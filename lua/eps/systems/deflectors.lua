if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Deflectors = EPS.Deflectors or {}
EPS.Deflectors = Deflectors

local function copyMap(source)
    local out = {}
    for key, value in pairs(source or {}) do
        if istable(value) then
            local inner = {}
            for k, v in pairs(value) do
                inner[k] = v
            end
            out[key] = inner
        else
            out[key] = value
        end
    end
    return out
end

local function normalizeKey(locKey)
    if not locKey or locKey == "" then
        return "global"
    end
    return string.lower(locKey)
end

local function buildTracked()
    if Deflectors._tracked then return Deflectors._tracked end

    local tracked = {}
    local cfg = EPS.Config and EPS.Config.Deflectors or {}

    local function addEntry(id, entry)
        if entry == false then return end
        local subsystem
        local label
        local threshold = 0

        if istable(entry) then
            subsystem = entry.subsystem or entry.id or id
            label = entry.label or subsystem or id
            threshold = tonumber(entry.threshold or entry.minPower or entry.min or 0) or 0
        elseif isstring(entry) then
            subsystem = entry
            label = entry
        elseif entry ~= nil then
            subsystem = tostring(entry)
            label = subsystem
        end

        if subsystem then
            tracked[id] = {
                subsystem = string.lower(subsystem),
                label = label or subsystem,
                threshold = threshold,
            }
        end
    end

    for id, entry in pairs(cfg) do
        addEntry(id, entry)
    end

    if next(tracked) == nil then
        tracked.main = { subsystem = "main_deflector", label = "Main Deflector", threshold = 0 }
        tracked.secondary = { subsystem = "secondary_deflector", label = "Secondary Deflector", threshold = 0 }
    end

    Deflectors._tracked = tracked
    return tracked
end

local function ensureStatusTable()
    Deflectors._status = Deflectors._status or {}
    return Deflectors._status
end

local function updateGlobalFlags(deflectorId, status, locKey)
    EPS.DeflectorStatus = EPS.DeflectorStatus or {}
    EPS.DeflectorStatus[deflectorId] = status

    if deflectorId == "main" or deflectorId == "main_deflector" then
        EPS.MainDeflectorOnline = status.online
        EPS.MainDeflectorAllocation = status.allocation
    elseif deflectorId == "secondary" or deflectorId == "secondary_deflector" then
        EPS.SecondaryDeflectorOnline = status.online
        EPS.SecondaryDeflectorAllocation = status.allocation
    end

    EPS.DeflectorLocations = EPS.DeflectorLocations or {}
    EPS.DeflectorLocations[locKey or "global"] = EPS.DeflectorLocations[locKey or "global"] or {}
    EPS.DeflectorLocations[locKey or "global"][deflectorId] = status
end

local function emit(deflectorId, status, locKey)
    updateGlobalFlags(deflectorId, status, locKey)
    hook.Run("EPS_DeflectorStatusChanged", deflectorId, status.online, locKey, status.allocation or 0, status)
    if not status.online then
        hook.Run("EPS_DeflectorOffline", deflectorId, locKey, status)
    end
end

local function updateForLocation(locKey, allocations, suppressEmit)
    local tracked = buildTracked()
    local statusMap = ensureStatusTable()
    locKey = normalizeKey(locKey)

    statusMap[locKey] = statusMap[locKey] or {}
    local locationStatus = statusMap[locKey]

    local changed = {}

    for id, info in pairs(tracked) do
        local subId = info.subsystem or id
        local threshold = info.threshold or 0
        local allocation = allocations and allocations[subId] or 0
        local online = (allocation or 0) > threshold
        local record = locationStatus[id]

        if not record or record.online ~= online or record.allocation ~= allocation then
            record = record or {}
            record.online = online
            record.allocation = allocation or 0
            record.threshold = threshold
            record.subsystem = subId
            record.label = info.label or subId
            locationStatus[id] = record

            if not suppressEmit then
                changed[#changed + 1] = { id = id, status = record }
            end
        end
    end

    if not suppressEmit then
        for _, entry in ipairs(changed) do
            emit(entry.id, entry.status, locKey)
        end
    end
end

local function broadcastLocation(locKey)
    locKey = normalizeKey(locKey)
    local statusMap = Deflectors._status and Deflectors._status[locKey]
    if not statusMap then return end

    for id, status in pairs(statusMap) do
        emit(id, status, locKey)
    end
end

function Deflectors.Refresh(locKey)
    if locKey then
        local state, normalized = EPS.GetLocationState(locKey)
        local allocations = state and state.allocations or {}
        updateForLocation(normalized or locKey, allocations, true)
        return
    end

    if EPS.State and EPS.State.locations then
        for key, state in pairs(EPS.State.locations) do
            updateForLocation(key, state and state.allocations or {}, true)
        end
    else
        local state, normalized = EPS.GetLocationState(nil)
        updateForLocation(normalized or "global", state and state.allocations or {}, true)
    end
end

function Deflectors.Broadcast(locKey)
    if locKey then
        broadcastLocation(locKey)
        return
    end

    if not Deflectors._status then return end
    for key in pairs(Deflectors._status) do
        broadcastLocation(key)
    end
end

function Deflectors.HandlePowerChanged(allocations, budget, locKey)
    updateForLocation(locKey or "global", allocations or {})
end

function Deflectors.Setup()
    if Deflectors._setup then return end
    Deflectors._setup = true

    buildTracked()
    Deflectors.Refresh(nil)
    Deflectors.Broadcast(nil)

    hook.Add("EPS_PowerChanged", "EPS_DeflectorPowerWatcher", function(allocations, budget, locKey)
        Deflectors.HandlePowerChanged(allocations, budget, locKey)
    end)
end

function Deflectors.GetStatus(deflectorId, locKey)
    if not deflectorId then return nil end
    local statusMap = Deflectors._status
    if not statusMap then return nil end
    locKey = normalizeKey(locKey)
    local locationStatus = statusMap[locKey]
    if not locationStatus then return nil end
    return locationStatus[deflectorId]
end

function Deflectors.IsOnline(deflectorId, locKey)
    local status = Deflectors.GetStatus(deflectorId, locKey)
    if not status then return false end
    return status.online and (status.allocation or 0) > (status.threshold or 0)
end

function Deflectors.GetTracked()
    local tracked = buildTracked()
    return copyMap(tracked)
end

return Deflectors
