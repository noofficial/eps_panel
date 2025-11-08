AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

EPS = EPS or {}

-- Same wall prop we used on the old console. Swap it if you have something prettier.
local DEFAULT_MODEL = "models/props/engineering/engineering_wallprop_01.mdl"
local USE_COOLDOWN = 1.0 -- seconds between legit uses; keeps the spam-clickers honest
local SCANNER_UPDATE_INTERVAL = 5
local SCANNER_MAINTENANCE_HINT_DURATION = 120

local function normalizeLocKey(locKey)
    if not isstring(locKey) then return "global" end
    local trimmed = string.Trim(locKey)
    if trimmed == "" then return "global" end
    return string.lower(trimmed)
end

local function resolvePanelInfo(panel)
    if not EPS then return nil end
    if EPS._UpdatePanelSection then
        EPS._UpdatePanelSection(panel)
    end
    return EPS._panelRefs and EPS._panelRefs[panel] or nil
end

local function getMaintenanceRecord(locKey, panel)
    if not EPS then return nil end
    local locks = EPS._maintenanceLocks
    if not locks then return nil end
    local normalized = normalizeLocKey(locKey)
    local bucket = locks[normalized]
    if not bucket then return nil end

    local function prune(target, state)
        if not state then return nil end
        if state.expires and state.expires > 0 and state.expires < CurTime() then
            bucket[target] = nil
            return nil
        end
        if state.panel and not IsValid(state.panel) then
            bucket[target] = nil
            return nil
        end
        return state
    end

    if IsValid(panel) then
        local specific = prune(panel, bucket[panel])
        if specific then
            return specific
        end
    end

    local global = prune("_global", bucket["_global"])
    if global then
        return global
    end

    for target, state in pairs(bucket) do
        if target ~= "_global" then
            local kept = prune(target, state)
            if kept then
                return kept
            end
        end
    end

    return nil
end

function ENT:Initialize()
    self:SetModel(self.ModelOverride or DEFAULT_MODEL)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:Wake() end

    self:SetUseType(SIMPLE_USE)
    self._nextUse = 0 -- remember the last E press so we can throttle a bit
    self._epsDamage = nil
    self._nextScannerUpdate = 0
    self._scannerMaintenanceState = nil
    self:UpdateScannerData()
    self:NextThink(CurTime())
    -- Tie this panel into the shared EPS pool as soon as it spins up.
    if EPS and EPS.RegisterPanel then
        EPS.RegisterPanel(self)
    end
end

function ENT:Use(activator, caller)
    if (self._nextUse or 0) > CurTime() then return end
    self._nextUse = CurTime() + USE_COOLDOWN
    if not IsValid(activator) or not activator:IsPlayer() then return end

    local info = resolvePanelInfo(self)
    local locKey = info and (info.locationKeyLower or info.locationKey) or "global"
    if EPS and EPS.IsLocationMaintenanceLocked and EPS.IsLocationMaintenanceLocked(locKey, self) then
        if activator.ChatPrint then
            activator:ChatPrint("[EPS] Maintenance lock engaged; review allocations before proceeding.")
        end
        activator:EmitSound("buttons/button11.wav", 55, 90, 0.35)
    end

    if EPS and EPS.RecordPanelUse then
        EPS.RecordPanelUse(self, activator)
    end

    -- Ask the routing addon for a fresh state push. If it isn't loaded yet, no big deal.
    if EPS and EPS.BroadcastState then
        EPS.BroadcastState(activator)
    end

    -- Fire the same console command players type manually. Nice and predictable.
    if activator.SendLua then
        activator:SendLua("RunConsoleCommand('eps_open')")
    else
        activator:ConCommand("eps_open\n")
    end

    activator:EmitSound("buttons/button14.wav", 60, 100) -- little bit of feedback so folks know it worked
end

function ENT:OnRemove()
    -- Drop our handle so stale panels don't hang onto the power tally.
    if EPS and EPS.UnregisterPanel then
        EPS.UnregisterPanel(self)
    end
end

-- Let duplicator/advdupe2 snapshot this without extra wiring.
duplicator.RegisterEntityClass("ent_eps_panel", function(ply, data)
    local ent = ents.Create("ent_eps_panel")
    if not IsValid(ent) then return end
    ent:SetPos(data.Pos)
    ent:SetAngles(data.Angle)
    ent:Spawn()
    ent:Activate()
    return ent
end, {"Pos","Angle"})

local function toVector(value)
    if not value then return nil end
    if isvector(value) then
        return Vector(value.x, value.y, value.z)
    end
    if istable(value) then
        local x = tonumber(value.x or value[1] or 0) or 0
        local y = tonumber(value.y or value[2] or 0) or 0
        local z = tonumber(value.z or value[3] or 0) or 0
        return Vector(x, y, z)
    end
    if isstring(value) then
        local x, y, z = string.match(value, "([%-%d%.]+)[,%s]+([%-%d%.]+)[,%s]+([%-%d%.]+)")
        if x and y and z then
            return Vector(tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
        end
    end
    return nil
end

if not EPS.SetPanelSparkOffset then
    function EPS.SetPanelSparkOffset(value)
        EPS._panelSparkOverride = toVector(value)
        return EPS._panelSparkOverride
    end
end

if not EPS.GetPanelSparkOffset then
    function EPS.GetPanelSparkOffset()
        return EPS._panelSparkOverride
    end
end

if not EPS.SetPanelFireOffset then
    function EPS.SetPanelFireOffset(value)
        EPS._panelFireOverride = toVector(value)
        return EPS._panelFireOverride
    end
end

if not EPS.GetPanelFireOffset then
    function EPS.GetPanelFireOffset()
        return EPS._panelFireOverride
    end
end

local function resolveSparkOffset()
    if not EPS then return nil end

    local override = EPS.GetPanelSparkOffset and EPS.GetPanelSparkOffset()
    if override then
        return override
    end

    local config = toVector(EPS.Config and EPS.Config.PanelSparkOffset)
    if config then
        return config
    end

    local constant = toVector(EPS.Constants and EPS.Constants.PANEL_SPARK_OFFSET)
    if constant then
        return constant
    end

    return nil
end

function ENT:GetSparkOffset()
    local configured = resolveSparkOffset()
    if configured then
        return configured
    end
    return self.SparkOffset or Vector(6, 0, 32)
end

function ENT:GetFireOffset()
    if self.FireOffset then return self.FireOffset end
    local override = toVector(EPS.GetPanelFireOffset and EPS.GetPanelFireOffset())
    if override then
        return override
    end
    local configured = toVector(EPS.Config and EPS.Config.PanelFireOffset)
    if configured then
        return configured
    end
    local constant = toVector(EPS.Constants and EPS.Constants.PANEL_FIRE_OFFSET)
    if constant then
        return constant
    end
    return self:GetSparkOffset() + Vector(0, 0, 24)
end

function ENT:SetSparkOffset(offset)
    local vec = toVector(offset)
    if vec then
        self.SparkOffset = vec
    end
end

function ENT:SetFireOffset(offset)
    local vec = toVector(offset)
    if vec then
        self.FireOffset = vec
    end
end

function ENT:SetSubsystemMask(list)
    if not istable(list) then
        self._epsSubsystemMask = nil
        return
    end

    self._epsSubsystemMask = {}
    for _, id in ipairs(list) do
        if isstring(id) then
            self._epsSubsystemMask[id] = true
        end
    end
end

function ENT:ServesSubsystem(id)
    if not self._epsSubsystemMask then return true end
    return self._epsSubsystemMask[id] == true
end

function ENT:TriggerOverpowerSparks()
    if self._nextSpark and self._nextSpark > CurTime() then return end
    self._nextSpark = CurTime() + 0.4

    local effect = EffectData()
    effect:SetOrigin(self:LocalToWorld(self:GetSparkOffset()))
    effect:SetNormal(self:GetForward())
    effect:SetMagnitude(2.5)
    effect:SetScale(1.1)
    effect:SetRadius(6)
    util.Effect("ElectricSpark", effect, true, true)

    self:EmitSound("ambient/energy/zap" .. math.random(1, 3) .. ".wav", 60, 100, 0.55)
end

function ENT:GetActiveDamageState()
    if not self._epsDamage then return end
    for _, state in pairs(self._epsDamage) do
        if state and not state.repaired then
            return state
        end
    end
end

function ENT:HandleSonicRepair(ply, swep, hitPos)
    local state = self:GetActiveDamageState()
    if not state or state.repaired then return false end

    local repairTime = state.repairTime or 0
    if repairTime <= 0 then return false end

    state.progress = math.min((state.progress or 0) + FrameTime(), repairTime)
    state.lastRepair = CurTime()

    if state.progress >= repairTime and EPS and EPS._CompleteDamageRepair then
        EPS._CompleteDamageRepair(state, ply)
    end

    return true
end

local function jitterMetric(ent, tag, base, variance)
    if variance <= 0 then return base end
    local stamp = math.floor(CurTime() / 5)
    local key = string.format("eps_panel_scan:%d:%s:%d", ent:EntIndex(), tag, stamp)
    return util.SharedRandom(key, base - variance, base + variance)
end

function ENT:BuildScannerLines()
    if not EPS then
        return {
            "[Tricorder] EPS Panel Scan",
            "  Status: EPS core telemetry unavailable.",
            "Summary: Unable to query EPS controller; check power scripts.",
        }
    end

    local info = resolvePanelInfo(self)
    local locKey = info and (info.locationKeyLower or info.locationKey) or "global"
    local normalized = normalizeLocKey(locKey)

    local deck = info and info.deck
    local section = info and info.sectionName
    local locationLabel
    if deck or section then
        locationLabel = string.format("Deck %s / %s", deck and tostring(deck) or "?", section and section ~= "" and section or "Unassigned Section")
    else
        locationLabel = string.upper(normalized)
    end

    local budget = EPS.GetBudget and (EPS.GetBudget(normalized) or 0) or 0
    local totalAlloc = EPS.GetTotalAllocation and (EPS.GetTotalAllocation(normalized) or 0) or 0
    local reserve = math.max(budget - totalAlloc, 0)

    local layout = info and info.layout
    if (not layout or #layout == 0) and EPS.IterSubsystems then
        layout = {}
        for _, sub in EPS.IterSubsystems() do
            layout[#layout + 1] = sub.id
        end
    end

    local lines = {
        "[Tricorder] EPS Panel Scan",
        "",
        string.format("  Node: %s", locationLabel),
        "",
        string.format("  Grid Load: %d / %d (%d reserve)", totalAlloc, budget, reserve),
    }

    local listed = 0
    if istable(layout) then
        for _, id in ipairs(layout) do
            if listed >= 6 then break end
            local sub = EPS.GetSubsystem and EPS.GetSubsystem(id)
            if sub then
                local demand = EPS.GetDemand and (EPS.GetDemand(normalized, id) or 0) or 0
                local alloc = EPS.GetAllocation and (EPS.GetAllocation(normalized, id) or 0) or 0
                lines[#lines + 1] = string.format("  %-22s %4d alloc / %4d demand", (sub.label or string.upper(id)), alloc, demand)
                listed = listed + 1
            end
        end
    end

    lines[#lines + 1] = ""
    local flux = jitterMetric(self, "flux", math.max(totalAlloc, 1) * 0.08, 3.0)
    local harmonic = jitterMetric(self, "harmonic", 40 + (totalAlloc % 15) * 0.6, 1.2)
    local phaseNoise = math.max(0.01, jitterMetric(self, "phase", 0.18, 0.04))
    local wallTemp = jitterMetric(self, "wall", 285 + totalAlloc * 0.12, 4.5)

    lines[#lines + 1] = string.format("  Plasma Flux: %.2f kl/s", flux)
    lines[#lines + 1] = string.format("  Harmonic Drift: %.2f kHz", harmonic)
    lines[#lines + 1] = string.format("  Phase Noise: %.2f%%", phaseNoise * 100)
    lines[#lines + 1] = string.format("  Conduit Wall Temp: %.1f K", wallTemp)

    local needsMaintenance = false
    if EPS.IsLocationMaintenanceLocked and EPS.IsLocationMaintenanceLocked(normalized, self) then
        needsMaintenance = true
    else
        local record = getMaintenanceRecord(normalized, self)
        if record and record.active then
            needsMaintenance = true
        end
    end

    if not needsMaintenance then
        local cached = self._scannerMaintenanceState
        if cached and cached.expires > CurTime() then
            needsMaintenance = cached.flag
        else
            needsMaintenance = math.random() < 0.2
            self._scannerMaintenanceState = {
                flag = needsMaintenance,
                expires = CurTime() + SCANNER_MAINTENANCE_HINT_DURATION,
            }
        end
    end

    local summary
    if needsMaintenance then
        summary = "Summary: Maintenance flush recommended; route ODN scanner to conduit.";
    else
        summary = "Summary: EPS conduit within nominal tolerances."
    end
    lines[#lines + 1] = summary

    return lines, needsMaintenance
end

function ENT:UpdateScannerData()
    local lines, needsMaintenance = self:BuildScannerLines()
    self._scannerReadout = {
        header = lines[1] or "[Tricorder] EPS Panel Scan",
        lines = lines,
        summary = lines[#lines] or "",
        needsMaintenance = needsMaintenance and true or false,
    }
    self.ScannerData = table.concat(lines, "\n")
end

function ENT:GetScannerData(ply, swep)
    if not self.ScannerData then
        self:UpdateScannerData()
    end
    return self.ScannerData
end

function ENT:GetScannerReadout()
    if not self._scannerReadout then
        self:UpdateScannerData()
    end
    return self._scannerReadout or { lines = { "[Tricorder] EPS Panel Scan", "  Status: Data unavailable.", "Summary: Unable to read EPS panel." }, summary = "Summary: Unable to read EPS panel.", needsMaintenance = false }
end

function ENT:Think()
    if CurTime() >= (self._nextScannerUpdate or 0) then
        self:UpdateScannerData()
        self._nextScannerUpdate = CurTime() + SCANNER_UPDATE_INTERVAL
    end
    self:NextThink(CurTime() + 1)
    return true
end
