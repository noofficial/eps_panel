if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Hooks = {}

local function setupAllocations(modules, utilLib)
    local Allocations = modules.Allocations
    local Spikes = modules.Spikes
    local State = modules.State
    local Maintenance = modules.Maintenance
    if not Allocations or not Allocations.Setup then return end

    Allocations.Setup({
        isPlayerAllowed = modules.Access and modules.Access.IsAllowed,
        handleAllocationChange = Spikes and Spikes.HandleAllocationChange or nil,
        notifyWatchers = State and State.NotifyWatchers or nil,
    })

    if Maintenance and Maintenance.CancelAttempts then
        Hooks.CancelMaintenanceAttempts = Maintenance.CancelAttempts
    end
end

local function setupRoutingNet(modules)
    local RoutingNet = modules.RoutingNet
    local State = modules.State
    local Allocations = modules.Allocations
    local Access = modules.Access
    if not RoutingNet or not RoutingNet.Setup then return end

    RoutingNet.Setup({
        sendFullState = State and State.SendFullState or nil,
        applyAllocations = Allocations and Allocations.Apply or nil,
        isPlayerAllowed = Access and Access.IsAllowed,
    })
end

local function setupSpikes(modules)
    local Spikes = modules.Spikes
    local State = modules.State
    if not Spikes or not Spikes.Setup then return end

    Spikes.Setup({
        sendFullState = State and State.SendFullState or nil,
    })
end

local function setupDeflectors(modules)
    local Deflectors = modules.Deflectors
    if not Deflectors or not Deflectors.Setup then return end

    Deflectors.Setup()
end

local function setupCommands(modules)
    local Commands = modules.Commands
    local Spikes = modules.Spikes
    local Access = modules.Access
    local Damage = modules.Damage
    local Panels = modules.Panels
    if not Commands or not Commands.Setup then return end

    Commands.Setup({
        sendFullState = modules.State and modules.State.SendFullState or nil,
        isPlayerAllowed = Access and Access.IsAllowed,
        isPlayerPrivileged = Access and Access.IsPrivileged,
        beginSpike = Spikes and Spikes.Begin,
        scheduleNextSpike = Spikes and Spikes.ScheduleNext,
        pickSubsystemForPanel = Spikes and Spikes.PickSubsystemForPanel,
        startSubsystemDamage = Damage and Damage.StartSubsystemDamage,
        collectPanelInfos = Panels and Panels.CollectPanelInfos,
        pickRandomPanelInfo = Panels and Panels.PickRandomPanelInfo,
        rememberPanelForLocation = Panels and Panels.RememberPanelForLocation,
    })
end

local function setupMaintenanceInteractions(modules, utilLib)
    local Maintenance = modules.Maintenance
    local Telemetry = modules.Telemetry
    if not Maintenance or not Maintenance.SetupInteractions then return end

    local timerNameBuilder = utilLib.BuildTimerName
    if not timerNameBuilder then
        local source = utilLib.NormalizeLocKey or string.lower
        timerNameBuilder = function(prefix, locKey)
            local label = source and source(locKey or "global") or (locKey or "global")
            label = string.gsub(label or "global", "[^%w_]", "_")
            return string.format("%s_%s", prefix or "EPS_Timer", label)
        end
    end

    Maintenance.SetupInteractions({
        getPanelInfo = modules.Panels and modules.Panels.GetPanelInfo,
        sendTricorderReport = Telemetry and Telemetry.SendTricorderReport,
        buildPanelPowerReport = Telemetry and Telemetry.BuildPanelPowerReport,
        buildMaintenanceReport = Telemetry and Telemetry.BuildMaintenanceReport,
        buildTimerName = timerNameBuilder,
    })
end

local function setupPlayerInteractions(modules)
    local Interactions = modules.Interactions
    local Maintenance = modules.Maintenance
    local Telemetry = modules.Telemetry
    if not Interactions or not Interactions.Setup then return end

    Interactions.Setup({
        handleSonicOverride = Maintenance and Maintenance.HandleSonicDriverOverride,
        tryStartMaintenance = Maintenance and Maintenance.TryStartMaintenanceFromScan,
        tryStartOverride = Maintenance and Maintenance.TryStartOverrideFromScan,
        processReenergize = Maintenance and Maintenance.ProcessReenergizeContact,
        getPanelInfo = modules.Panels and modules.Panels.GetPanelInfo,
        sendTricorderReport = Telemetry and Telemetry.SendTricorderReport,
        buildPanelPowerReport = Telemetry and Telemetry.BuildPanelPowerReport,
    })
end

local function setupBootstrap(modules)
    local Bootstrap = modules.Bootstrap
    local Spikes = modules.Spikes
    local State = modules.State
    local Maintenance = modules.Maintenance
    if not Bootstrap or not Bootstrap.Setup then return end

    Bootstrap.Setup({
        scheduleNextSpike = Spikes and Spikes.ScheduleNext,
        sendFullState = State and State.SendFullState,
        clearPlayer = State and State.ClearPlayer,
        cancelMaintenanceAttempts = Maintenance and Maintenance.CancelAttempts,
        cancelSpikeSchedule = Spikes and Spikes.CancelSchedule,
    })
end

function Hooks.RegisterAll(modules)
    modules = modules or {}
    local utilLib = EPS.Util or {}

    setupAllocations(modules, utilLib)
    setupRoutingNet(modules)
    setupSpikes(modules)
    setupDeflectors(modules)
    setupCommands(modules)
    setupMaintenanceInteractions(modules, utilLib)
    setupPlayerInteractions(modules)
    setupBootstrap(modules)
end

return Hooks
