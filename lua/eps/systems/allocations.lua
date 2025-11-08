if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Allocations = {}

local deps = {
    isPlayerAllowed = function(ply) return IsValid(ply) and ply:IsAdmin() end,
    handleAllocationChange = nil,
    notifyWatchers = nil,
}

local function clampSubsystemAllocation(id, value)
    if EPS.ClampAllocationForSubsystem then
        return EPS.ClampAllocationForSubsystem(id, value)
    end
    return value
end

function Allocations.Setup(options)
    options = options or {}
    if options.isPlayerAllowed then
        deps.isPlayerAllowed = options.isPlayerAllowed
    end
    deps.handleAllocationChange = options.handleAllocationChange or deps.handleAllocationChange
    deps.notifyWatchers = options.notifyWatchers or deps.notifyWatchers
end

local function buildUpdates(incoming, locKey)
    local updates = {}
    local changes = {}
    local total = 0

    for _, sub in EPS.IterSubsystems() do
        local id = sub.id
        local current = EPS.GetAllocation(locKey, id)
        local requested = incoming[id]
        if requested ~= nil then
            local clamped = clampSubsystemAllocation(id, requested)
            if clamped == nil then
                return nil, nil, string.format("Unknown subsystem '%s'", id)
            end
            updates[id] = clamped
            changes[id] = clamped
            total = total + clamped
        else
            total = total + current
        end
    end

    return updates, changes, total
end

function Allocations.Apply(ply, incoming, locKey)
    incoming = incoming or {}
    if not deps.isPlayerAllowed(ply) then
        return false, "Access denied"
    end

    local _, normalized = EPS.GetLocationState(locKey)
    locKey = normalized

    if EPS.GetMaintenanceState then
        local record = EPS.GetMaintenanceState(locKey)
        if record and record.active and not record.overrideActive then
            if IsValid(ply) and ply.ChatPrint then
                ply:ChatPrint("[EPS] Conduit secured for maintenance; allocations locked until safeties are bypassed.")
            end
            return false, "Conduit secured for maintenance"
        end
    end

    if not EPS.IterSubsystems then
        return false, "Subsystem iterator unavailable"
    end

    local updates, changes, totalOrError = buildUpdates(incoming, locKey)
    if not updates then
        return false, totalOrError
    end

    local budget = EPS.GetBudget(locKey)
    if totalOrError > budget then
        return false, "Requested allocations exceed available EPS budget"
    end

    local changed = false
    for id, value in pairs(updates) do
        if EPS.GetAllocation(locKey, id) ~= value then
            EPS.SetAllocation(locKey, id, value)
            changed = true
        else
            changes[id] = nil
        end
    end

    if changed then
        if EPS._RunChangeHookIfNeeded then
            EPS._RunChangeHookIfNeeded(locKey)
        end
        if deps.handleAllocationChange then
            deps.handleAllocationChange(locKey, changes)
        end
        if deps.notifyWatchers then
            deps.notifyWatchers(locKey)
        end
    else
        for key in pairs(changes) do
            changes[key] = nil
        end
    end

    return true, locKey
end

return Allocations
