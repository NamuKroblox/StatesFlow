-- Client/StateController.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.knit)
local StateManager = require(ReplicatedStorage.Shared.Utils.States.StateManager)

local DEBUG = false
local function dprint(...)
	if DEBUG then
		print("[StateController]", ...)
	end
end
local function dwarn(...)
	if DEBUG then
		warn("[StateController WARNING]", ...)
	end
end

local StateController = Knit.CreateController({
	Name = "StateController",
	_managers = setmetatable({}, { __mode = "k" }), -- [Instance] = StateManager
	_conns = setmetatable({}, { __mode = "k" }), -- [Instance] = connection (AncestryChanged)
	_stateService = nil, -- Knit service ref
	_pendingPredictions = setmetatable({}, { __mode = "k" }), -- [Instance][key] = prediction
	_predictionSeq = 0,
})

-- Internal: get or create a StateManager for an entity
function StateController:_getManager(entity, createIfMissing: boolean)
	if not entity or typeof(entity) ~= "Instance" then
		return nil
	end

	local sm = self._managers[entity]
	if sm or not createIfMissing then
		return sm
	end

	sm = StateManager.new()
	self._managers[entity] = sm

	-- cleanup when entity is removed from the world
	local con
	con = entity.AncestryChanged:Connect(function(_, parent)
		if not parent then
			dprint("Entity removed; cleaning manager:", entity)
			-- disconnect connection
			if con then
				con:Disconnect()
				con = nil
			end
			self._managers[entity] = nil
			self._conns[entity] = nil
		end
	end)
	self._conns[entity] = con

	dprint("Created local StateManager for", entity)
	return sm
end

-- Internal: apply a state changes table { [key] = newValue }
function StateController:_applyChangesToManager(entity, changes)
	if not entity or typeof(entity) ~= "Instance" or type(changes) ~= "table" then
		return
	end

	local sm = self:_getManager(entity, true)
	-- Use SetMany so we fire key/global listeners in StateManager
	sm:SetMany(changes)
end

-- Handle initial snapshot sent by server (payload { list = { { entity, state } } })
function StateController:_handleInitialSnapshot(payload)
	if not payload or type(payload) ~= "table" then
		return
	end

	local list = payload.list or {}
	dprint("InitialSnapshot received. entries:", #list)

	for _, item in ipairs(list) do
		local entity, state = item.entity, item.state
		if entity and typeof(entity) == "Instance" and type(state) == "table" and next(state) then
			local sm = self:_getManager(entity, true)
			-- SetMany will only fire for actual differences
			sm:SetMany(state)
		end
	end
end

function StateController:_predict(entity, key, value)
	local sm = self:_getManager(entity, true)

	self._predictionSeq += 1
	local seq = self._predictionSeq

	self._pendingPredictions[entity] = self._pendingPredictions[entity] or {}
	self._pendingPredictions[entity][key] = {
		predicted = value,
		seq = seq,
	}

	-- Apply prediction immediately
	sm:Set(key, value)

	dprint("Predicted", entity, key, value, "seq:", seq)
end

function StateController:_handleStateChanged(packet)
	if not packet then
		return
	end

	local entity = packet.entity
	local changes = packet.changes
	if typeof(entity) ~= "Instance" or type(changes) ~= "table" then
		dwarn("Bad StateChanged packet")
		return
	end

	local sm = self:_getManager(entity, true)
	local pendingForEntity = self._pendingPredictions[entity]

	for key, serverValue in pairs(changes) do
		local prediction = pendingForEntity and pendingForEntity[key]

		if prediction then
			if prediction.predicted == serverValue then
				-- Prediction confirmed
				dprint("Prediction confirmed:", entity, key)
			else
				-- Mismatch → reconcile
				dwarn("Prediction mismatch:", entity, key, "predicted:", prediction.predicted, "server:", serverValue)

				sm:Set(key, serverValue)
			end

			-- Clear prediction
			pendingForEntity[key] = nil
		else
			-- No prediction → normal authoritative update
			sm:Set(key, serverValue)
		end
	end
end

-----------------------
-- Public API
-----------------------

-- Subscribe to a specific key on an entity.
-- Returns a disconnect function.
function StateController:Subscribe(entity, key, callback)
	if typeof(entity) ~= "Instance" or type(key) ~= "string" or type(callback) ~= "function" then
		error("Subscribe: bad args")
	end

	local sm = self:_getManager(entity, true)
	-- StateManager:OnChanged returns a cleanup function
	local cleanup = sm:OnChanged(key, callback)
	dprint("Subscribe ->", entity, key)
	return cleanup
end

-- Subscribe to any key-change on the entity.
-- Callback signature: (newValue, prevValue, key)
-- Returns a disconnect function.
function StateController:SubscribeAny(entity, callback)
	if typeof(entity) ~= "Instance" or type(callback) ~= "function" then
		error("SubscribeAny: bad args")
	end

	local sm = self:_getManager(entity, true)
	local cleanup = sm:OnAnyChanged(callback)
	dprint("SubscribeAny ->", entity)
	return cleanup
end

-- Read a single key locally (may be nil if not present)
function StateController:Get(entity, key)
	if typeof(entity) ~= "Instance" then
		return nil
	end
	local sm = self._managers[entity]
	if not sm then
		return nil
	end
	return sm:Get(key)
end

-- Get a safe copy of the full state for an entity
function StateController:GetAll(entity)
	if typeof(entity) ~= "Instance" then
		return {}
	end
	local sm = self._managers[entity]
	if not sm then
		return {}
	end
	return sm:GetAll()
end

-- Request that the server set a single key (goes through server-side validation & rate-limits).
-- Safety: the server does final validation.
function StateController:RequestSet(entity, key, value, Predict)
	if typeof(entity) ~= "Instance" or type(key) ~= "string" then
		dwarn("RequestSetPredicted bad args")
		return
	end

	if Predict then
		-- Predict locally
		self:_predict(entity, key, value)
	end

	-- Send to server
	local ok, err = pcall(function()
		self._stateService:RequestSet(entity, key, value)
	end)
	if not ok then
		dwarn("RequestSetPredicted failed:", err)
	end
end

-- Request many keys: sends multiple RequestSet calls (server-side SetMany not exposed to clients)
-- If you want efficient bulk requests, add a RequestSetMany on the server.
function StateController:RequestSetMany(entity, tbl)
	if not self._stateService then
		dwarn("RequestSetMany called before StateService ready")
		return
	end
	if typeof(entity) ~= "Instance" or type(tbl) ~= "table" then
		dwarn("RequestSetMany bad args")
		return
	end

	-- simple loop: server will rate-limit by key; consider local batching if necessary
	for k, v in pairs(tbl) do
		self:RequestSet(entity, k, v)
	end
end

-----------------------
-- Knit lifecycle
-----------------------

function StateController:KnitInit()
	-- resolve service
	local ok, service = pcall(function()
		return Knit.GetService("StateService")
	end)
	if not ok or not service then
		error("StateController: failed to get StateService")
	end
	self._stateService = service
end

function StateController:KnitStart()
	-- Hook signals exposed by server's Client table
	-- Note: Knit maps server signals to client-side events.
	-- Using :Connect to avoid overwriting other consumers.

	self._stateService.InitialSnapshot:Connect(function(player, payload)
		-- server fires player-specific; ensure it's for us
		-- some Knit configs pass player param automatically; handle both shapes
		-- if first arg is player object, we ignore it on client
		if typeof(player) == "Instance" and player:IsA("Player") then
			-- payload is second param
			self:_handleInitialSnapshot(payload)
		else
			-- payload came as first arg
			self:_handleInitialSnapshot(player)
		end
	end)

	-- State changes (server broadcasts)

	self._stateService.StateChanged:Connect(function(packet)
		self:_handleStateChanged(packet)
	end)

	dprint("KnitStart complete; StateController ready")
end

return StateController
