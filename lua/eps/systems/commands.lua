if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Commands = {}

local Util = EPS.Util or {}

local deps = {
    sendFullState = nil,
    isPlayerAllowed = function() return true end,
    isPlayerPrivileged = function(ply) return IsValid(ply) and ply:IsAdmin() end,
    beginSpike = nil,
    scheduleNextSpike = nil,
    pickSubsystemForPanel = nil,
    startSubsystemDamage = nil,
    collectPanelInfos = nil,
    pickRandomPanelInfo = nil,
    rememberPanelForLocation = nil,
}

local function getRandomPanelInfo()
    if deps.pickRandomPanelInfo then
        local info = deps.pickRandomPanelInfo()
        if info and IsValid(info.entity) then
            return info
        end
    end
    if not deps.collectPanelInfos then return nil end
    local infos = deps.collectPanelInfos()
    if not istable(infos) or #infos == 0 then return nil end
    return infos[math.random(#infos)]
end

local function triggerManualSpike(ply, options)
    if not deps.beginSpike then
        if IsValid(ply) and ply.ChatPrint then
            ply:ChatPrint("[EPS] Spike controller unavailable.")
        end
        return false
    end

    options = options or {}

    local context, reason = deps.beginSpike(nil, nil, {
        manual = true,
        resetTimer = true,
        force = options.force ~= false,
    })

    if not context then
        if IsValid(ply) and ply.ChatPrint then
            ply:ChatPrint(string.format("[EPS] Unable to trigger spike: %s", tostring(reason or "unknown")))
        end
        return false
    end
    if options.quiet or options.skipLocalMessage then
        return true
    end

    if IsValid(ply) and ply.ChatPrint then
        local subLabel = context.sub and (context.sub.label or context.sub.id) or (context.target or "EPS subsystem")
        local deckText = context.deck and tostring(context.deck) or "?"
        local sectionName = context.sectionName or "Unknown Section"
        if options.force ~= false then
            ply:ChatPrint(string.format("[EPS] Forced spike on %s (Deck %s, %s).", subLabel, deckText, sectionName))
        else
            ply:ChatPrint(string.format("[EPS] EPS spike reported at %s (Deck %s, %s).", subLabel, deckText, sectionName))
        end
    end

    return true
end

local function triggerManualDamage(ply, options)
    if not deps.startSubsystemDamage then
        if IsValid(ply) and ply.ChatPrint then
            ply:ChatPrint("[EPS] Damage system not available.")
        end
        return false
    end

    local info = getRandomPanelInfo()
    if not info or not IsValid(info.entity) then
        if IsValid(ply) and ply.ChatPrint then
            ply:ChatPrint("[EPS] No valid panel found for damage event.")
        end
        return false
    end

    local targetSubsystem
    if deps.pickSubsystemForPanel then
        targetSubsystem = deps.pickSubsystemForPanel(info)
    end

    if not targetSubsystem then
        if IsValid(ply) and ply.ChatPrint then
            ply:ChatPrint("[EPS] Panel lacks routed subsystems to damage.")
        end
        return false
    end

    local _, normalized = EPS.GetLocationState(info.locationKey)
    if deps.rememberPanelForLocation then
        deps.rememberPanelForLocation(info.entity, normalized)
    end

    options = options or {}

    deps.startSubsystemDamage(normalized, targetSubsystem, 1)
    if deps.scheduleNextSpike then
        deps.scheduleNextSpike()
    end

    if options.quiet then
        return true
    end

    if IsValid(ply) and ply.ChatPrint then
        local sub = EPS.GetSubsystem(targetSubsystem)
        local label = sub and (sub.label or sub.id) or targetSubsystem
        local deckText = info.deck and tostring(info.deck) or "?"
        local sectionName = info.sectionName or "Unknown Section"
        if options.force ~= false then
            ply:ChatPrint(string.format("[EPS] Forced overload on %s (Deck %s, %s).", label, deckText, sectionName))
        else
            ply:ChatPrint(string.format("[EPS] EPS overload detected on %s (Deck %s, %s).", label, deckText, sectionName))
        end
    end

    return true
end

function Commands.TriggerManualSpike(ply)
    return triggerManualSpike(ply)
end

function Commands.TriggerManualDamage(ply)
    return triggerManualDamage(ply)
end

local function handleChatCommand(ply, text)
    local trimmed = string.Trim(text or "")
    if trimmed == "" then return end

    local lowered = string.lower(trimmed)
    local cfg = EPS.Config or {}
    local cmdConfig = cfg.Commands or {}

    local openCmd = cmdConfig.Chat
    if openCmd and openCmd ~= "" and lowered == string.lower(openCmd) then
        if deps.isPlayerAllowed(ply) then
            if deps.sendFullState then
                deps.sendFullState(ply, true)
            end
            return ""
        end
        return
    end

    local naturalSpike = cmdConfig.NaturalSpike
    if naturalSpike and naturalSpike ~= "" and lowered == string.lower(naturalSpike) then
        if IsValid(ply) and not deps.isPlayerPrivileged(ply) then return end
        triggerManualSpike(ply, { force = false, quiet = false, skipLocalMessage = true })
        return ""
    end

    local forcedSpike = cmdConfig.ForcedSpike or (EPS.Config.Spikes and EPS.Config.Spikes.ForceCommand)
    if forcedSpike and forcedSpike ~= "" and lowered == string.lower(forcedSpike) then
        if IsValid(ply) and not deps.isPlayerPrivileged(ply) then return end
        triggerManualSpike(ply, { force = true, quiet = false })
        return ""
    end

    local naturalDamage = cmdConfig.NaturalDamage
    if naturalDamage and naturalDamage ~= "" and lowered == string.lower(naturalDamage) then
        if IsValid(ply) and not deps.isPlayerPrivileged(ply) then return end
        triggerManualDamage(ply, { force = false, quiet = false })
        return ""
    end

    local forcedDamage = cmdConfig.ForcedDamage or cmdConfig.Damage or "/epsdamage"
    if forcedDamage and forcedDamage ~= "" and lowered == string.lower(forcedDamage) then
        if IsValid(ply) and not deps.isPlayerPrivileged(ply) then return end
        triggerManualDamage(ply, { force = true, quiet = false })
        return ""
    end
end

local function addConsoleCommands()
    local cfg = EPS.Config or {}
    local cmdConfig = cfg.Commands or {}
    local openCmd = cmdConfig.ConCommand or "eps_open"

    concommand.Add(openCmd, function(ply)
        if not IsValid(ply) then return end
        if not deps.isPlayerAllowed(ply) then return end
        if deps.sendFullState then
            deps.sendFullState(ply, true)
        end
    end, nil, "Open the EPS routing interface")

    concommand.Add("eps_sync", function(ply)
        if deps.sendFullState then
            if IsValid(ply) then
                deps.sendFullState(ply, false)
            else
                deps.sendFullState(nil, false)
            end
        end
    end, nil, "Sync EPS state to yourself (or everyone from server console)")

    concommand.Add("eps_damage", function(ply)
        if IsValid(ply) and not deps.isPlayerPrivileged(ply) then return end
        triggerManualDamage(ply)
    end, nil, "Force an EPS overload on a random routed subsystem")
end

local installed = false

function Commands.Setup(options)
    if installed then return end
    installed = true

    options = options or {}
    deps.sendFullState = options.sendFullState or deps.sendFullState
    deps.isPlayerAllowed = options.isPlayerAllowed or deps.isPlayerAllowed
    deps.isPlayerPrivileged = options.isPlayerPrivileged or deps.isPlayerPrivileged
    deps.beginSpike = options.beginSpike or deps.beginSpike
    deps.scheduleNextSpike = options.scheduleNextSpike or deps.scheduleNextSpike
    deps.pickSubsystemForPanel = options.pickSubsystemForPanel or deps.pickSubsystemForPanel
    deps.startSubsystemDamage = options.startSubsystemDamage or deps.startSubsystemDamage
    deps.collectPanelInfos = options.collectPanelInfos or deps.collectPanelInfos
    deps.pickRandomPanelInfo = options.pickRandomPanelInfo or deps.pickRandomPanelInfo
    deps.rememberPanelForLocation = options.rememberPanelForLocation or deps.rememberPanelForLocation

    hook.Add("PlayerSay", "EPS_ChatCommand", handleChatCommand)
    addConsoleCommands()
end

return Commands
