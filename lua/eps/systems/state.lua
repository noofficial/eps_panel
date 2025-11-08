if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Layout = include("eps/systems/layout.lua")
local Panels = include("eps/systems/panels.lua")

local State = {}

local Util = EPS.Util or {}

local clampToUInt = Util.ClampToUInt or function(value, bits)
    local num = math.floor(tonumber(value) or 0)
    if num < 0 then
        num = 0
    end
    local maxValue = bit.lshift(1, bits or 16) - 1
    if num > maxValue then
        num = maxValue
    end
    return num
end

local function sanitizeLayout(layout)
    return Layout.SanitizeLayout(layout or {}, true)
end

function State.NormalizeRecipients(target)
    if target == true or target == nil then
        target = player.GetHumans()
    end

    if istable(target) then
        local recipients = {}
        for _, entry in ipairs(target) do
            if IsValid(entry) and entry:IsPlayer() then
                recipients[#recipients + 1] = entry
            end
        end
        return recipients
    end

    if IsValid(target) and target:IsPlayer() then
        return { target }
    end

    return {}
end

function State.GetPlayerLayout(ply)
    EPS._playerLayouts = EPS._playerLayouts or setmetatable({}, { __mode = "k" })

    local cache = EPS._playerLayouts[ply]
    if cache and cache.layout and #cache.layout > 0 then
        return cache.layout, cache.locKey, cache.meta
    end

    local meta = {}
    local layout
    local locKey

    local lastPanel = EPS._lastPanelPerPlayer and EPS._lastPanelPerPlayer[ply] or nil
    local info = IsValid(lastPanel) and Panels.GetPanelInfo(lastPanel) or nil

    if info then
        meta.deck = info.deck
        meta.section = info.sectionName
        meta.sectionId = info.sectionId
        meta.panelId = info.panelId
        layout = sanitizeLayout(info.layout or {})
        locKey = info.locationKey or info.locationKeyLower
    else
        layout = sanitizeLayout({})
        locKey = nil
    end

    if not layout or #layout == 0 then
        layout = sanitizeLayout({})
    end

    local _, normalized = EPS.GetLocationState(locKey)
    locKey = normalized

    cache = {
        layout = layout,
        locKey = locKey,
        meta = meta,
    }

    EPS._playerLayouts[ply] = cache

    return layout, locKey, meta
end

local function writeSubsystemState(layout, locKey)
    net.WriteUInt(clampToUInt(#layout, 8), 8)

    for _, id in ipairs(layout) do
        local sub = EPS.GetSubsystem(id)
        if sub then
            local baseMax = EPS.GetSubsystemBaseMax and EPS.GetSubsystemBaseMax(sub.id) or (sub.max or EPS.Config.MaxBudget or 0)
            local overdrive = EPS.GetSubsystemOverdrive and EPS.GetSubsystemOverdrive(sub.id) or baseMax
            if overdrive < baseMax then
                overdrive = baseMax
            end

            net.WriteString(sub.id)
            net.WriteString(sub.label or "")
            net.WriteUInt(clampToUInt(sub.min or 0, 16), 16)
            net.WriteUInt(clampToUInt(baseMax or 0, 16), 16)
            net.WriteUInt(clampToUInt(overdrive or 0, 16), 16)
            net.WriteUInt(clampToUInt(EPS.GetAllocation(locKey, sub.id), 16), 16)
            net.WriteUInt(clampToUInt(EPS.GetDemand(locKey, sub.id), 16), 16)
        end
    end
end

function State.SendFullStateToPlayer(ply, shouldOpen)
    if not EPS.State then return end
    if not IsValid(ply) or not ply:IsPlayer() then return end

    local layout, locKey, meta = State.GetPlayerLayout(ply)
    layout = layout or {}

    if #layout == 0 then
        layout = sanitizeLayout({})
    end

    if not locKey or locKey == "" then
        local _, normalized = EPS.GetLocationState(nil)
        locKey = normalized
    end

    local deckLabel = meta and meta.deck and tostring(meta.deck) or ""
    local sectionLabel = meta and meta.section or ""

    local budget = EPS.GetBudget(locKey)
    local totalAlloc = EPS.GetTotalAllocation(locKey)

    net.Start(EPS.NET.FullState)
    net.WriteBool(shouldOpen or false)
    net.WriteString(locKey or "")
    net.WriteString(deckLabel)
    net.WriteString(sectionLabel)
    net.WriteUInt(clampToUInt(budget, 16), 16)
    net.WriteUInt(clampToUInt(totalAlloc, 16), 16)

    writeSubsystemState(layout, locKey)

    net.Send(ply)
end

local function flushFullStateQueue()
    if not EPS._pendingFullState then return end
    local queue = EPS._pendingFullState
    EPS._pendingFullState = setmetatable({}, { __mode = "k" })
    for ply, data in pairs(queue) do
        if IsValid(ply) and ply:IsPlayer() then
            State.SendFullStateToPlayer(ply, data and data.open)
        end
    end
end

local function queueFullState(ply, shouldOpen)
    EPS._pendingFullState = EPS._pendingFullState or setmetatable({}, { __mode = "k" })
    EPS._pendingFullState[ply] = {
        open = shouldOpen or false,
    }

    if not EPS._pendingFullStateTimer then
        EPS._pendingFullStateTimer = true
        timer.Simple(0, function()
            EPS._pendingFullStateTimer = false
            flushFullStateQueue()
        end)
    end
end

function State.SendFullState(target, shouldOpen)
    local recipients = State.NormalizeRecipients(target)
    if #recipients == 0 then return end
    for _, ply in ipairs(recipients) do
        queueFullState(ply, shouldOpen)
    end
end

function State.NotifyWatchers(locKey)
    local watchers = {}
    for ply, cache in pairs(EPS._playerLayouts or {}) do
        if IsValid(ply) and ply:IsPlayer() and cache and cache.locKey == locKey then
            watchers[#watchers + 1] = ply
        end
    end
    if #watchers > 0 then
        State.SendFullState(watchers, false)
    end
end

function State.ClearPlayer(ply)
    if EPS._playerLayouts then
        EPS._playerLayouts[ply] = nil
    end
    if EPS._pendingFullState then
        EPS._pendingFullState[ply] = nil
    end
    if EPS._lastPanelPerPlayer then
        EPS._lastPanelPerPlayer[ply] = nil
    end
end

EPS.BroadcastState = State.SendFullState

return State
