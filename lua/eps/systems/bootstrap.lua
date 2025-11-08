if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Bootstrap = {}

local installed = false

function Bootstrap.Setup(options)
    if installed then return end
    installed = true

    options = options or {}
    local scheduleNextSpike = options.scheduleNextSpike
    local sendFullState = options.sendFullState
    local clearPlayer = options.clearPlayer
    local cancelMaintenance = options.cancelMaintenanceAttempts
    local cancelSpikeSchedule = options.cancelSpikeSchedule

    if scheduleNextSpike then
        hook.Add("Initialize", "EPS_StartSpikesOnInit", function()
            scheduleNextSpike()
        end)
    end

    if sendFullState then
        hook.Add("PlayerInitialSpawn", "EPS_SendInitialState", function(ply)
            timer.Simple(3, function()
                if IsValid(ply) then
                    sendFullState(ply, false)
                end
            end)
        end)
    end

    hook.Add("PlayerDisconnected", "EPS_ClearLayoutCache", function(ply)
        if clearPlayer then
            clearPlayer(ply)
        end
        if cancelMaintenance then
            cancelMaintenance(ply)
        end
    end)

    if cancelSpikeSchedule then
        hook.Add("ShutDown", "EPS_StopSpikeTimer", function()
            cancelSpikeSchedule()
        end)
    end
end

return Bootstrap
