EPS = EPS or {}
EPS.Config = EPS.Config or {}

local subsystems = EPS.Config.Subsystems or {}

local function clampToRange(val, minVal, maxVal)
	val = math.floor((val or 0) + 0.5)
	if minVal ~= nil then val = math.max(val, minVal) end
	if maxVal ~= nil then val = math.min(val, maxVal) end
	return val
end

local function getSubsystemBaseMax(sub)
 if not sub then return EPS.Config.MaxBudget or 0 end
 return sub.max or EPS.Config.MaxBudget or 0
end

local function getSubsystemOverdrive(sub)
 local base = getSubsystemBaseMax(sub)
 local over = sub and sub.overdrive or base
 if over < base then over = base end
 return over
end

local function buildDefaultTables()
	local allocations, demand = {}, {}
	for _, sub in ipairs(subsystems) do
		local minVal = sub.min or 0
		local maxVal = getSubsystemBaseMax(sub)
		local default = sub.default
		if default == nil then default = minVal end
		local clamped = clampToRange(default, minVal, maxVal)
		allocations[sub.id] = clamped
		demand[sub.id] = clamped
	end
	return allocations, demand
end

EPS.State = EPS.State or {}

if not EPS.State.allocations or not EPS.State.demand then
	local allocations, demand = buildDefaultTables()
	EPS.State.allocations = allocations
	EPS.State.demand = demand
end

EPS.State.maxBudget = EPS.State.maxBudget or EPS.Config.MaxBudget or 0

local function ensureSubsystemEntries()
	for _, sub in ipairs(subsystems) do
		if EPS.State.allocations[sub.id] == nil then
			EPS.State.allocations[sub.id] = clampToRange(sub.default or sub.min or 0, sub.min, getSubsystemBaseMax(sub))
		end
		if EPS.State.demand[sub.id] == nil then
			EPS.State.demand[sub.id] = EPS.State.allocations[sub.id]
		end
	end
end

ensureSubsystemEntries()

function EPS.ResetState()
	local allocations, demand = buildDefaultTables()
	EPS.State.maxBudget = EPS.Config.MaxBudget or EPS.State.maxBudget or 0
	EPS.State.allocations = allocations
	EPS.State.demand = demand
	if SERVER then
		EPS._playerLayouts = setmetatable({}, { __mode = "k" })
	end
	EPS._lastAllocSnapshot = nil
	EPS._RunChangeHookIfNeeded()
end

function EPS.GetSubsystem(id)
	for _, sub in ipairs(subsystems) do
		if sub.id == id then
			return sub
		end
	end
end

function EPS.IterSubsystems()
	return ipairs(subsystems)
end

function EPS.GetBudget()
	return EPS.State.maxBudget or 0
end

function EPS.GetTotalAllocation()
	local sum = 0
	for _, sub in ipairs(subsystems) do
		sum = sum + (EPS.State.allocations[sub.id] or 0)
	end
	return sum
end

function EPS.GetAllocation(id)
	return (EPS.State.allocations and EPS.State.allocations[id]) or 0
end

function EPS.GetDemand(id)
	return (EPS.State.demand and EPS.State.demand[id]) or EPS.GetAllocation(id)
end

function EPS.ClampAllocationForSubsystem(id, value)
	local sub = EPS.GetSubsystem(id)
	if not sub then return nil end
	return clampToRange(value, sub.min, getSubsystemOverdrive(sub))
end

function EPS.GetSubsystemBaseMax(id)
	local sub = EPS.GetSubsystem(id)
	return getSubsystemBaseMax(sub)
end

function EPS.GetSubsystemOverdrive(id)
	local sub = EPS.GetSubsystem(id)
	return getSubsystemOverdrive(sub)
end

local function deepCopyAlloc()
	local t = {}
	for _, sub in ipairs(subsystems) do
		t[sub.id] = EPS.State.allocations[sub.id] or 0
	end
	return t
end

EPS._lastAllocSnapshot = EPS._lastAllocSnapshot or deepCopyAlloc()

function EPS._RunChangeHookIfNeeded()
	if not EPS.State or not EPS.State.allocations then return end
	if not EPS._lastAllocSnapshot then
		EPS._lastAllocSnapshot = deepCopyAlloc()
	end

	local changed = false
	for _, sub in ipairs(subsystems) do
		local id = sub.id
		local now = EPS.State.allocations[id] or 0
		local prev = EPS._lastAllocSnapshot[id] or -1
		if now ~= prev then
			changed = true
			break
		end
	end

	if changed then
		hook.Run("EPS_PowerChanged", table.Copy(EPS.State.allocations), EPS.State.maxBudget)
		if SERVER and EPS._SyncPanels then
			EPS._SyncPanels()
		end
		EPS._lastAllocSnapshot = deepCopyAlloc()
	end
end

EPS.NET = {
	Open = "EPS_OpenUI",
	Update = "EPS_Update",
	FullState = "EPS_State",
}