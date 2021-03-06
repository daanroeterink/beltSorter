require "libs.classes.BeltFactory"
require "control.belt-sorter-gui"

-- Registering entity into system
local beltSorterEntity = {}
entities["belt-sorter1"] = beltSorterEntity
entities["belt-sorter2"] = beltSorterEntity
entities["belt-sorter3"] = beltSorterEntity
beltSorter = {} -- methods of beltSorter

-- Constants
local searchPriority = {{0,-1},{-1,0},{1,0},{0,1}}
local rowIndexToDirection = {
	[1]=defines.direction.north,
	[2]=defines.direction.west,
	[3]=defines.direction.east,
	[4]=defines.direction.south
}
local minimalUpdateTicks = 60
local energy = {25,50,100} --kW
local energyFactor = 17.7777
local maxUpdateTicks = {36,18,12}


---------------------------------------------------
-- entityData
---------------------------------------------------

-- Used data:
-- {
--   lamp = LuaEntity(fake lamp),
--	 config = LuaEntity(fake constant combinator to store settings)
--   filter[$itemName] = { {$int(side), {$bool(putOnLeftLane), $bool(putOnRightLane)}} }
--                       This is an ordered list to support output priority
--   filter[$prio] = $rowIndex
--   guiFilter[$row.."."..$slot] = $itemName
--            [$row.."."..$slot..".sides"] = { $bool, $bool } (on which belt lane should itmes go)
--            [$row] = $prio
--   lvl = $number (1=basic,2=average,3=advanced)
--   condition = $bool (whether circuit condition allows entity to work
--   nextConditionUpdate = int(tick) (when next check of circuit condition is done)
-- }

--------------------------------------------------
-- Global data
--------------------------------------------------

-- This helper file uses the following global data variables:
-- global.gui.playerData[$playerName].beltSorterGuiCopy = $guiFilter

--------------------------------------------------
-- Migration
--------------------------------------------------
--

beltSorter.migrateData37 = function()
	for id,data in pairs(global.entityData) do
		if data.name=="belt-sorter-v2" then
			data.name = "belt-sorter1"
			data.lvl = 1
			
			-- extend guiFilter with beltLane sides arr
			local newKeys={}
			for slotIndex,_ in pairs(data.guiFilter) do
				newKeys[slotIndex..".sides"] = {true,true}
			end
			for k,v in pairs(newKeys) do data.guiFilter[k] = v end
			
			local entity = entityOfId(id,"belt-sorter1")
			beltSorter.createConfig(data,entity)
		elseif data.name=="belt-sorter-advanced" then
			data.name = "belt-sorter2"
			data.lvl = 2
		end
	end
end

beltSorter.migrateData40 = function()
	local intro=false
	for id,data in pairs(global.entityData) do
		for row = 1,4 do
			data.guiFilter[row] = row
		end
		for row=1,4 do
			for slot=1,4 do
				local name = data.guiFilter[row.."."..slot]
				if name ~= nil and game.item_prototypes[name] == nil then
					data.guiFilter[row.."."..slot] = nil
				end
			end
		end
		if data.lvl == 1 then
			local problem = nil
			local side = {"up","left","right","down"}
			for row=1,4 do
				for slot=3,4 do --old slots no longer available
					if data.guiFilter[row.."."..slot] ~= nil then
						if not problem then problem = "" end
						problem = problem .. data.guiFilter[row.."."..slot].."("..side[row]..") ,"
					end
				end
			end
			if problem then
				if not intro then
					game.print("[BeltSorter] Due to a change in the slot amounts of the normal BeltSorter some problem occured:")
					game.print("[BeltSorter] (coordinates are printed in the format: surface_x_y)")
					intro = true
				end
				game.print("[BeltSorter] at "..id.." some filter was removed: "..problem.." please check!")
			end
		end
		beltSorterGui.rebuildFilterFromGui(data)
	end
end
	
beltSorter.log = function(data)
	local toLog = deepcopy(data)
	toLog.input = nil
	toLog.output = nil
	return toLog
end

---------------------------------------------------
-- build and remove
---------------------------------------------------

beltSorterEntity.build = function(entity)
	scheduleAdd(entity, TICK_ASAP)
	local data = {
		lvl = tonumber(entity.name:sub(-1))
	}

	local pos = entity.position
	local lamp = entity.surface.create_entity({name="belt-sorter-lamp"..data.lvl,position=pos,force=entity.force})
	lamp.operable = false
	lamp.minable = false
	lamp.destructible = false
	lamp.get_or_create_control_behavior().circuit_condition = {
		condition = {
			comparator = "=",
			first_signal = {type="item", name="iron-plate"},
			second_signal = {type="item", name="iron-plate"}
		}
	}
	entity.connect_neighbour{wire=defines.wire_type.green,target_entity=lamp}
	
	-- find config combinator and load it's config
	local entities = entity.surface.find_entities_filtered{
		area={{pos.x-0.5,pos.y-0.5},{pos.x+0.5,pos.y+0.5}}, 
		name="entity-ghost", 
		force=entity.force
	}
	local config = nil
	for i = 1,#entities do
		if entities[i].ghost_name == "belt-sorter-config-combinator" then
			config = entities[i]
			break
		end
	end
	if config then
		_,data.config = config.revive()
		beltSorterGui.loadFilterFromConfig(data)
	else
		beltSorter.createConfig(data,entity)
	end
	
	overwriteContent(data,{
		config = data.config,
		lamp = lamp,
		filter = data.filter or {
			[1]=1,[2]=2,[3]=3,[4]=4
		},
		guiFilter = data.guiFilter or {
			[1]=1,[2]=2,[3]=3,[4]=4
		},
	})
	return data
end

beltSorter.createConfig = function(data,entity)
	data.config = entity.surface.create_entity({
		name = "belt-sorter-config-combinator",
		position = {entity.position.x,entity.position.y+0.2},
		force = entity.force
	})
	data.config.operable = false
	data.config.minable = false
	data.config.destructible = false
end

beltSorterEntity.remove = function(data)
	if data.lamp and data.lamp.valid then
		data.lamp.destroy()
	end
	if data.config and data.config.valid then
		data.config.destroy()
	end
end

beltSorterEntity.copy = function(source,srcData,target,targetData)
	info(target.name:sub(1,11))
	if not target.name:sub(1,11) == "belt-sorter" then
		return
	end
	beltSorter.replaceFilter(target,targetData,srcData.guiFilter)
end

beltSorter.replaceFilter = function(entity,data,newGuiFilter)
	data.guiFilter = deepcopy(newGuiFilter)
	beltSorter.sanityCheckFilter(data)
	info("Copy entity data. filter after sanity checks: "..serpent.block(data.guiFilter))

	beltSorterGui.rebuildFilterFromGui(data)
	local playersWithGuiOfTarget = gui_playersWithOpenGuiOf(entity)
	for _,player in pairs(playersWithGuiOfTarget) do
		beltSorterGui.refreshGui(player,entity)
	end
end

beltSorter.sanityCheckFilter = function(data)
	if data.lvl < 2 then
		local newFilter = {}
		for side=1,4 do
			for slot=1,beltSorterGui.slotsAvailable[1] do
				if data.guiFilter[side.."."..slot] then
					newFilter[side.."."..slot] = data.guiFilter[side.."."..slot]
					newFilter[side.."."..slot..".sides"] = {true,true}
				end
			end
		end
		data.guiFilter = newFilter
	end
	if data.lvl < 3 then
		for side=1,4 do
			data.guiFilter[side] = side
		end
	end
end


beltSorterEntity.tick = function(entity,data)
	if not data then
		err("Error occured with beltSorter: "..idOfEntity(entity))
		return 0,nil
	end
	if data.condition == nil or data.nextConditionUpdate == nil or data.nextConditionUpdate <= game.tick then
		beltSorter.updateCircuitCondition(entity,data)
		if data.condition == false then
			return minimalUpdateTicks,nil
		end
	end

	local maxEnergy = energy[data.lvl] * energyFactor
	local energyPercentage = math.min(entity.energy,maxEnergy) / maxEnergy
	local nextUpdate= math.floor(maxUpdateTicks[data.lvl] / energyPercentage)
	if nextUpdate>minimalUpdateTicks then
		nextUpdate = minimalUpdateTicks
	else
		beltSorter.searchInputOutput(entity,data)
		beltSorter.distributeItems(entity,data)
		data.input = nil
		data.output = nil
	end
	return nextUpdate,nil
end


---------------------------------------------------
-- Helper methods
---------------------------------------------------


beltSorter.updateCircuitCondition = function(beltSorter,data)
	-- check circuit
	local behavior = beltSorter.get_or_create_control_behavior()
	local conditionTable = behavior.circuit_condition
	if conditionTable.condition.first_signal.name ~= nil then
		data.condition = conditionTable.fulfilled
	else
		data.condition = true
	end
	
	-- check logistic condition
	if data.condition and behavior.connect_to_logistic_network then
		conditionTable = behavior.logistic_condition
		if conditionTable.condition.first_signal.name ~= nil then
			data.condition = conditionTable.fulfilled
		else
			data.condition = true
		end
	end
	
	local lampCondition = {
		condition = {
			comparator= (data.condition and "=" or ">"),
			first_signal={type="item", name="iron-plate"},
			second_signal={type="item", name="iron-plate"}
		}
	}
	data.lamp.get_control_behavior().circuit_condition = lampCondition
	data.nextConditionUpdate = game.tick + 60
end

beltSorter.distributeItems = function(entity,data)
	-- Search for input (only loop if items available), mostly only 1 input
	for prio = 1,4 do
		local inputSide = data.filter[prio]
		local inputAccess = data.input[inputSide]
		if not inputAccess or not inputAccess:isValid() then
			data.input[inputSide] = nil
		else
			for itemName,_ in pairs(inputAccess:get_contents()) do
				local sideList = data.filter[itemName]
				if sideList then
					beltSorter.distributeItemToSides(data,inputAccess,itemName,sideList)
				else -- item can go nowhere, check rest filter
					sideList = data.filter["belt-sorter-everythingelse"]
					if sideList then
						beltSorter.distributeItemToSides(data,inputAccess,itemName,sideList)
					end
				end
			end
		end
	end
end


beltSorter.distributeItemToSides = function(data,inputAccess,itemName,sideList)
	local itemStack = {name=itemName,count=1}
	for _,arr in pairs(sideList) do
		local side = arr[1]
		local outputOnLanes = arr[2]
		local outputAccess = data.output[side]
		if outputAccess then
			if not outputAccess:isValid() then
				data.output[side] = nil
			else
				beltSorter.insertAsManyAsPossible(inputAccess,outputAccess,itemStack,outputOnLanes)
			end
		end
	end
end

beltSorter.insertAsManyAsPossible = function(inputAccess,outputAccess,itemStack,outputOnLanes)
	local curPos = 0.13
	while curPos <= 1 do
		if outputOnLanes[1] and outputAccess:can_insert_on_at(false,curPos) then
			local result = inputAccess:remove_item(itemStack)
			if result == 0 then	return end
			outputAccess:insert_on_at(false,curPos,itemStack)
		end
		if outputOnLanes[2] and outputAccess:can_insert_on_at(true,curPos) then
			local result = inputAccess:remove_item(itemStack)
			if result == 0 then	return end
			outputAccess:insert_on_at(true,curPos,itemStack)
		end
		curPos = curPos + 0.29
	end
	
end

beltSorter.searchInputOutput = function(beltSorter,data)
	local surface = beltSorter.surface
	local x = beltSorter.position.x
	local y = beltSorter.position.y
	-- search for input and output belts
	data.input = {}
	data.output = {}
	for rowIndex = 1, 4 do
		data.input[rowIndex] = nil -- [side] => BeltAccess or SplitterAccess objects
		data.output[rowIndex] = nil -- [side] => BeltAccess or SplitterAccess objects
		local searchPos = searchPriority[rowIndex]
		local searchPoint = { x = x + searchPos[1], y = y + searchPos[2] }
		for _,searchType in pairs(BeltFactory.supportedTypes) do
			local candidates = surface.find_entities_filtered{position = searchPoint, type= searchType}
			for _,entity in pairs(candidates) do
				local access = BeltFactory.accessFor(entity,searchPoint,beltSorter.position)
				if access:isInput() then
					data.input[rowIndex] = access
				else
					data.output[rowIndex] = access
				end
			end
		end
	end
end
