--[[
    BEHAVIOR TREE CREATOR V5
	
	Originally by tyridge77: https://devforum.roblox.com/t/btrees-visual-editor-v2-0/461015
	Forked and improved by defaultio

	
	Changes by tyridge77(November 23rd, 2020)
	- Trees are now created only once, and decoupled from objects
	- You now create trees simply by doing BehaviorTreeCreator:Create(treeFolder) - if a tree is already made for that folder it'll return that
	- You now run Trees via Tree:Run(object) 
	- You can now abort a tree via Tree:Abort(object) , used for switching between trees but still calling finish on the previously running task
	- Added support for live debugging
	- Added BehaviorTreeCreator:RegisterBlackboard(name,table)
		- This is used in conjunction with the new blackboard query node
	- Changed up some various internal stuff
--]]

local CollectionService = game:GetService("CollectionService")
local TREE_TAG = "_BTree"

local TreeCreator = {}
local BehaviorTree3 = require(script.BehaviorTree5)

local Trees = {}
local SourceTasks = {}
local TreeIDs = {}

--------------------------------------------
-------------- PUBLIC METHODS --------------

-- Create tree object from a treeFolder.
function TreeCreator:Create(treeFolder)
	assert(treeFolder, "Invalid parameters, expecting treeFolder, object")

	local Tree = self:_getTree(treeFolder)
	if Tree then
		return Tree
	else
		warn("Couldn't get tree for ",treeFolder)
	end
end


function TreeCreator:RegisterSharedBlackboard(index,tab)
	assert(index and tab and typeof(index) == "string" and typeof(tab) == "table","RegisterSharedBlackboard takes two arguments in the form of [string] index,[table] table")
	BehaviorTree3.SharedBlackboards[index] = tab
end


---------------------------------------------
-------------- PRIVATE METHODS --------------

local function GetModule(ModuleScript)
	local found = SourceTasks[ModuleScript]
	if found then
		return found
	else
		found = require(ModuleScript)
		SourceTasks[ModuleScript]=found
		return found
	end
end


local function GetModuleScript(folder)
	local found = folder:FindFirstChildWhichIsA("ModuleScript")
	if found then
		return found
	else
		local link = folder:FindFirstChild("Link")
		if link then
			local linked = link.Value
			if linked then
				return GetModuleScript(linked)
			end
		end
	end
end


-- For task nodes, get module script from node folder
function TreeCreator:_getSourceTask(folder)
	local ModuleScript = GetModuleScript(folder)
	if ModuleScript then
		return GetModule(ModuleScript)
	end
end
function TreeCreator:_getExternalSourceTask(folder)
	local SourcePeram = folder.Parameters:FindFirstChild("Source")
	if SourcePeram then
		local Source = SourcePeram.Value
		if Source then
			return GetModule(Source)
		end
	end
end


function TreeCreator:_buildNode(folder)
	local nodeType = folder.Type.Value
	local weight = folder:FindFirstChild("Weight") and folder.Weight.Value or 1

	-- Get outputs, sorted in index order 
	local Outputs = folder.Outputs:GetChildren()
	local orderedChildren = {}
	for i = 1,#Outputs do
		local objvalue = Outputs[i]
		table.insert(orderedChildren,objvalue)
	end
	table.sort(orderedChildren,function(a,b)
		return tonumber(a.Name) < tonumber(b.Name)
	end)
	for i = 1,#orderedChildren do
		orderedChildren[i] = self:_buildNode(orderedChildren[i].Value)
	end

	-- Get parameters from parameters folder
	local parameters = {}
	for _, value in pairs(folder.Parameters:GetChildren()) do
		if not (value.Name == "Index") then
			parameters[string.lower(value.Name)] = value.Value
		end
	end

	-- Add nodes and task module/tree to node parameters
	parameters.nodes = orderedChildren
	parameters.nodefolder = folder
	if nodeType == "Task" then
		local sourcetask = self:_getSourceTask(folder)
		assert(sourcetask, "could't build tree; task node had no module")
		parameters.start = sourcetask.start
		parameters.run = sourcetask.run
		parameters.finish = sourcetask.finish
	elseif nodeType == "External Task" then
		local sourcetask = self:_getExternalSourceTask(folder)
		assert(sourcetask, "could't build tree; external task node had no source")
		parameters.start = sourcetask.start
		parameters.run = sourcetask.run
		parameters.finish = sourcetask.finish
	elseif nodeType == "Tree" then
		local tree = self:_getTreeFromId(parameters.treeid)
		assert(tree, string.format("could't build tree; couldn't get tree object for tree node with TreeID:  %s!",tostring(parameters.treeid)))
		parameters.tree = tree
	end

	-- Initialize node with BehaviorTree3
	parameters.weight = weight
	local node = BehaviorTree3[nodeType](parameters)

	return node
end


function TreeCreator:_createTree(treeFolder)
	print("Attempt create tree: ",treeFolder)
	local nodes = treeFolder.Nodes
	local RootFolder = nodes:FindFirstChild("Root")
	assert(RootFolder, string.format("Could not find Root under BehaviorTrees.Trees.%s.Nodes!",treeFolder.Name))
	assert(#RootFolder.Outputs:GetChildren() == 1, string.format("The root node does not have exactly one connection for %s!",treeFolder.Name))

	local firstNodeFolder = RootFolder.Outputs:GetChildren()[1].Value
	local root = self:_buildNode(firstNodeFolder)
	local Tree = BehaviorTree3:new({tree=root,treeFolder = treeFolder})
	Trees[treeFolder] = Tree
	TreeIDs[treeFolder.Name] = Tree
	return Tree	
end


function TreeCreator:_getTree(treeFolder)
	return Trees[treeFolder] or self:_createTree(treeFolder)
end
-- For tree ndoes to get a tree from
function TreeCreator:_getTreeFromId(treeId)
	local tree = TreeIDs[treeId]
	if not tree then
		for i,folder in pairs(CollectionService:GetTagged(TREE_TAG)) do
			if folder.Name == treeId then
				return self:_getTree(folder)
			end
		end
	else
		return tree
	end
end


return TreeCreator
