-- ServerScriptService/StateService.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.knit)
local Helper = require(ReplicatedStorage.Shared.Utils.Helpers.Helper)
local StateManager = require(ReplicatedStorage.Shared.Utils.States.StateManager)

local DEBUG = true

local function dprint(...)
	if DEBUG then
		print("[StateService]", ...)
	end
end
local function dwarn(...)
	if DEBUG then
		warn("[StateService WARNING]", ...)
	end
end

local MIN_CLIENT_REQUEST_INTERVAL = 0.05

local StateService = {
	Name = "StateService",
	Client = {
		StateChanged = Knit.CreateSignal(), -- payload = { entity = instance, changes = table }
		InitialSnapshot = Knit.CreateSignal(), -- payload = { list = { { entity, state } } }
	},
}

-- Weak storage maps prevent memory leaks
local entityManagers = setmetatable({}, { __mode = "k" }) -- [Instance] = StateManager
local pendingChanges = setmetatable({}, { __mode = "k" }) -- [Instance] = { key = value }
local lastClientRequest = setmetatable({}, { __mode = "k" }) -- [Player] = map

------------------------------------------------------
-- MANAGER + CHANGE HOOK
------------------------------------------------------
local function getManager(entity)
	if not entity or not entity.Parent then
		warn("not entity parent")
		return
	end

	local sm = entityManagers[entity]
	if sm then
		return sm
	end

	sm = StateManager.new(nil)
	entityManagers[entity] = sm

	-- Hook any-change to batch replication
	sm:OnAnyChanged(function(new, _, key)
		local bucket = pendingChanges[entity]
		if not bucket then
			bucket = {}
			pendingChanges[entity] = bucket
		end
		bucket[key] = new
	end)

	local con
	if con then
		con:Disconnect()
		con = nil
	end
	con = entity.AncestryChanged:Connect(function(_, parent)
		if not parent then
			entityManagers[entity] = nil
			pendingChanges[entity] = nil
			con:Disconnect()
			con = nil
			dprint("Clean cleanup entity:", entity)
		end
	end)

	return sm
end

------------------------------------------------------
-- INITIAL SNAPSHOT
------------------------------------------------------
local function sendInitialSnapshot(player)
	local list = {}

	for entity, sm in pairs(entityManagers) do
		local state = sm:GetAll()
		if next(state) then
			table.insert(list, { entity = entity, state = state })
		end
	end

	StateService.Client.InitialSnapshot:Fire(player, { list = list })
end

------------------------------------------------------
-- SERVER AUTHORITATIVE API
------------------------------------------------------
function StateService:Set(entity, key, value)
	local sm = getManager(entity)
	if not sm then
		return
	end
	sm:Set(key, value)
end

function StateService:SetMany(entity, tbl)
	local sm = getManager(entity)
	if not sm then
		return
	end
	sm:SetMany(tbl)
end

function StateService:Get(entity, key)
	local sm = entityManagers[entity]
	if not sm then
		return {}
	end
	return sm:Get(key)
end

function StateService:GetAll(entity)
	local sm = entityManagers[entity]
	if not sm then
		return {}
	end
	return sm:GetAll()
end

function StateService:OnChanged(entity, key, callback)
	local sm = getManager(entity)
	if not sm then
		return function() end
	end

	return sm:OnChanged(key, callback)
end

------------------------------------------------------
-- CLIENT REQUEST MUTATIONS (SAFE)
------------------------------------------------------
function StateService.Client:RequestSet(player, entity, key, value)
	if not player or not player:IsA("Player") then
		return
	end

	if entity == nil then
		warn("entity is nil")
	end
	if typeof(entity) ~= "Instance" or type(key) ~= "string" then
		dwarn("Bad request from", player.Name)
		return
	end

	-- entity must exist & be tracked
	local sm = getManager(entity)
	if not sm then
		dwarn("Client requested entity that is not managed", player.Name)
		return
	end

	-- rate limit per key per entity
	local stampMap = lastClientRequest[player]
	if not stampMap then
		stampMap = {}
		lastClientRequest[player] = stampMap
	end

	local id = tostring(entity) .. ":" .. key
	local now = tick()
	local last = stampMap[id] or 0

	if now - last < MIN_CLIENT_REQUEST_INTERVAL then
		dwarn("Rate block", player.Name, key)
		return
	end

	stampMap[id] = now

	-- ownership: only allow modifying own character
	if entity:IsA("Model") and entity:FindFirstChild("Humanoid") then
		if entity ~= player.Character then
			dwarn("Tried modifying different character", player.Name)
			return
		end
	end

	-- apply
	local ok, err = pcall(function()
		getManager(entity):Set(key, value)
	end)

	if not ok then
		dwarn("Request failed:", err)
	end
end

------------------------------------------------------
-- BATCH REPLICATION LOOP
------------------------------------------------------

function StateService:KnitStart()
	Players.PlayerAdded:Connect(sendInitialSnapshot)
	Players.PlayerRemoving:Connect(function(p)
		lastClientRequest[p] = nil
	end)

	RunService.Heartbeat:Connect(function()
		for entity, changes in pairs(pendingChanges) do
			if entity and entity.Parent and next(changes) then
				local packet = {
					entity = entity,
					changes = Helper.ShallowClone(changes),
				}

				StateService.Client.StateChanged:FireAll(packet)

				for k in pairs(changes) do
					changes[k] = nil
				end
			end
		end
	end)
end

return StateService
