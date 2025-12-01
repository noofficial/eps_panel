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

local resolvedCommandSpecs = {}
local commandLookup = {}

local defaultAccessDenied = "[EPS] You are not authorized to access the EPS routing grid."
local defaultPrivilegeDenied = "[EPS] Elevated authorization is required for that EPS command."

local rawCommandDescriptors

rawCommandDescriptors = {
    {
        id = "open",
        info = "Open the EPS routing interface.",
        requiresAccess = true,
        resolveCommands = function(cmdConfig)
            return cmdConfig.Chat
        end,
        execute = function(ply)
            if not deps.sendFullState then return end
            if not deps.isPlayerAllowed(ply) then return end
            deps.sendFullState(ply, true)
        end,
        denyMessage = "[EPS] You are not authorized to access the EPS routing grid.",
    },
    {
        id = "natural_spike",
        info = "Trigger a simulated EPS spike (quiet).",
        requiresAccess = true,
        requiresPrivilege = true,
        resolveCommands = function(cmdConfig)
            return cmdConfig.NaturalSpike
        end,
        execute = function(ply)
            triggerManualSpike(ply, { force = false, quiet = false, skipLocalMessage = true })
        end,
        privilegeDenyMessage = "[EPS] Only authorized engineering staff may schedule EPS spikes.",
    },
    {
        id = "forced_spike",
        info = "Force an EPS spike immediately.",
        requiresAccess = true,
        requiresPrivilege = true,
        resolveCommands = function(cmdConfig, fullConfig)
            local spikeCfg = fullConfig.Spikes or {}
            return cmdConfig.ForcedSpike or spikeCfg.ForceCommand
        end,
        execute = function(ply)
            triggerManualSpike(ply, { force = true, quiet = false })
        end,
        privilegeDenyMessage = "[EPS] Forced spikes require chief engineer authorization.",
    },
    {
        id = "natural_damage",
        info = "Trigger a simulated EPS overload.",
        requiresAccess = true,
        requiresPrivilege = true,
        resolveCommands = function(cmdConfig)
            return cmdConfig.NaturalDamage
        end,
        execute = function(ply)
            triggerManualDamage(ply, { force = false, quiet = false })
        end,
        privilegeDenyMessage = "[EPS] Only senior engineering staff may schedule overload drills.",
    },
    {
        id = "forced_damage",
        info = "Force an EPS overload on a random subsystem.",
        requiresAccess = true,
        requiresPrivilege = true,
        resolveCommands = function(cmdConfig)
            return cmdConfig.ForcedDamage or cmdConfig.Damage or "/epsdamage"
        end,
        execute = function(ply)
            triggerManualDamage(ply, { force = true, quiet = false })
        end,
        privilegeDenyMessage = "[EPS] Forced overloads require chief engineer authorization.",
    },
}

local function normalizeCommandList(value)
    if not value then return nil end

    local entries = {}
    local dedupe = {}

    local function addEntry(entry)
        if not isstring(entry) then return end
        local trimmed = string.Trim(entry)
        if trimmed == "" then return end
        if dedupe[trimmed] then return end
        dedupe[trimmed] = true
        table.insert(entries, trimmed)
    end

    if istable(value) then
        for _, entry in ipairs(value) do
            addEntry(entry)
        end
    else
        addEntry(value)
    end

    if #entries == 0 then return nil end
    return entries
end

local function rebuildCommandSpecs()
    resolvedCommandSpecs = {}
    commandLookup = {}

    local fullConfig = EPS.Config or {}
    local cmdConfig = fullConfig.Commands or {}

    for _, descriptor in ipairs(rawCommandDescriptors) do
        local commands = descriptor.resolveCommands and descriptor.resolveCommands(cmdConfig, fullConfig) or nil
        local normalized = normalizeCommandList(commands)
        if normalized then
            local spec = {
                id = descriptor.id,
                info = descriptor.info,
                commands = normalized,
                requiresAccess = descriptor.requiresAccess ~= false,
                requiresPrivilege = descriptor.requiresPrivilege == true,
                denyMessage = descriptor.denyMessage,
                privilegeDenyMessage = descriptor.privilegeDenyMessage,
                execute = descriptor.execute,
            }

            table.insert(resolvedCommandSpecs, spec)
            for _, cmd in ipairs(normalized) do
                commandLookup[string.lower(cmd)] = spec
            end
        end
    end
end

local function notifyPlayer(ply, message)
    if not IsValid(ply) then return end
    if not message or message == "" then return end
    if ply.ChatPrint then
        ply:ChatPrint(message)
    else
        ply:PrintMessage(HUD_PRINTTALK, message)
    end
end

local function checkAccess(spec, ply, silent)
    if not spec then return false end

    if spec.requiresAccess and not deps.isPlayerAllowed(ply) then
        if not silent then
            notifyPlayer(ply, spec.denyMessage or defaultAccessDenied)
        end
        return false
    end

    if spec.requiresPrivilege and not deps.isPlayerPrivileged(ply) then
        if not silent then
            notifyPlayer(ply, spec.privilegeDenyMessage or spec.denyMessage or defaultPrivilegeDenied)
        end
        return false
    end

    return true
end

local function runCommandSpec(spec, ply, args)
    if not spec or not spec.execute then return false end
    if not checkAccess(spec, ply, false) then
        return false
    end
    return spec.execute(ply, args or {}) ~= false
end

local function tryRegisterChatCommands()
    if not Chat or not isfunction(Chat.RegisterCommand) then return false end
    if #resolvedCommandSpecs == 0 then return false end

    local registeredAny = false

    for _, spec in ipairs(resolvedCommandSpecs) do
        Chat:RegisterCommand("eps_" .. spec.id, {
            enabled = true,
            info = spec.info or "EPS command",
            commands = spec.commands,
            execute = function(ply, args)
                runCommandSpec(spec, ply, args)
            end,
            canUse = function(ply)
                return checkAccess(spec, ply, true)
            end,
        })
        registeredAny = true
    end

    return registeredAny
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

    local spec = commandLookup[string.lower(trimmed)]
    if not spec then return end

    runCommandSpec(spec, ply, {})
    return ""
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

    rebuildCommandSpecs()
    local registeredChat = tryRegisterChatCommands()
    hook.Remove("PlayerSay", "EPS_ChatCommand")
    if not registeredChat then
        hook.Add("PlayerSay", "EPS_ChatCommand", handleChatCommand)
    end
    addConsoleCommands()
end

return Commands
