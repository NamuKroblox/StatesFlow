-- StateManager.lua
local StateManager = {}
StateManager.__index = StateManager

export type Listener = (key: string, value: any, prev: any) -> ()

local DEBUG = false
local function dprint(...)
	if DEBUG then
		print("[StateManager]", ...)
	end
end
local function dwarn(...)
	if DEBUG then
		warn("[StateManager WARNING]", ...)
	end
end

function StateManager.new(initialState: { [string]: any }?)
	local self = setmetatable({}, StateManager)

	self._state = initialState or {}
	self._globalListeners = {}
	self._keyListeners = {}

	dprint("Created new manager with state", self._state)

	return self
end

-- Get whole state or specific key
function StateManager:Get(key: string?)
	if key then
		dprint("Get(", key, ") ->", self._state[key])
		return self._state[key]
	end

	dprint("GetAll reference returned")
	return self._state
end

function StateManager:GetAll()
	local clone = table.clone(self._state)
	dprint("GetAll() -> clone returned size =", #clone)
	return clone
end

-- Set value (only fires if changed)
function StateManager:Set(key: string, value: any)
	local prev = self._state[key]
	if prev == value then
		dprint("Set skipped, no change:", key, "=", value)
		return
	end

	self._state[key] = value
	dprint("Set:", key, "=", value, "(prev =", prev, ")")

	-- Fire key listeners
	local list = self._keyListeners[key]
	if list then
		dprint("Firing", #list, "key listeners for", key)
		for _, fn in ipairs(list) do
			local ok, err = pcall(fn, value, prev)
			if not ok then
				dwarn("Key listener error:", err)
			end
		end
	end

	-- Fire global listeners
	dprint("Firing", #self._globalListeners, "global listeners for", key)
	for _, fn in ipairs(self._globalListeners) do
		local ok, err = pcall(fn, value, prev, key)
		if not ok then
			dwarn("Global listener error:", err)
		end
	end
end

-- Listen to a specific key
function StateManager:OnChanged(key: string, callback: (value: any, prev: any) -> ())
	local list = self._keyListeners[key]
	if not list then
		list = {}
		self._keyListeners[key] = list
	end

	table.insert(list, callback)
	dprint("Added key listener for", key, "-> total:", #list)

	-- Cleanup handle
	return function()
		for i, fn in ipairs(list) do
			if fn == callback then
				table.remove(list, i)
				dprint("Removed key listener for", key, "-> total:", #list)
				break
			end
		end
	end
end

function StateManager:SetMany(tbl: { [string]: any })
	if not tbl then
		return
	end

	local changedCount = 0

	local state = self._state
	local keyListeners = self._keyListeners
	local globalListeners = self._globalListeners

	for key, newValue in pairs(tbl) do
		local prev = state[key]
		if prev ~= newValue then
			state[key] = newValue
			changedCount += 1

			dprint("SetMany changed:", key, "=", newValue, "(prev =", prev, ")")

			local list = keyListeners[key]
			if list then
				dprint("Firing", #list, "key listeners for", key)
				for i = 1, #list do
					local fn = list[i]
					local ok, err = pcall(fn, newValue, prev)
					if not ok then
						dwarn("StateManager key listener error:", err)
					end
				end
			end

			for i = 1, #globalListeners do
				local fn = globalListeners[i]
				local ok, err = pcall(fn, newValue, prev, key)
				if not ok then
					dwarn("StateManager global listener error:", err)
				end
			end
		else
			dprint("SetMany skipped (same value):", key)
		end
	end

	dprint("SetMany completed. Keys changed =", changedCount)
end

-- Listen to ANY change
function StateManager:OnAnyChanged(callback: Listener)
	table.insert(self._globalListeners, callback)
	dprint("Added global listener -> total:", #self._globalListeners)

	return function()
		for i, fn in ipairs(self._globalListeners) do
			if fn == callback then
				table.remove(self._globalListeners, i)
				dprint("Removed global listener -> total:", #self._globalListeners)
				break
			end
		end
	end
end

return StateManager
