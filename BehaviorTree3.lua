--[[
    BEHAVIOR TREES V5
    
	Originally by iniich_n and tyridge77: https://devforum.roblox.com/t/behaviortree2-create-complex-behaviors-with-ease/451047
	Forked and improved by defaultio

	Improvements/changes:
		- Decorators will work as expected when parents of arbitrary nodes, instead of only Task nodes
		- Calling tree:run() will return the outcome of the tree (success [1], fail [2], running [3])
		- Added repeater node
			- can repeat infinitely with a "count" parameter of nil or <= 0
			- returns success when done repeating
			- returns fail if a "breakonfail" parameter is true and it receives a failed result from its child
		- Added tree node which will call another tree and return the result of the other tree
		- If a success/fail node is left hanging without a child, it will directly return success/fail
		- Improved ProcessNode organization and readability by adding the interateNodes() iterator and the addNode() function
		- Changed node runner from using string node states to using number enums, to avoid string comparisons. Should be slightly faster.
		- Changed tasks to report their status by returning a status number enum, instead of calling a success/fail/running function on self
		- Added some more assertions in ProcessNode
		- Added comments and documentation so it's a little easier to add new nodes
		
		
	Changes by tyridge77(November 23rd, 2020)
		- Added support for live debugging(only in studio)
		- Added support for blackboards
		- Added Tree:Abort(), used for switching between trees but still calling finish on the previously running task
		
		
		- Added new Leaf node, Blackboard Query
			- These are used to perform fast and simple comparisons on a specific key in a blackboard
			- For instance, if you wanted a sequence to execute only if the entity's "LowHealth" state was set to true, or if a world's "NightTime" state was set to true(Shared Blackboard)
			- You can do this with tasks , but it's a bit faster if you only need to perform a simple boolean or nil check
			
			- You can only read from a blackboard using this node. Behavior Trees aren't meant to be visual scripting - just a way to carry out plans
			
			- Parameters:
				
				- Board: string that defaults to Entity if no value is specified. 
					- Entity will reference the object's blackboard passed into the tree via tree:Run(object)
					- If a value is given, say "WorldStates", it will attempt to grab the Shared Blackboard to use with the same name. You can register these via BehaviorTreeCreator:RegisterSharedBlackboard(name,table)

				- Key: the string index of the key you're trying to query(for instance, "LowHealth")
				- Type: string which specifies what kind of query you're trying to perform.
					- You can choose true,false,set,or unset to perform boolean/nil checks. Alternatively you can specify a string of your choice to perform a string comparison
		
		- Added new composite node, While
			- Only accepts two children, a condition(1st child), and an action(2nd child)
			- Repeats until either
				- condition returns fail, wherein the node itself returns fail
				- action returns success, wherein the node itself returns success
			
			- Used for processing stacks of items
				- Say you want an NPC to create a stack of nearby doors, then try to enter each door until there are no doors left to try, or the NPC got through a door.
				- If the NPC got through a door successfully, the node would return success. Otherwise, if there were no doors that were able to be entered, the node will return fail
				- Example pic: https://cdn.discordapp.com/attachments/711758878995513364/783523673704628294/unknown.png
				
				
	Changes by tyridge77(May 5th, 2022)

	-- Fixed critical issue where actors using the same tree borrowed the same running/paused state, effectively breaking all trees used by multiple actors(woops!)
	-- Added Metaprox's "External Task" fork, which allows you to use Rojo with BTrees
	
--]]


local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local IsStudio = RunService:IsRunning() and RunService:IsStudio()

local BehaviorTree = {}

local SUCCESS,FAIL,RUNNING = 1,2,3


-- Used by the BehaviorTree Editor plugin 
local RunningTreesFolder
if IsStudio then
	local cam = Instance.new("Camera",script)
	cam.Name = "NonReplicated"
	RunningTreesFolder = Instance.new("Folder",cam)
	RunningTreesFolder.Name = "RunningTrees(debug)"
	CollectionService:AddTag(RunningTreesFolder,"_btRunningTrees")
end
--

-------- Blackboards --------

-- Blackboards are just tables for behavior trees that can be read from and written to
-- They can exist on a per-entity or a global/shared level. 
-- Trees can read and write entity blackboards but only read from shared blackboards
-- Trees do this using the new Blackboard node

BehaviorTree.SharedBlackboards = {} -- Dictionary for shared blackboards using the blackboard's string index as key

local BLACKBOARD_QUERY_TYPE_TRUE, BLACKBOARD_QUERY_TYPE_FALSE, BLACKBOARD_QUERY_TYPE_NIL, BLACKBOARD_QUERY_TYPE_NOTNIL = 1,2,3,4


-------- TREE NODE PROCESSOR --------

-- Iterates through raw node tree and constructs an optimzied data structure that will be used for quick tree traversal at runtime
-- For each node, onsuccess and onfail values are set, which indicate the index of the next node that the runner hit after a success or failure

-- During processing algorithm, onsuccess and onfail will be each set to true or false, until it is set to an actual int index.
-- true indicates that a onsuccess or onfail should return success. false indicates that a onsuccess or onfail should return fail.


local function ProcessNode(node, nodes)

	-- Iterate and process all children and descendant nodes, returning an iterator for each descendant node
	local function iterateNodes()
		local c, i = 0, 0
		local childNode 
		local isFinalChildNode
		return function()
			i = i + 1
			if i == #nodes + 1 then
				childNode = nil
			end
			if not childNode then
				if isFinalChildNode then
					return nil
				end
				c = c + 1
				childNode = node.params.nodes[c]
				isFinalChildNode = c == #node.params.nodes
				i = #nodes + 1
				ProcessNode(childNode, nodes)
			end
			local node = nodes[i]
			return node, #nodes + 1, isFinalChildNode
		end
	end

	-- Add a new node to the final node table, returning the node and its index
	local function addNode(nodeType)
		local node = {type = nodeType}
		nodes[#nodes + 1] = node
		return node, #nodes
	end


	------------------------------
	--------- LEAF NODES ---------

	if node.type == "task" then
		assert(node.params.run, "Can't process tree; task leaf node has no run func parameter")

		local taskNode = addNode("task")
		taskNode.start = node.params.start
		taskNode.run = node.params.run
		taskNode.finish = node.params.finish
		taskNode.onsuccess = true
		taskNode.onfail = false
		taskNode.nodefolder = node.params.nodefolder

	elseif node.type == "blackboard" then

		local bbnode = addNode("blackboard")
		bbnode.onsuccess = true
		bbnode.onfail = false
		bbnode.key = node.params.key
		bbnode.board = node.params.board

		local returntype = node.params.value:lower()

		local comparestring = false

		if returntype == "true" then
			bbnode.returntype = BLACKBOARD_QUERY_TYPE_TRUE
		elseif returntype == "false" then
			bbnode.returntype = BLACKBOARD_QUERY_TYPE_FALSE
		elseif returntype == "unset" or returntype == "nil" then
			bbnode.returntype = BLACKBOARD_QUERY_TYPE_NIL
		elseif returntype == "set" then
			bbnode.returntype = BLACKBOARD_QUERY_TYPE_NOTNIL
		else
			comparestring = true
			bbnode.returntype = node.params.value
		end
		bbnode.comparestring = comparestring

	elseif node.type == "tree" then
		assert(node.params.tree, "Can't process tree; tree leaf node has no linked tree object")

		local treeNode = addNode("tree")
		treeNode.tree = node.params.tree
		treeNode.onsuccess = true
		treeNode.onfail = false
		treeNode.nodefolder = node.params.nodefolder


		-----------------------------------
		--------- DECORATOR NODES ---------	

	elseif node.type == "always_succeed" then
		assert(#node.params.nodes <= 1, "Can't process tree; succeed decorator with multiple children")

		if node.params.nodes[1] then
			-- All child node outcomes that return failure are switched to return success
			for node, nextNode, isFinal in iterateNodes() do
				if node.onsuccess == false then
					node.onsuccess = true
				end
				if node.onfail == false then
					node.onfail = true
				end
			end
		else
			-- Hanging succeed node, always return success
			local succeed = addNode("succeed")
			succeed.onsuccess = true
		end



	elseif node.type == "always_fail" then
		assert(#node.params.nodes <= 1, "Can't process tree; fail decorator with multiple children")

		if node.params.nodes[1] then
			-- All child node outcomes that return success are switched to return failure
			for node, nextNode, isFinal in iterateNodes() do
				if node.onsuccess == true then
					node.onsuccess = false
				end
				if node.onfail == true then
					node.onfail = false
				end
			end
		else
			-- Hanging fail node, always return fail
			local fail = addNode("fail")
			fail.onfail = false
		end


	elseif node.type == "invert" then
		assert(#node.params.nodes <= 1, "Can't process tree; invert decorator with multiple children")
		assert(#node.params.nodes == 1, "Can't process tree; hanging invert decorator")

		-- All child node outcomes are flipped
		for node, nextNode, isFinal in iterateNodes() do
			if node.onsuccess == true then
				node.onsuccess = false
			elseif node.onsuccess == false then
				node.onsuccess = true
			end
			if node.onfail == false then
				node.onfail = true
			elseif node.onfail == true then
				node.onfail = false
			end
		end


	elseif node.type == "repeat" then
		assert(#node.params.nodes <= 1, "Can't process tree; repeat decorator with multiple children")
		assert(#node.params.nodes == 1, "Can't process tree; hanging repeat decorator")

		local repeatStartIndex = #nodes + 1

		-- It's not necessary to have a repeat node if it repeats indefinitely
		local repeatCount = node.params.count and node.params.count > 0 and node.params.count or nil

		if repeatCount and repeatCount > 0 then
			addNode("repeat-start")

			local repeatNode, repeatIndex = addNode("repeat")
			repeatNode.repeatGoal = repeatCount
			repeatNode.repeatCount = 0
			repeatNode.onsuccess = true
			repeatNode.onfail = false

			repeatStartIndex = repeatIndex
		end

		-- Direct all child node outcomes to this node. If break on fail, then leave fail outcomes as they are (fail outcome for breaking)
		local breakOnFail = node.params.breakonfail

		for node, nextNode, isFinal in iterateNodes() do
			if node.onsuccess == true then
				node.onsuccess = repeatStartIndex
			elseif node.onsuccess == false and not breakOnFail then
				node.onsuccess = repeatStartIndex
			end

			if node.onfail == false and not breakOnFail then
				node.onfail = repeatStartIndex
			elseif node.onfail == true then
				node.onfail = repeatStartIndex
			end
		end

	elseif node.type == "while" then
		assert(#node.params.nodes == 2, "Can't process tree; while composite without 2 children")

		local conditionNode = node.params.nodes[1]
		local actionNode = node.params.nodes[2]

		local repeatStartIndex = #nodes + 1

		-- It's not necessary to have a repeat node if it repeats indefinitely
		local repeatCount = node.params.count and node.params.count > 0 and node.params.count or nil

		if repeatCount and repeatCount > 0 then
			-- repeat-start resets repeatCount of the following repeat
			local startNode, startIndex = addNode("repeat-start")

			local repeatNode, repeatIndex = addNode("repeat")
			repeatNode.repeatGoal = repeatCount
			repeatNode.repeatCount = 0
			repeatNode.onsuccess = false
			repeatNode.onfail = false

			repeatStartIndex = repeatIndex
		end

		--

		local conditionStartIndex = #nodes + 1
		ProcessNode(conditionNode, nodes)

		local actionStartIndex = #nodes + 1
		ProcessNode(actionNode, nodes)

		for index = conditionStartIndex, actionStartIndex - 1 do
			local node = nodes[index]

			if node.onsuccess == true then
				node.onsuccess = actionStartIndex
			end

			if node.onfail == true then
				node.onfail = actionStartIndex
			end
		end

		for index = actionStartIndex, #nodes do
			local node = nodes[index]

			if node.onsuccess == false then
				node.onsuccess = repeatStartIndex 
			end

			if node.onfail == false then
				node.onfail = repeatStartIndex
			end
		end


		-----------------------------------
		--------- COMPOSITE NODES ---------	


	elseif node.type == "sequence" then
		assert(#node.params.nodes >= 1, "Can't process tree; sequence composite node has no children")

		-- All successful child node outcomes will return the next node, or success if it is the last node
		for node, nextNode, isFinal in iterateNodes() do
			if node.onsuccess == true then
				node.onsuccess = not isFinal and nextNode or true
			end
			if node.onfail == true then
				node.onfail = not isFinal and nextNode or true
			end
		end


	elseif node.type == "selector" then
		assert(#node.params.nodes >= 1, "Can't process tree; selector composite node has no children")

		-- All fail child node outcome will return the next node, or fail if it is the last node
		for node, nextNode, isFinal in iterateNodes() do
			if node.onsuccess == false then
				node.onsuccess = not isFinal and nextNode or false
			end
			if node.onfail == false then
				node.onfail = not isFinal and nextNode or false
			end
		end


	elseif node.type == "random" then
		assert(#node.params.nodes >= 1, "Can't process tree; random composite node has no children")

		local randomNode = addNode("random")
		randomNode.indices = {}
		for _,childNode in pairs(node.params.nodes) do
			if childNode.params.weight then
				local base = #randomNode.indices
				local index = #nodes + 1
				for i = 1, childNode.params.weight do
					randomNode.indices[base + i] = index
				end
			else
				randomNode.indices[#randomNode.indices + 1] = #nodes + 1
			end
			ProcessNode(childNode, nodes)
		end


		-----------------------------
		--------- ROOT NODE ---------

	elseif node.type == "root" then
		assert(#nodes == 0, "Can't process tree; root node found at nonroot location")

		ProcessNode(node.tree, nodes)

		for i = 1, #nodes do
			local node = nodes[i]
			-- Set success outcomes next index to #nodes + 1 to indicate success
			-- Set fail outcomes next index to #nodes + 2 to indicate failure
			if node.onsuccess == true then
				node.onsuccess = #nodes + 1
			elseif node.onsuccess == false then
				node.onsuccess = #nodes + 2
			end
			if node.onfail == true then
				node.onfail = #nodes + 1
			elseif node.onfail == false then
				node.onfail = #nodes + 2
			end
		end


	else
		error("ProcessNode: bad node.type " .. tostring(node.type))
	end
end


local TreeProto = {}


-------- TREE ABORT --------

-- Calls finish() on the running task of the tree, and sets the tree index back to 1
-- Should be used if you want to cancel out of a tree to swap to another(for instance in the case of a state change)

function TreeProto:abort(obj,...)
	assert(typeof(obj) == "table","The first argument of a behavior tree's abort method must be a table!")
	local nodes = self.nodes
	local data = self.DataLookup[obj]

	if not data then
		return
	end
	
	local index = data.index 
	
	local node = nodes[index]
	if node.type == "task" then
		if node.finish then
			node.finish(obj,FAIL,...)
		end
	end
	data.index = 1
end


-------- TREE RUNNER --------

-- Traverses across the processed node tree produced by ProcessNode

-- For each node, calculates success, fail, or running
-- If running, pause the runner and immediately break out of the runner, returning a running state.
-- If success or fail, gets the next node we should move to using node.onsuccess or node.onfail

-- When the final node is processed, its onsuccess/onfail index will point outside of the scope of nodes, causing the loop to break
-- onsuccess final nodes will point to #nodes + 1, which indicates a tree outcome of success
-- onfail final nodes will point to #nodes + 2, which indicates a tree outcome of fail


function TreeProto:run(obj,...)	
	assert(typeof(obj) == "table","The first argument of a behavior tree's run method must be a table!")


	-- Editor debugging
	local DebugEntityNode
	if IsStudio and self.folder then
		local treeName = self.folder.Name
		local objName = tostring(obj)
		local entities = RunningTreesFolder:FindFirstChild(treeName)
		if not entities then
			entities = Instance.new("Folder")
			entities.Name = treeName
			entities.Parent = RunningTreesFolder
		end
		local entity = entities:FindFirstChild(objName)
		if not entity then
			entity = Instance.new("Folder")
			entity.Name = objName

			local nodefolder = Instance.new("ObjectValue",entity)
			nodefolder.Name = "Node"

			local treefolder = Instance.new("ObjectValue",entity)
			treefolder.Name = "TreeFolder"
			treefolder.Value = self.folder

			local displayName = obj.name or obj.Name 
			if displayName and typeof(displayName) ~= "string" then
				displayName = nil
			end
			if not displayName then
				for i,v in pairs(obj) do
					if typeof(v) == "Instance" then
						displayName = v.Name
					end
				end
			end
			if displayName then
				local name = Instance.new("StringValue",entity)
				name.Name = "Name"
				name.Value = displayName
			end
			entity.Parent = entities
		end		
		DebugEntityNode = entity.Node
	end
	--
	

	local nodes = self.nodes
	
	--[[ Get data for this object or create new ]]
	local data = self.DataLookup[obj]
	if not data then
		data = {index = 1}
		self.DataLookup[obj] = data
	end
	--
		
	if data.running then
		-- warn(debug.traceback("Tried to run BehaviorTree while it was already running"))
		return
	end		

	-- Get entity blackboard
	local blackboard = obj.Blackboard
	if not blackboard then
		blackboard = {}
		obj.Blackboard = blackboard
	end

	if not obj.SharedBlackboards then
		obj.SharedBlackboards = BehaviorTree.SharedBlackboards
	end
	--

	local nodeCount = #nodes

	local didResume = data.paused
	data.paused = false
	data.running = true

	-- Loop over all nodes until complete or a task node returns RUNNING
	while data.index <= nodeCount do
		local node = nodes[data.index]

		-- Debug
        if IsStudio and self.folder then
			DebugEntityNode.Value = node.nodefolder
		end		
		--

		------------------------------
		--------- LEAF NODES ---------	

		if node.type == "task" then
			if didResume then
				didResume = false
			elseif node.start then
				node.start(obj,...)
			end

			local status = node.run(obj,...)
			if status == nil then
				warn("node.run did not call success, running or fail, acting as fail")
				status = FAIL
			end

			if status == RUNNING then
				data.paused = true
				break
			elseif status == SUCCESS then
				if node.finish then
					node.finish(obj,status, ...)
				end
				data.index = node.onsuccess
			elseif status == FAIL then
				if node.finish then
					node.finish(obj,status, ...)
				end
				data.index = node.onfail
			else
				error("bad node.status")
			end

		elseif node.type == "blackboard" then
			local result = false
			local board

			if node.board == "Entity" then
				board = blackboard
			else
				local shared_board = BehaviorTree.SharedBlackboards[node.board]
				if not shared_board then
					warn(string.format("Shared Blackboard %s is not registered, acting as fail"), node.board)
				end
				board = shared_board
			end

			if board then
				local val = board[node.key]
				local str = tostring(val)
				if node.comparestring then
					result = str and str == node.returntype
				else
					if node.returntype == BLACKBOARD_QUERY_TYPE_TRUE then
						result = val == true
					elseif node.returntype == BLACKBOARD_QUERY_TYPE_FALSE then
						result = val == false
					elseif node.returntype == BLACKBOARD_QUERY_TYPE_NIL then
						result = val == nil
					elseif node.returntype == BLACKBOARD_QUERY_TYPE_NOTNIL then
						result = val ~= nil
					end			
				end	
			end

			data.index = result == true and node.onsuccess or node.onfail

		elseif node.type == "tree" then
			local treeResult = node.tree:run(obj,...)

			if treeResult == RUNNING then
				data.paused = true
				break
			elseif treeResult == SUCCESS then
				data.index = node.onsuccess
			elseif treeResult == FAIL then
				data.index = node.onfail
			else
				error("bad tree result")
			end


			-----------------------------------
			--------- COMPOSITE NODES ---------	

		elseif node.type == "random" then
			data.index = node.indices[math.random(1, #node.indices)]


			-----------------------------------
			--------- DECORATOR NODES ---------	

		elseif node.type == "repeat-start" then
			data.index = data.index + 1

			local repeatNode = nodes[data.index]
			repeatNode.repeatCount = 0


		elseif node.type == "repeat" then
			node.repeatCount = node.repeatCount + 1

			if node.repeatCount > node.repeatGoal then
				data.index = node.onsuccess
			else
				data.index = data.index + 1
			end


		elseif node.type == "succeed" then -- Hanging succeed node (technically a leaf)
			data.index = node.onsuccess
		elseif node.type == "fail" then -- Hanging fail node (technically a leaf)
			data.index = node.onfail
		else
			error("bad node.type")
		end
	end


	-- Get tree outcome from the break index outcome
	-- +1 indicates success; +2 indicates fail
	-- If index is <= node count, then tree must be running
	local treeOutcome
	if data.index == nodeCount + 1 then
		treeOutcome = SUCCESS
	elseif data.index == nodeCount + 2 then
		treeOutcome = FAIL
	else
		treeOutcome = RUNNING
	end

	data.index = data.index <= nodeCount and data.index or 1
	data.running = false

	return treeOutcome
end

TreeProto.Run = TreeProto.run
TreeProto.Abort = TreeProto.abort

------- TREE CONSTRUCTOR -------

function BehaviorTree.new(params)
	local tree = params.tree
	local nodes = {}
	local DataLookup = {}

	ProcessNode({type = "root", tree = tree, params = {}}, nodes)

	return setmetatable({
		nodes = nodes,
		DataLookup = DataLookup,
		folder = params.treeFolder,
	}, { __index = TreeProto })
end



------- NODE CONSTRUCTORS -------

-- Composites
BehaviorTree.Sequence = function(params) return {type = "sequence", params = params} end
BehaviorTree.Selector = function(params) return {type = "selector", params = params} end
BehaviorTree.Random = function(params) return {type = "random", params = params} end
BehaviorTree.While = function(params) return {type = "while", params = params} end

-- Decorators
BehaviorTree.Succeed = function(params) return {type = "always_succeed", params = params} end
BehaviorTree.Fail = function(params) return {type = "always_fail", params = params} end
BehaviorTree.Invert = function(params) return {type = "invert", params = params} end
BehaviorTree.Repeat = function(params) return {type = "repeat", params = params} end


-- Leafs
BehaviorTree.Task = function(params) return {type = "task", params = params} end
BehaviorTree["External Task"] = function(params) return {type = "task", params = params} end
BehaviorTree.Tree = function(params) return {type = "tree", params = params} end
BehaviorTree["Blackboard Query"] = function(params) return {type = "blackboard", params = params} end


return BehaviorTree
