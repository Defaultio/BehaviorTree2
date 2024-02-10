# BehaviorTree5(Latest update: May 5th, 2022)

This module is a fork of BehaviorTrees2 by oniich_n. The following are the improvements/changes:
* Previously, Decorators would only work when parented to Task node. Now, they can be placed arbitrarily, and even chained together, and will work as expected. Internally, decorators work slightly differently, but I preserved the clever and efficient tree traversal algorithm that oniich_n implemented in BehaviorTrees2. Should still be just as fast.
* Calling tree:run() will return the outcome of the tree (success [1], fail [2], running [3])
* Added repeater node
    * can repeat infinitely with a "count" parameter of nil or <= 0
    * returns success when done repeating
    * returns fail if a "breakonfail" parameter is true and it receives a failed result from its child
* Added tree node which will call another tree and return the result of the other tree
* If a success/fail node is left hanging without a child, it will directly return success/fail
* Improved ProcessNode organization and readability by adding the interateNodes() iterator and the addNode() function
* Changed node runner from using string node states to using number enums, to avoid string comparisons. Should be slightly faster.
* Changed tasks to report their status by returning a status number enum, instead of calling a success/fail/running function on self
* Added some more assertions in ProcessNode
* Added comments and documentation so it's a little easier to add new nodes
* Changed "Task"/"Selector" language to more generic "Leaf"/"Composite"

V5: (May 2022)

* Added Metaprox's External Task fork, to allow for rojo support
* Fixed critical issue in behavior trees where multiple actors wouldn't properly keep track of their running states


BehaviorTree5 is an implementation of the "behavior tree" paradigm for managing behavior. This allows us to create relatively complex patterns of behavior without much getting "lost in the sauce", so to speak. In *behavior trees*, actions are represented as **tasks**, or "leaves". These tasks are then collected in a container called a **tree**, which we "run" through in order to determine what task should be done at a given point in time.

## Nodes
Nodes contain information about how to handle *something*. This can either be a task, or a manipulation of tasks. In BT2, there are 3 types of nodes:
* Leafs
* Composites
* Decorators

Creating nodes creates new objects, so be aware of that when reusing them for different agents.

### Leafs
Leafs are the foundation of BT3. They define how to act.

#### Tasks
The most commonly used leaf is a `Task`. Let's take a look at how they're written.

```
local SUCCESS,FAIL,RUNNING = 1,2,3

local NewNode = BehaviorTree5.Task({

   -- 'start' and 'finish' functions are optional. only "run" is required!

   start = function(object, ...)
      object.i = 0
      print("I've prepped the task!")
   end,

   run = function(object, ...)
      object.i = object.i+1
      if object.i == 5 then
          return SUCCESS
      elseif object.i > 5 then
         return FAIL'
      else
         print("The task is still running...")
         return RUNNING
      end
   end,

   

   finish = function(object, status, ...)
      object.i = nil
      print("I'm done with the task! My outcome was: ")
      if status == SUCCESS then
         print("Success!")
      elseif status == FAIL then
         print("Fail!")
      end
   end
})
```
Tasks are created by calling `BehaviorTree5.Task()`, with a table defining different **task functions**. When we run a behavior tree, it will "process" a node in the order `start -> run -> finish`. These functions will *always be called in this order*.

The `start` and `finish` functions are usually used to prep and cleanup the work that a task does, like initializing and destroying object properties. However, it is not necessary to define them. A task will function perfectly fine with just the `run` function alone.

The `run` function is the "base of operations" for a task. Here, we handle anything we would want to do. When we "run" a behavior tree, we would do so in steps. If we wanted real-time behavior, for example, we could run our trees within `RunService.Heartbeat`. Keep in mind the rate at which you will be processing trees when defining this function. Think about where to change the *task state* of a node when writing your function as well. Consider when it should `fail` so that you don't create unintended behavior. (i.e. attacking when you should be walking instead) Remember that you can **only call one state** per step.

Notice the `object, ...` parameters passed to `start`, `run`, and `finish`. This object is a table that is passed to the tree when `run` is called on it, and any additional parameters are also passed along.

#### Blackboard Query

When running a tree on an object, a `Blackboard` table will be injected into the object if one does not exist already. This can be used by the Blackboard Query node for easy state lookup. A blackboard query is commonly used to see if a value is set or not in order to dictate the flow of relevant logic in a tree.

You can achieve the same effect with tasks, but it's a bit faster if you only need to perform a simple boolean or nil check

#### Trees
The `Tree` is a special `Leaf` type that will execute another tree and pass the result of that tree to its parent.

```
local AnotherTree = BehaviorTree5:new(...)
local NewNode = BehaviorTree5.Task({tree = AnotherTree})
````
### Composites
These nodes take multiple `Leafs` and give them order. In BT3, we have `Sequence`, `Selector`, `Random` types for `Compites`.

#### Sequence
The `Sequence` process the nodes it is given in sequence of the order they are defined. If any of its subnodes fail, then it will not continue to process the `subnodes` that follow it and return a `fail` state itself.

```
Sequence = BehaviorTree5.Sequence({
    nodes = {
        node1,
        node2, -- if this failed, the next step would process node1
        node3
    }
})
```
#### Selector
The `Selector` node will process every node until one of them succeeds, after which it will return `success` itself. If none of its subnodes succeed, then this `Composite` would return a `fail` state.

```
Priority = BehaviorTree5.Selector({
    nodes = {
        node1,
        node2,
        node3 -- this is the only node that suceeded, so Priority would return success
    }
})
```
#### Random
This `Selector` will randomly select a subnode to process, and will return whatever state that node returns.
```
Random = BehaviorTree5.Random({
    nodes = {
        node1,
        node2,
        node3
    }
})
```
Nodes can also have an optional `weight` attribute that will affect `Random`. Default is `1`.

```
local SUCCESS,FAIL,RUNNING = 1,2,3

node1 = BehaviorTree5.Task({
    weight = 10,
    run = function(object)
        print("Weight: 10")
        return SUCCESS
    end
})

node2 = BehaviorTree5.Task({
    weight = 10,
    run = function(object)
        print("Also weight: 10")
        return SUCCESS
    end
})

node3 = BehaviorTree5.Task({
    weight = 200,
    run = function(object)
        print('You probably won't see "Weight: 10" printed'.)
        return SUCCESS
    end
})
```
#### While
The `While` Only accepts two children, a condition(1st child), and an action(2nd child) It repeats until either the condition returns fail, wherein the node itself returns fail, or the action returns success, wherein the node itself returns success.

```
While = BehaviorTree5.While({
    nodes = {
        condition, -- If this node returns fail, return fail
        action -- When this node returns success, return success
    }
})
```
### Decorators
Decorators are nodes that wrap other nodes and alter their task state. Right now, there are `Succeed`, `Fail`, `Invert`, and `Repeat` decorators. `Succeed`, `Fail`, and `Invert` are pretty self-explanatory, and are helpful for when you start making more complex trees via nested `Collections`. 

These can be written as such.
```
Invert = BehaviorTree5.Invert({
    nodes = {nodeHere}
})
````
`Repeat` decorators will repeat their children node tasks until `count`, or indefinitely if `count` is nil or < 0, after which they will return a `success` state. If `breakonfail` is true and its child node fails, it will stop repeating and return a `fail` state.
````
Repeat = BehaviorTree5.Repeat({
    nodes = {nodeHere},
    count = 3,
    breakonfail = true
})
````
## The Tree
Once you have your nodes set up and ready to go, we can start planting some trees. A `Tree` usually starts with any `Selector`, which should have `Task` nodes in them or other `Selector` nodes with other nodes in them. They can be instantiated by calling `BehaviorTree5:new()` with a `table` containing tree information as its only argument.

```
Tree = BehaviorTree5:new({
    tree = BehaviorTree5.Sequence({
        nodes = {
            node1,
            node2,

            BehaviorTree5.Random({
                nodes = {
                    node3,
                    node4
                }
            })
        }
    })
})
```
As you can see, we can nest `Composite` nodes within each other. This is where the magic of behavior trees come in! 

### Running trees
To run a tree, call `:run` on the tree object, passing it a table. This table is the relevant object or actor that tree is dictating behavior for. You can also pass any additional parameters you desire, and these will be passed along to the task functions.

```
local actorObject = {...}

Tree = BehaviorTree5:new({
    tree = BehaviorTree5.Sequence({
        -- nodes from earlier
    })
})

while true do
    local treeStatus = Tree:run(actorObject)
    wait(1)
end
```

That's pretty much all there is to BehaviorTree5. Go nuts with it or something. If you have any issues or questions, feel free to ask about them on the devforum post: 
https://devforum.roblox.com/t/btreesv5-rojo-support-fixes/
