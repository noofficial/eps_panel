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

local function getSubsystemDefault(sub)
    if not sub then return 0 end
    local base = sub.default
    if base == nil then base = sub.min or 0 end
    return clampToRange(base, sub.min, getSubsystemBaseMax(sub))
end

local function buildDefaultTables()
    local allocations, demand = {}, {}
    for _, sub in ipairs(subsystems) do
        local default = getSubsystemDefault(sub)
        allocations[sub.id] = default
        demand[sub.id] = default
    end
    return allocations, demand
end

local function ensureTableEntries(target)
    for _, sub in ipairs(subsystems) do
        if target.allocations[sub.id] == nil then
            target.allocations[sub.id] = getSubsystemDefault(sub)
        end
        if target.demand[sub.id] == nil then
            target.demand[sub.id] = getSubsystemDefault(sub)
        end
    end
    if target.maxBudget == nil then
        target.maxBudget = EPS.Config.MaxBudget or 0
    end
end

local function snapshotAllocations(source)
    local snap = {}
    for _, sub in ipairs(subsystems) do
        snap[sub.id] = source.allocations[sub.id] or 0
    end
    return snap
end

EPS.State = EPS.State or {}
EPS.State.locations = EPS.State.locations or {}
EPS.State.locationMeta = EPS.State.locationMeta or {}
EPS.State.maxBudgetDefault = EPS.Config.MaxBudget or (EPS.State.maxBudgetDefault or 0)

EPS._lastAllocSnapshot = EPS._lastAllocSnapshot or {}

local function normalizeSection(sectionName)
    if not sectionName or sectionName == "" then return "" end
    local str = string.lower(tostring(sectionName))
    str = string.Trim(str)
    return str
end

function EPS.NormalizeLocationKey(deck, sectionName)
    local deckStr = deck and tostring(deck) or "?"
    local sectionStr = normalizeSection(sectionName)
    if sectionStr == "" then
        sectionStr = "unknown"
    end
    return string.format("%s::%s", deckStr, sectionStr)
end

local function ensureLocationState(locKey)
    if not locKey or locKey == "" then
        locKey = "global"
    end

    local normalized = string.lower(locKey)
    local locations = EPS.State.locations

    if not locations["global"] then
        local allocations, demand = buildDefaultTables()
        local base = {
            maxBudget = EPS.Config.MaxBudget or EPS.State.maxBudgetDefault or 0,
            allocations = allocations,
            demand = demand,
        }
        locations["global"] = base
        EPS._lastAllocSnapshot["global"] = snapshotAllocations(base)
    end

    local state = locations[normalized]
    if not state then
        if normalized == "global" then
            state = locations["global"]
        else
            local base = locations["global"]
            state = {
                maxBudget = base.maxBudget,
                allocations = table.Copy(base.allocations),
                demand = table.Copy(base.demand),
            }
            locations[normalized] = state
        end
        EPS._lastAllocSnapshot[normalized] = snapshotAllocations(state)
    else
        ensureTableEntries(state)
        if not EPS._lastAllocSnapshot[normalized] then
            EPS._lastAllocSnapshot[normalized] = snapshotAllocations(state)
        end
    end

    return normalized, locations[normalized]
end

function EPS.GetLocationState(locKey)
    local key, state = ensureLocationState(locKey)
    return state, key
end

function EPS.SetLocationMeta(locKey, meta)
    if not locKey then return end
    EPS.State.locationMeta[string.lower(locKey)] = meta
end

function EPS.ResetState()
    EPS.State.locations = {}
    EPS.State.locationMeta = {}
    EPS._lastAllocSnapshot = {}
    if SERVER then
        EPS._playerLayouts = setmetatable({}, { __mode = "k" })
        EPS._overpowerWatch = {}
        EPS._recentPanelByLocation = setmetatable({}, { __mode = "v" })
        EPS._lastPanelPerPlayer = setmetatable({}, { __mode = "kv" })
        if EPS._damageStates then
            for _, state in pairs(EPS._damageStates) do
                if state then
                    if state.fireEnt and IsValid(state.fireEnt) then
                        state.fireEnt:Fire("Extinguish", "", 0)
                        state.fireEnt:Remove()
                    end
                    local panel = state.panel
                    if IsValid(panel) and panel._epsDamage then
                        panel._epsDamage[state.key or state.id] = nil
                        if next(panel._epsDamage) == nil then
                            panel._epsDamage = nil
                        end
                    end
                end
            end
            EPS._damageStates = {}
        end
        EPS._maintenanceLocks = {}
    end
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

function EPS.GetBudget(locKey)
    local state = EPS.GetLocationState(locKey)
    return state.maxBudget or 0
end

function EPS.SetBudget(locKey, value)
    local state = EPS.GetLocationState(locKey)
    local clamped = math.max(0, math.floor((value or 0) + 0.5))
    state.maxBudget = clamped
    for key, other in pairs(EPS.State.locations) do
        if other ~= state then
            other.maxBudget = clamped
        end
    end
end

function EPS.GetTotalAllocation(locKey)
    local state = EPS.GetLocationState(locKey)
    local sum = 0
    for _, sub in ipairs(subsystems) do
        sum = sum + (state.allocations[sub.id] or 0)
    end
    return sum
end

function EPS.GetAllocation(locKey, id)
    local state = EPS.GetLocationState(locKey)
    return state.allocations[id] or 0
end

function EPS.SetAllocation(locKey, id, value)
    local state = EPS.GetLocationState(locKey)
    state.allocations[id] = value
    for key, other in pairs(EPS.State.locations) do
        if other ~= state and other.allocations then
            other.allocations[id] = value
        end
    end
end

function EPS.GetDemand(locKey, id)
    local state = EPS.GetLocationState(locKey)
    local val = state.demand[id]
    if val ~= nil then
        return val
    end
    local def = EPS.GetSubsystemDefault and EPS.GetSubsystemDefault(id)
    return def or EPS.GetAllocation(locKey, id)
end

function EPS.SetDemand(locKey, id, value)
    local state = EPS.GetLocationState(locKey)
    state.demand[id] = value
    for key, other in pairs(EPS.State.locations) do
        if other ~= state and other.demand then
            other.demand[id] = value
        end
    end
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

function EPS.GetSubsystemDefault(id)
    local sub = EPS.GetSubsystem(id)
    return getSubsystemDefault(sub)
end

local function updateSnapshot(locKey, state)
    EPS._lastAllocSnapshot[locKey] = snapshotAllocations(state)
end

function EPS._RunChangeHookIfNeeded(locKey)
    local normalized, state = ensureLocationState(locKey)
    local snapshot = EPS._lastAllocSnapshot[normalized]
    local changed = false
    if not snapshot then
        snapshot = snapshotAllocations(state)
        EPS._lastAllocSnapshot[normalized] = snapshot
    else
        for _, sub in ipairs(subsystems) do
            local id = sub.id
            local now = state.allocations[id] or 0
            local prev = snapshot[id]
            if prev == nil or prev ~= now then
                changed = true
                break
            end
        end
    end

    if changed then
        updateSnapshot(normalized, state)
        local copy = table.Copy(state.allocations)
        hook.Run("EPS_PowerChanged", copy, state.maxBudget, normalized)
        if SERVER and EPS._SyncPanels then
            EPS._SyncPanels(normalized)
        end
    end
end

EPS.NET = {
    Open = "EPS_OpenUI",
    Update = "EPS_Update",
    FullState = "EPS_State",
}