if CLIENT then return end

util.AddNetworkString(EPS.NET.Open)
util.AddNetworkString(EPS.NET.Update)
util.AddNetworkString(EPS.NET.FullState)

EPS._playerLayouts = EPS._playerLayouts or setmetatable({}, { __mode = "k" })
-- Keep tabs on the deployed panels so they all read the same power ledger.
EPS._panelRefs = EPS._panelRefs or setmetatable({}, { __mode = "k" })
EPS._damageStates = EPS._damageStates or {}
EPS._recentPanelByLocation = EPS._recentPanelByLocation or setmetatable({}, { __mode = "v" })
EPS._lastPanelPerPlayer = EPS._lastPanelPerPlayer or setmetatable({}, { __mode = "kv" })
EPS._maintenanceLocks = EPS._maintenanceLocks or {}
EPS._maintenanceScanAttempts = EPS._maintenanceScanAttempts or setmetatable({}, { __mode = "k" })
EPS._panelTelemetry = EPS._panelTelemetry or setmetatable({}, { __mode = "k" })

local buildLayoutFor
local haveActivePanels
local registerPanelLayout
local normalizeRecipients

local OVERPOWER_THRESHOLD = 0.25       -- fraction of extra headroom before the panel starts taking damage
local OVERPOWER_DAMAGE_DELAY_MIN = 75  -- fastest seconds above threshold before damage kicks in (worst overload)
local OVERPOWER_DAMAGE_DELAY_MAX = 240 -- slowest seconds above threshold before damage kicks in (light overload)
local DAMAGE_SPARK_INTERVAL_MIN = 0.8  -- seconds between sparks when the subsystem is pegged at max
local DAMAGE_SPARK_INTERVAL_MAX = 4.0  -- seconds between sparks when the overload is barely above threshold
local DAMAGE_REPAIR_TIME = 5          -- cumulative seconds of sonic-driver contact to clear damage
local DAMAGE_FIRE_DELAY_MIN = 25       -- shortest delay before the console ignites (after damage onset)
local DAMAGE_FIRE_DELAY_MAX = 120      -- longest delay before ignition when overload is mild
local DAMAGE_RESPAWN_ACCEL = 0.6       -- multiplier applied to respawn delay after each repair while overload persists
local DAMAGE_RESPAWN_MIN_MULT = 0.1    -- never let the respawn delay drop below 10% of the base severity delay
local DAMAGE_RESPAWN_MIN_DELAY = 5     -- absolute seconds floor so sparks never respawn instantly

local MAINTENANCE_LOCK_DURATION = 600  -- seconds before an unattended maintenance lock naturally expires
local ODN_SCAN_RANGE = 160             -- hammerhead scanner interaction range in Hammer units
local MAINTENANCE_SCAN_TIME = 1.25     -- seconds the ODN scanner must dwell before the flush triggers
local MAINTENANCE_SCAN_INTERVAL = 0.1  -- polling interval while confirming the ODN scan
local MAINTENANCE_AIM_TOLERANCE = 8    -- distance tolerance (Hammer units) when re-confirming the aimed panel
local REENERGIZE_REQUIRED_TIME = 1.5   -- seconds of hyperspanner contact to bring the conduit back online
local REENERGIZE_STEP = 0.25           -- progress gain per hyperspanner pulse
local REENERGIZE_DECAY = 1.0           -- seconds before unattended progress falls back to zero
local DAMAGE_RESPAWN_ACCEL = 0.6       -- multiplier applied to respawn delay after each repair while overload persists
local DAMAGE_RESPAWN_MIN_MULT = 0.1    -- never let the respawn delay drop below 10% of the base severity delay
local DAMAGE_RESPAWN_MIN_DELAY = 5     -- absolute seconds floor so sparks never respawn instantly

local function normalizeLocKey(locKey)
	if not locKey or locKey == "" then return "global" end
	return string.lower(locKey)
end

local function buildTimerName(prefix, locKey)
	local safe = normalizeLocKey(locKey or "global")
	safe = string.gsub(safe, "[^%w_]", "_")
	return string.format("%s_%s", prefix or "EPS_Timer", safe)
end

local function getMaintenanceState(locKey)
	EPS._maintenanceLocks = EPS._maintenanceLocks or {}
	local key = normalizeLocKey(locKey)
	local state = EPS._maintenanceLocks[key]
	if state and state.expires and state.expires > 0 and state.expires < CurTime() then
		EPS._maintenanceLocks[key] = nil
		return nil
	end
	return state
end

local function setMaintenanceState(locKey, state)
	EPS._maintenanceLocks = EPS._maintenanceLocks or {}
	local key = normalizeLocKey(locKey)
	if state then
		EPS._maintenanceLocks[key] = state
	else
		EPS._maintenanceLocks[key] = nil
	end
end

function EPS.IsLocationMaintenanceLocked(locKey)
	local state = getMaintenanceState(locKey)
	return state ~= nil and state.active == true
end

local function rememberPanelForLocation(panel, locKey)
	if not IsValid(panel) then return end
	EPS._recentPanelByLocation = EPS._recentPanelByLocation or setmetatable({}, { __mode = "v" })
	local key = normalizeLocKey(locKey)
	EPS._recentPanelByLocation[key] = panel
end

local function getPanelInfo(panel)
	if not IsValid(panel) then return nil end
	EPS._UpdatePanelSection(panel)
	local info = EPS._panelRefs and EPS._panelRefs[panel]
	if not info then return nil end
	return info
end

local sendFullState
local sendFullStateImmediate

local function describeLocation(info, locKey)
	local deck = info and info.deck
	local section = info and info.sectionName
	local deckText = deck and tostring(deck) or nil
	local sectionText = section and section ~= "" and section or nil
	if deckText or sectionText then
		deckText = deckText or "?"
		sectionText = sectionText or "Unassigned Section"
		return string.format("Deck %s / %s", deckText, sectionText)
	end
	locKey = normalizeLocKey(locKey)
	if locKey == "global" then
		return "Global EPS Lattice"
	end
	return string.upper(locKey)
end

local function snapshotSubsystemTables(locKey)
	local state = EPS.GetLocationState(locKey)
	local alloc = {}
	local demand = {}
	for _, sub in EPS.IterSubsystems() do
		local id = sub.id
		alloc[id] = state.allocations and state.allocations[id] or 0
		demand[id] = state.demand and state.demand[id] or 0
	end
	return alloc, demand
end

local function copyMap(input)
	local output = {}
	if istable(input) then
		for key, value in pairs(input) do
			output[key] = value
		end
	end
	return output
end

local function storePanelTelemetry(panel, lines)
	if not IsValid(panel) or not istable(lines) then return end
	EPS._panelTelemetry = EPS._panelTelemetry or setmetatable({}, { __mode = "k" })
	EPS._panelTelemetry[panel] = {
		lines = table.Copy(lines),
		timestamp = CurTime(),
	}
	panel:SetNWFloat("eps_scan_stamp", CurTime())
	local ok, payload = pcall(util.TableToJSON, { lines = lines or {}, stamp = CurTime() })
	if ok and payload then
		panel:SetNWString("eps_scan_packet", payload)
	else
		panel:SetNWString("eps_scan_packet", "")
	end
end

local function sendTricorderReport(ply, panel, lines)
	storePanelTelemetry(panel, lines)
	if not IsValid(ply) then return end
	local summary = lines and lines[#lines]
	if summary and summary ~= "" then
		ply:PrintMessage(HUD_PRINTCENTER, summary)
	end
end

function EPS.GetPanelTelemetry(panel)
	local entry = EPS._panelTelemetry and EPS._panelTelemetry[panel]
	if not entry then return nil, 0 end
	return table.Copy(entry.lines or {}), entry.timestamp or 0
end

local function generateTelemetry(locKey, savedDemand)
	savedDemand = savedDemand or {}
	local sumDemand = 0
	local sumAlloc = 0
	local perSubsystem = {}
	for _, sub in EPS.IterSubsystems() do
		local id = sub.id
		local demand = savedDemand[id]
		if demand == nil then
			demand = EPS.GetDemand(locKey, id) or 0
		end
		demand = tonumber(demand) or 0
		local alloc = EPS.GetAllocation(locKey, id) or demand
		alloc = tonumber(alloc) or 0
		sumDemand = sumDemand + demand
		sumAlloc = sumAlloc + alloc
		perSubsystem[#perSubsystem + 1] = { sub = sub, demand = demand, alloc = alloc }
	end

	local budget = EPS.GetBudget(locKey) or 0
	local reserve = math.max(budget - sumAlloc, 0)

	local function jitter(base, scale)
		return base + math.Rand(-scale, scale)
	end

	local purgeFlux = jitter(sumDemand * 0.085, 0.25)
	local fieldError = math.max(0, jitter(2.0 - sumDemand * 0.003, 0.08))
	local wallTemp = jitter(285 + sumDemand * 0.12, 3.5)
	local phaseOffset = jitter(0.015 + sumDemand * 0.00002, 0.0007)
	local gradient = jitter(0.7 + sumDemand * 0.0015, 0.05)
	local coherence = math.max(80, jitter(99.3 - sumDemand * 0.004, 0.6))
	local harmonic = jitter(42.0 + (sumAlloc % 17) * 0.37 + (sumDemand % 13) * 0.22, 0.8)
	local phaseNoise = math.max(0.02, jitter(0.18 - reserve * 0.0004, 0.01))

	return {
		sumDemand = sumDemand,
		sumAlloc = sumAlloc,
		budget = budget,
		reserve = reserve,
		perSubsystem = perSubsystem,
		purgeFlux = purgeFlux,
		fieldError = fieldError,
		wallTemp = wallTemp,
		phaseOffset = phaseOffset,
		gradient = gradient,
		coherence = coherence,
		harmonic = harmonic,
		phaseNoise = phaseNoise,
	}
end

local function buildMaintenanceReport(info, locKey, savedDemand, telemetry)
	local label = describeLocation(info, locKey)
	telemetry = telemetry or generateTelemetry(locKey, savedDemand)
	local lines = {
		"[Tricorder] EPS Diagnostic Scan",
		string.format("  Node: %s", label),
		string.format("  Plasma Flow (pre-flush): %.2f kl/s", telemetry.purgeFlux),
		string.format("  Field Regulator Error: %.2f%%", telemetry.fieldError),
		string.format("  Conduit Wall Temperature: %.1f K", telemetry.wallTemp),
		string.format("  Subspace Phase Offset: %.4f millicochranes", telemetry.phaseOffset),
		string.format("  Induction Gradient: %.3f tesla", telemetry.gradient),
		string.format("  Coherence Envelope: %.2f%%", telemetry.coherence),
		"  Conduit Purge Status: COMPLETE",
		"Summary: EPS maintenance flush successful; conduit ready for re-energizing.",
	}
	return lines, telemetry
end

local function buildPanelPowerReport(info, locKey, summary, header, telemetry)
	local label = describeLocation(info, locKey)
	telemetry = telemetry or generateTelemetry(locKey)
	local lines = {
		header or "[Tricorder] EPS Power Diagnostics",
		string.format("  Node: %s", label),
	}

	for _, entry in ipairs(telemetry.perSubsystem or {}) do
		local sub = entry.sub
		local labelText = (sub and sub.label) or string.upper((sub and sub.id) or "Unknown")
		lines[#lines + 1] = string.format("  %-22s demand %4d / alloc %4d", labelText, entry.demand or 0, entry.alloc or 0)
	end

	lines[#lines + 1] = string.format("  Net Power Demand: %d", telemetry.sumDemand)
	lines[#lines + 1] = string.format("  Net Allocation Load: %d", telemetry.sumAlloc)
	local efficiency = 0
	if telemetry.sumDemand > 0 then
		efficiency = math.min(100, (telemetry.sumAlloc / telemetry.sumDemand) * 100)
	end
	lines[#lines + 1] = string.format("  Lattice Budget Capacity: %d", telemetry.budget)
	lines[#lines + 1] = string.format("  Reserve Power Margin: %d", telemetry.reserve)
	lines[#lines + 1] = string.format("  Harmonic Field Frequency: %.2f kHz", telemetry.harmonic)
	lines[#lines + 1] = string.format("  Subspace Phase Noise: %.3f%%", telemetry.phaseNoise * 100)
	lines[#lines + 1] = string.format("  Transfer Efficiency: %.1f%%", efficiency)
	lines[#lines + 1] = summary or "Summary: EPS diagnostics nominal."
	return lines
end

local function buildReenergizeReport(info, locKey)
	return buildPanelPowerReport(info, locKey, "Summary: EPS conduit nominal; manual controls restored.", "[Tricorder] EPS Power Reinitialization")
end

local function clearDamageForLocation(locKey)
	local prefix = normalizeLocKey(locKey) .. "::"
	for key, state in pairs(EPS._damageStates or {}) do
		if state and string.StartWith(key, prefix) then
			EPS._CompleteDamageRepair(state, nil, { silent = true })
		end
	end
	for key, watch in pairs(EPS._overpowerWatch or {}) do
		if string.StartWith(key, prefix) then
			watch.since = 0
			watch.respawnMultiplier = 1
		end
	end
end

function EPS.EnterMaintenance(panel, ply)
	if not IsValid(panel) or panel:GetClass() ~= "ent_eps_panel" then
		return false, "Not an EPS panel"
	end

	local info = getPanelInfo(panel)
	if not info then
		return false, "Unable to resolve panel location"
	end

	local locKey = info.locationKey or info.locationKeyLower or "global"
	local normalized = normalizeLocKey(locKey)
	local existing = getMaintenanceState(normalized)
	if existing and existing.active then
		return false, "EPS conduit already secured for maintenance"
	end

	local savedAlloc, savedDemand = snapshotSubsystemTables(normalized)

	local record = {
		active = true,
		savedAllocations = copyMap(savedAlloc),
		savedDemand = copyMap(savedDemand),
		started = CurTime(),
		panel = panel,
		by = IsValid(ply) and ply or nil,
		expires = CurTime() + MAINTENANCE_LOCK_DURATION,
		locationKey = normalized,
		meta = {
			deck = info.deck,
			sectionName = info.sectionName,
		},
		reenergizeProgress = 0,
		reenergizeDuration = REENERGIZE_REQUIRED_TIME,
		lastReenergizeHit = 0,
	}

	setMaintenanceState(normalized, record)

	for _, sub in EPS.IterSubsystems() do
		local id = sub.id
		EPS.SetDemand(normalized, id, 0)
		EPS.SetAllocation(normalized, id, 0)
	end

	clearDamageForLocation(normalized)
	EPS._RunChangeHookIfNeeded(normalized)
	EPS._SyncPanels(normalized)
	sendFullState(nil, false)

	local report, telemetry = buildMaintenanceReport(info, normalized, savedDemand)
	record.telemetry = telemetry
	record.telemetryStamp = CurTime()
	return true, record, report
end

function EPS.ExitMaintenance(panel, ply)
	if not IsValid(panel) or panel:GetClass() ~= "ent_eps_panel" then
		return false, "Not an EPS panel"
	end

	local info = getPanelInfo(panel)
	if not info then
		return false, "Unable to resolve panel location"
	end

	local locKey = info.locationKey or info.locationKeyLower or "global"
	local normalized = normalizeLocKey(locKey)
	local record = getMaintenanceState(normalized)
	if not record or not record.active then
		return false, "EPS conduit is already online"
	end

	local savedAlloc = record.savedAllocations or {}
	local savedDemand = record.savedDemand or {}

	for _, sub in EPS.IterSubsystems() do
		local id = sub.id
		local demand = savedDemand[id]
		if demand == nil then
			demand = EPS.GetSubsystemDefault and EPS.GetSubsystemDefault(id) or EPS.GetDemand(normalized, id)
		end
		demand = demand or 0
		local alloc = savedAlloc[id]
		if alloc == nil then
			alloc = EPS.GetAllocation(normalized, id)
		end
		alloc = alloc or demand
		local clampedAlloc = EPS.ClampAllocationForSubsystem and EPS.ClampAllocationForSubsystem(id, alloc) or alloc
		EPS.SetDemand(normalized, id, demand)
		EPS.SetAllocation(normalized, id, clampedAlloc)
	end

	setMaintenanceState(normalized, nil)
	EPS._RunChangeHookIfNeeded(normalized)
	EPS._SyncPanels(normalized)
	sendFullState(nil, false)

	local report = buildReenergizeReport(info, normalized)
	return true, record, report
end

local function computeSeverityFromRatio(ratio)
	if ratio <= OVERPOWER_THRESHOLD then return 0 end
	local span = 1 - OVERPOWER_THRESHOLD
	if span <= 0 then return 1 end
	return math.Clamp((ratio - OVERPOWER_THRESHOLD) / span, 0, 1)
end

local function severityLerp(severity, minValue, maxValue)
	local clamped = math.Clamp(severity or 0, 0, 1)
	return Lerp(clamped, maxValue, minValue)
end

local function determineSectionForPos(pos)
	if not pos then return end
	if not Star_Trek or not Star_Trek.Sections or not Star_Trek.Sections.DetermineSection then return end

	local success, deck, sectionId = Star_Trek.Sections:DetermineSection(pos)
	if not success then return end

	local sectionName = Star_Trek.Sections:GetSectionName(deck, sectionId)
	if sectionName == false then
		sectionName = nil
	end

	return deck, sectionId, sectionName
end

function EPS._UpdatePanelSection(panel)
	if not IsValid(panel) then return end
	EPS._panelRefs = EPS._panelRefs or setmetatable({}, { __mode = "k" })

	local info = EPS._panelRefs[panel]
	if not info or type(info) ~= "table" then
		info = { entity = panel }
		EPS._panelRefs[panel] = info
	end

	local deck, sectionId, sectionName = determineSectionForPos(panel:GetPos())
	info.deck = deck
	info.sectionId = sectionId
	info.sectionName = sectionName
	info.entity = panel

	local layout = select(1, buildLayoutFor(deck, sectionName))
	info.layout = layout

	local rawKey = EPS.NormalizeLocationKey and EPS.NormalizeLocationKey(deck, sectionName) or nil
	local _, locKey = EPS.GetLocationState(rawKey)
	info.locationKey = locKey
	info.locationKeyLower = locKey and string.lower(locKey) or nil
	info.rawLocationKey = rawKey
	panel._epsLocationKey = locKey
	rememberPanelForLocation(panel, locKey)

	if locKey and EPS.SetLocationMeta then
		EPS.SetLocationMeta(locKey, {
			deck = deck,
			section = sectionName,
			sectionId = sectionId,
		})
	end

	registerPanelLayout(panel, layout)
end

local function syncPanelNetworkState(panel)
	if not IsValid(panel) then return end

	local info = EPS._panelRefs and EPS._panelRefs[panel]
	local locKey = info and info.locationKey or nil
	local maxBudget = EPS.GetBudget(locKey)
	local totalAllocation = EPS.GetTotalAllocation(locKey)
	panel:SetNWInt("eps_max_budget", maxBudget)
	panel:SetNWInt("eps_total_allocation", totalAllocation)
	panel:SetNWInt("eps_available_power", math.max(maxBudget - totalAllocation, 0))
	panel:SetNWString("eps_location", locKey or "global")
	panel:SetNWString("eps_location_section", info and (info.sectionName or "") or "")
	local deckLabel = info and info.deck and tostring(info.deck) or ""
	panel:SetNWString("eps_location_deck", deckLabel)
	panel:SetNWBool("eps_maintenance_lock", EPS.IsLocationMaintenanceLocked(locKey))
end

function EPS._SyncPanels(targetLocKey)
	if not EPS._panelRefs then return end

	local normalizedTarget = targetLocKey and string.lower(targetLocKey) or nil

	for panel in pairs(EPS._panelRefs) do
		if IsValid(panel) then
			EPS._UpdatePanelSection(panel)
			local info = EPS._panelRefs[panel]
			local panelKey = info and (info.locationKeyLower or (info.locationKey and string.lower(info.locationKey))) or nil
			if not normalizedTarget or panelKey == normalizedTarget then
				syncPanelNetworkState(panel)
			end
		else
			EPS._panelRefs[panel] = nil
		end
	end
end

function EPS.RegisterPanel(panel)
	if not IsValid(panel) then return end

	EPS._panelRefs = EPS._panelRefs or setmetatable({}, { __mode = "k" })
	local info = EPS._panelRefs[panel]
	if not info then
		info = { entity = panel }
		EPS._panelRefs[panel] = info
	else
		info.entity = panel
	end
	EPS._UpdatePanelSection(panel)
	syncPanelNetworkState(panel)

	panel:CallOnRemove("EPS_UnregisterPanel", function(ent)
		EPS.UnregisterPanel(ent)
	end)
end

function EPS.UnregisterPanel(panel)
	if not EPS._panelRefs then return end
	EPS._panelRefs[panel] = nil

	if not EPS._damageStates then return end
	for key, state in pairs(EPS._damageStates) do
		if state and state.panel == panel then
			EPS._CompleteDamageRepair(state, nil, { silent = true })
		end
	end
end

local function registerPanelEntity(ent)
	if not IsValid(ent) then return end
	if ent:GetClass() ~= "ent_eps_panel" then return end
	if EPS and EPS.RegisterPanel then
		EPS.RegisterPanel(ent)
	end
end

hook.Add("OnEntityCreated", "EPS_WatchForPanels", function(ent)
	if not IsValid(ent) then return end
	if ent:GetClass() ~= "ent_eps_panel" then return end
	timer.Simple(0, function()
		registerPanelEntity(ent)
	end)
end)

hook.Add("InitPostEntity", "EPS_RegisterExistingPanels", function()
	for _, ent in ipairs(ents.FindByClass("ent_eps_panel")) do
		registerPanelEntity(ent)
	end
end)

local function copyList(tbl)
	local result = {}
	if istable(tbl) then
		for _, value in ipairs(tbl) do
			result[#result + 1] = value
		end
	end
	return result
end

local function uniqueInsert(list, value)
	if not value then return end
	for _, existing in ipairs(list) do
		if existing == value then return end
	end
	list[#list + 1] = value
end

local function clampToUInt(value, bits)
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

function EPS.RecordPanelUse(panel, ply)
	if not IsValid(panel) then return end
	EPS._UpdatePanelSection(panel)
	local info = EPS._panelRefs and EPS._panelRefs[panel]
	if not info then return end
	info.lastUser = IsValid(ply) and ply or info.lastUser
	local locKey = info.locationKey
	info.locationKeyLower = locKey and string.lower(locKey) or nil
	rememberPanelForLocation(panel, locKey)
	syncPanelNetworkState(panel)

	if IsValid(ply) then
		EPS._lastPanelPerPlayer = EPS._lastPanelPerPlayer or setmetatable({}, { __mode = "kv" })
		EPS._lastPanelPerPlayer[ply] = panel
	end
end

local function matchesAccessList(ply, list)
	if not IsValid(ply) or not istable(list) then return false end
	local userGroup = string.lower(ply:GetUserGroup() or "")
	local teamName = ""
	if team and team.GetName then
		teamName = string.lower(team.GetName(ply:Team()) or "")
	end
	for _, entry in ipairs(list) do
		local target = string.lower(tostring(entry or ""))
		if target ~= "" then
			if userGroup == target then return true end
			if ply.IsUserGroup and ply:IsUserGroup(target) then return true end
			if teamName ~= "" and teamName == target then return true end
		end
	end
	return false
end

local function isPlayerAllowed(ply)
	if not IsValid(ply) then return true end
	if ply:IsAdmin() then return true end
	local groups = EPS.Config and EPS.Config.AllowedGroups
	if istable(groups) and #groups > 0 then
		return matchesAccessList(ply, groups)
	end
	return true
end

local function isPlayerPrivileged(ply)
	if not IsValid(ply) then return true end
	local spikeCfg = EPS.Config and EPS.Config.Spikes or {}
	local groups = spikeCfg.PrivilegedGroups
	if istable(groups) and #groups > 0 then
		return matchesAccessList(ply, groups)
	end
	return ply:IsAdmin()
end

local function subsystemExists(id)
	return id ~= nil and EPS.GetSubsystem and EPS.GetSubsystem(id) ~= nil
end

local function sanitizeLayout(layout, useDefaultFallback)
	local output = {}

	if istable(layout) then
		for _, id in ipairs(layout) do
			if subsystemExists(id) then
				uniqueInsert(output, id)
			end
		end
	end

	local dyn = EPS.Config.DynamicLayouts or {}
	local always = dyn.alwaysInclude
	if istable(always) then
		for _, id in ipairs(always) do
			if subsystemExists(id) then
				uniqueInsert(output, id)
			end
		end
	elseif subsystemExists("life_support") then
		uniqueInsert(output, "life_support")
	end

	if #output == 0 and useDefaultFallback then
		local default = dyn.default or { "replicators.general", "forcefields" }
		for _, id in ipairs(default) do
			if subsystemExists(id) then
				uniqueInsert(output, id)
			end
		end
		if istable(always) then
			for _, id in ipairs(always) do
				if subsystemExists(id) then
					uniqueInsert(output, id)
				end
			end
		end
	end

	if #output == 0 and subsystemExists("life_support") then
		uniqueInsert(output, "life_support")
	end

	return output
end


local function normalizeSectionKey(key)
    if not isstring(key) then return nil end
    return string.Trim(string.lower(key))
end

buildLayoutFor = function(deck, sectionName)
	local dyn = EPS.Config.DynamicLayouts or {}
	local layout
	local usedDefault = false

	local matchedLayout
	if sectionName and dyn.sectionNames then
		local normalized = normalizeSectionKey(sectionName)
		matchedLayout = dyn.sectionNames[sectionName]
		if not matchedLayout and normalized then
			matchedLayout = dyn.sectionNames[normalized]
		end
		if not matchedLayout and normalized then
			for key, value in pairs(dyn.sectionNames) do
				local keyNormalized = normalizeSectionKey(key)
				if keyNormalized == normalized or (keyNormalized and string.find(keyNormalized, normalized, 1, true)) or (normalized and keyNormalized and string.find(normalized, keyNormalized, 1, true)) then
					matchedLayout = value
					break
				end
			end
		end
	end

	local chosenLayout
	local chosenSource
	if matchedLayout then
		layout = copyList(matchedLayout)
		chosenLayout = layout
		chosenSource = "section"
	elseif deck and dyn.deckOverrides and dyn.deckOverrides[deck] then
		layout = copyList(dyn.deckOverrides[deck])
		chosenLayout = layout
		chosenSource = "deck"
	else
		layout = copyList(dyn.default)
		usedDefault = true
		chosenLayout = layout
		chosenSource = "default"
	end

	if not layout or #layout == 0 then
		layout = copyList(dyn.default)
		usedDefault = true
	end

	local sanitized = sanitizeLayout(layout, usedDefault)
	return sanitized, { source = chosenSource, deck = deck, section = sectionName }
end

local function getPlayerLayout(ply, forceRefresh)
	if not IsValid(ply) then
		local layout, meta = buildLayoutFor(nil, nil)
		local rawKey = EPS.NormalizeLocationKey and EPS.NormalizeLocationKey(meta and meta.deck, meta and meta.section)
		local _, locKey = EPS.GetLocationState(rawKey)
		if locKey and EPS.SetLocationMeta then
			EPS.SetLocationMeta(locKey, meta)
		end
		return layout, locKey, meta
	end

	local cached = EPS._playerLayouts[ply]
	if forceRefresh or not cached then
		local deck, sectionId, sectionName = determineSectionForPos(ply:GetPos())
		local layout, meta = buildLayoutFor(deck, sectionName)
		meta = meta or {}
		meta.sectionId = sectionId
		meta.deck = meta.deck or deck
		meta.section = meta.section or sectionName
		local rawKey = EPS.NormalizeLocationKey and EPS.NormalizeLocationKey(meta.deck, meta.section)
		local _, locKey = EPS.GetLocationState(rawKey)
		if locKey and EPS.SetLocationMeta then
			EPS.SetLocationMeta(locKey, meta)
		end
		cached = {
			layout = layout,
			locKey = locKey,
			meta = meta,
		}
		EPS._playerLayouts[ply] = cached
	end

	return cached.layout, cached.locKey, cached.meta
end

normalizeRecipients = function(target)
	if target == nil then
		return player.GetHumans()
	end
	if istable(target) then
		local recipients = {}
		for _, ply in pairs(target) do
			if IsValid(ply) then
				recipients[#recipients + 1] = ply
			end
		end
		return recipients
	end
	if IsValid(target) then
		return { target }
	end
	return {}
end

local function applyAllocations(ply, incoming, expectedLocKey)
	local layout, locKey = getPlayerLayout(ply, false)
	if not layout or #layout == 0 then
		return false, "No routed subsystems"
	end

	local _, normalizedKey = EPS.GetLocationState(locKey)
	locKey = normalizedKey

	if expectedLocKey and locKey and expectedLocKey ~= locKey then
		return false, "Location context changed"
	end
	if expectedLocKey and not locKey then
		locKey = expectedLocKey
	end

	if EPS.IsLocationMaintenanceLocked(locKey) then
		return false, "EPS routing is locked for maintenance"
	end

	local allowed = {}
	for _, id in ipairs(layout) do
		allowed[id] = true
	end

	local budget = EPS.GetBudget(locKey)
	local total = EPS.GetTotalAllocation(locKey)
	local changes = {}

	for id, raw in pairs(incoming or {}) do
		if allowed[id] then
			local clamped = EPS.ClampAllocationForSubsystem(id, raw)
			if clamped == nil then
				return false, "Invalid subsystem"
			end
			local current = EPS.GetAllocation(locKey, id)
			clamped = clamped or 0
			total = total - current + clamped
			changes[id] = clamped
		end
	end

	if total > budget then
		return false, "Budget exceeded"
	end

	for id, value in pairs(changes) do
		EPS.SetAllocation(locKey, id, value)
		local demand = EPS.GetDemand(locKey, id)
		if demand == nil then
			local def = EPS.GetSubsystemDefault and EPS.GetSubsystemDefault(id)
			EPS.SetDemand(locKey, id, def or value)
		end
	end

	if currentSpike and currentSpike.target and currentSpike.locKey == locKey then
		local targetId = currentSpike.target
		local newValue = changes[targetId]
		if newValue ~= nil then
			if not currentSpike.responded and newValue ~= currentSpike.startAlloc then
				currentSpike.responded = true
			end
			currentSpike.lastAlloc = newValue
		end
	end

	EPS._RunChangeHookIfNeeded(locKey)

	if IsValid(ply) then
		local lastPanel = EPS._lastPanelPerPlayer and EPS._lastPanelPerPlayer[ply]
		if IsValid(lastPanel) then
			local info = EPS._panelRefs and EPS._panelRefs[lastPanel]
			if not info then
				EPS._UpdatePanelSection(lastPanel)
				info = EPS._panelRefs and EPS._panelRefs[lastPanel]
			end
			local panelLoc = info and (info.locationKeyLower or info.locationKey)
			panelLoc = normalizeLocKey(panelLoc)
			if panelLoc == normalizeLocKey(locKey) then
				rememberPanelForLocation(lastPanel, panelLoc)
			end
		end
	end

	return true
end

sendFullStateImmediate = function(ply, shouldOpen)
	if not EPS.State then return end
	if not IsValid(ply) or not ply:IsPlayer() then return end

	local layout, locKey, meta = getPlayerLayout(ply, shouldOpen)
	layout = layout or {}

	local defs = {}
	for _, id in ipairs(layout) do
		local sub = EPS.GetSubsystem(id)
		if sub then
			defs[#defs + 1] = sub
		end
	end

	if #defs == 0 then
		local fallback = sanitizeLayout({ "replicators.general", "forcefields" }, true)
		for _, id in ipairs(fallback) do
			local sub = EPS.GetSubsystem(id)
			if sub then
				defs[#defs + 1] = sub
			end
		end
	end

	if not locKey or locKey == "" then
		local _, normalized = EPS.GetLocationState(nil)
		locKey = normalized
	end

	if EPS.State and EPS.State.locationMeta and locKey then
		local stored = EPS.State.locationMeta[string.lower(locKey)]
		if stored then
			meta = meta or {}
			if meta.deck == nil or meta.deck == "" then meta.deck = stored.deck end
			if meta.section == nil or meta.section == "" then meta.section = stored.section end
			if meta.sectionId == nil then meta.sectionId = stored.sectionId end
		end
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
	net.WriteUInt(clampToUInt(#defs, 8), 8)

	for _, sub in ipairs(defs) do
		local baseMax = EPS.GetSubsystemBaseMax and EPS.GetSubsystemBaseMax(sub.id) or (sub.max or budget)
		local overdrive = EPS.GetSubsystemOverdrive and EPS.GetSubsystemOverdrive(sub.id) or baseMax
		if overdrive < baseMax then overdrive = baseMax end

		net.WriteString(sub.id)
		net.WriteString(sub.label or "")
		net.WriteUInt(clampToUInt(sub.min or 0, 16), 16)
		net.WriteUInt(clampToUInt(baseMax, 16), 16)
		net.WriteUInt(clampToUInt(overdrive, 16), 16)
		net.WriteUInt(clampToUInt(EPS.GetAllocation(locKey, sub.id), 16), 16)
		net.WriteUInt(clampToUInt(EPS.GetDemand(locKey, sub.id), 16), 16)
	end

	net.Send(ply)
end

local function flushFullStateQueue()
	if not EPS._pendingFullState then return end
	local queue = EPS._pendingFullState
	EPS._pendingFullState = setmetatable({}, { __mode = "k" })
	for ply, data in pairs(queue) do
		if data and IsValid(ply) and ply:IsPlayer() then
			sendFullStateImmediate(ply, data.shouldOpen)
		end
	end
end

-- Queue state pushes so we never try to start a new net message while another is mid-write.
local function sendFullState(target, shouldOpen)
	if not EPS.State then return end

	local recipients = normalizeRecipients(target)
	if #recipients == 0 then return end

	EPS._pendingFullState = EPS._pendingFullState or setmetatable({}, { __mode = "k" })

	for _, ply in ipairs(recipients) do
		if IsValid(ply) and ply:IsPlayer() then
			local entry = EPS._pendingFullState[ply]
			if entry then
				entry.shouldOpen = entry.shouldOpen or shouldOpen
			else
				EPS._pendingFullState[ply] = { shouldOpen = shouldOpen }
			end
		end
	end

	if EPS._fullStateFlushScheduled then return end

	EPS._fullStateFlushScheduled = true
	timer.Simple(0, function()
		EPS._fullStateFlushScheduled = nil
		flushFullStateQueue()
	end

	sendFullState = function(target, shouldOpen)
function EPS.BroadcastState(target, shouldOpen)
	sendFullState(target, shouldOpen)
end

net.Receive(EPS.NET.Open, function(_, ply)
	if not isPlayerAllowed(ply) then return end
	sendFullState(ply, true)
end)

net.Receive(EPS.NET.Update, function(_, ply)
	if not isPlayerAllowed(ply) then return end

	local locKey = net.ReadString()
	local count = net.ReadUInt(8)
	local received = {}

	for _ = 1, count do
		local id = net.ReadString()
		local value = net.ReadUInt(16)
		received[id] = value
	end

	if locKey and locKey ~= "" then
		local _, normalized = EPS.GetLocationState(locKey)
		locKey = normalized
	else
		locKey = nil
	end

	local cachedLayout = EPS._playerLayouts and EPS._playerLayouts[ply]
	if cachedLayout and locKey and cachedLayout.locKey ~= locKey then
		-- Resend state if the client's cached location drifts from the server record.
		sendFullState(ply, false)
		return
	end

	local ok, reason = applyAllocations(ply, received, locKey)

	if not ok then
		sendFullState(ply, false)
		if reason and IsValid(ply) and ply.ChatPrint then
			ply:ChatPrint("[EPS] " .. reason)
		end
		return
	end

	sendFullState(nil, false)
end)

local function pickWeighted(weights)
	local total = 0
	for _, weight in pairs(weights or {}) do
		if weight and weight > 0 then
			total = total + weight
		end
	end
	if total <= 0 then return nil end

	local roll = math.Rand(0, total)
	for id, weight in pairs(weights) do
		if weight and weight > 0 then
			if roll <= weight then return id end
			roll = roll - weight
		end
	end
end

local spikeTimerId = "EPS_SpikeTimer"
local currentSpike
local scheduleNextSpike

local function panelSupportsSubsystem(panelInfo, subsystemId)
	if not panelInfo then return false end
	local layout = panelInfo.layout
	if not layout then
		layout = select(1, buildLayoutFor(panelInfo.deck, panelInfo.sectionName))
		panelInfo.layout = layout
		if IsValid(panelInfo.entity) then
			registerPanelLayout(panelInfo.entity, layout)
		end
	end
	for _, id in ipairs(layout) do
		if id == subsystemId then return true end
	end
	return false
end

local function collectPanelInfos(targetLocKey)
	local list = {}
	if not EPS._panelRefs then return list end

	local normalizedTarget = targetLocKey and string.lower(targetLocKey) or nil

	for panel, info in pairs(EPS._panelRefs) do
		if IsValid(panel) and info then
			EPS._UpdatePanelSection(panel)
			info = EPS._panelRefs[panel]
			if info then
				info.entity = panel
				local panelKey = info.locationKeyLower or (info.locationKey and string.lower(info.locationKey)) or nil
				if not normalizedTarget or panelKey == normalizedTarget then
					list[#list + 1] = info
				end
			end
		else
			EPS._panelRefs[panel] = nil
		end
	end

	return list
end

registerPanelLayout = function(panel, layout)
	if not IsValid(panel) or not panel.SetSubsystemMask then return end
	panel:SetSubsystemMask(layout or {})
end

local function pickRandomPanelInfo(targetLocKey)
	local infos = collectPanelInfos(targetLocKey)
	if #infos == 0 then return end
	return infos[math.random(#infos)]
end

local function pickPanelForSubsystem(subsystemId, targetLocKey)
	local infos = collectPanelInfos(targetLocKey)
	if #infos == 0 then return end

	local matches = {}
	for _, info in ipairs(infos) do
		if panelSupportsSubsystem(info, subsystemId) then
			matches[#matches + 1] = info
		end
	end

	if #matches > 0 then
		return matches[math.random(#matches)]
	end

	return infos[math.random(#infos)]
end

EPS._overpowerWatch = EPS._overpowerWatch or {}

local function makeDamageKey(locKey, subId)
	return string.format("%s::%s", normalizeLocKey(locKey), subId or "unknown")
end

local function pickPanelEntityForSubsystem(subsystemId, targetLocKey)
	local normalizedTarget = targetLocKey and string.lower(targetLocKey) or nil
	local preferredKey = normalizedTarget or "global"
	local recent = EPS._recentPanelByLocation and EPS._recentPanelByLocation[preferredKey]
	if IsValid(recent) then
		local info = EPS._panelRefs and EPS._panelRefs[recent]
		if info and panelSupportsSubsystem(info, subsystemId) then
			return recent
		elseif EPS._recentPanelByLocation then
			EPS._recentPanelByLocation[preferredKey] = nil
		end
	end

	local infos = collectPanelInfos(targetLocKey)
	if #infos == 0 then return nil end

	local matches = {}
	for _, info in ipairs(infos) do
		if panelSupportsSubsystem(info, subsystemId) and IsValid(info.entity) then
			matches[#matches + 1] = info.entity
		end
	end

	if #matches == 0 then return nil end
	return matches[math.random(#matches)]
end

local function cleanupDamageEffects(state)
	if not state then return end
	if IsValid(state.fireEnt) then
		state.fireEnt:Fire("Extinguish", "", 0)
		state.fireEnt:Remove()
	end
	state.fireEnt = nil
	state.fireSpawned = false
end

local function spawnDamageFire(state)
	if not state or state.fireSpawned then return end
	local panel = state.panel
	if not IsValid(panel) then return end

	local fire = ents.Create("env_fire")
	if not IsValid(fire) then return end
	fire:SetPos(panel:LocalToWorld(panel.GetFireOffset and panel:GetFireOffset() or panel:GetSparkOffset()))
	fire:SetKeyValue("spawnflags", "128") -- smokeless, start on
	fire:SetKeyValue("firesize", "64")
	fire:SetKeyValue("fireattack", "4")
	fire:SetKeyValue("health", "999")
	fire:SetKeyValue("damagescale", "2")
	fire:SetParent(panel)
	fire:Spawn()
	fire:Activate()
	fire:Fire("StartFire", "", 0)

	state.fireSpawned = true
	state.fireEnt = fire
end


local function startSubsystemDamage(locKey, subId, severity)
	local damageKey = makeDamageKey(locKey, subId)
	if EPS._damageStates[damageKey] then return EPS._damageStates[damageKey] end

	local panel = pickPanelEntityForSubsystem(subId, locKey)
	if not IsValid(panel) then return nil end
	rememberPanelForLocation(panel, locKey)

	local now = CurTime()
	local clampedSeverity = math.Clamp(severity or 0, 0, 1)
	local state = {
		id = subId,
		key = damageKey,
		locKey = normalizeLocKey(locKey),
		panel = panel,
		started = now,
		lastSpark = 0,
		progress = 0,
		repairTime = DAMAGE_REPAIR_TIME,
		fireSpawned = false,
		severity = clampedSeverity,
		lockedSeverity = clampedSeverity, -- cache initial overload strength so visuals stay consistent until repaired
	}

	EPS._damageStates[damageKey] = state

	panel._epsDamage = panel._epsDamage or {}
	panel._epsDamage[damageKey] = state

	panel:TriggerOverpowerSparks()
	panel:EmitSound("ambient/energy/zap1.wav", 70, 100, 0.65)

	return state
end

local function completeDamageRepair(state, repairedBy, opts)
	if not state or state.repaired then return end
	opts = opts or {}
	state.repaired = true
	cleanupDamageEffects(state)

	local panel = state.panel
	if IsValid(panel) and panel._epsDamage then
		panel._epsDamage[state.key] = nil
		if next(panel._epsDamage) == nil then
			panel._epsDamage = nil
		end
		if not opts.silent then
			panel:EmitSound("buttons/button19.wav", 65, 110, 0.6)
		end
	end

	EPS._damageStates[state.key] = nil

	local watch = EPS._overpowerWatch and EPS._overpowerWatch[state.key]
	if watch then
		watch.since = 0
		local currentMult = watch.respawnMultiplier or 1
		local nextMult = math.max(currentMult * DAMAGE_RESPAWN_ACCEL, DAMAGE_RESPAWN_MIN_MULT)
		watch.respawnMultiplier = nextMult
	end
end

function EPS._CompleteDamageRepair(state, repairedBy, opts)
	completeDamageRepair(state, repairedBy, opts)
end

hook.Add("Think", "EPS_OverpowerSparkLoop", function()
	if not EPS.State or not EPS.State.locations then return end
	if not haveActivePanels() then return end

	local now = CurTime()
	local dt = FrameTime()

	for locKey, state in pairs(EPS.State.locations or {}) do
		local normalizedLoc = normalizeLocKey(locKey)
		for subId, alloc in pairs(state.allocations or {}) do
			local demand = EPS.GetDemand(normalizedLoc, subId) or 0
			local overdrive = EPS.GetSubsystemOverdrive and EPS.GetSubsystemOverdrive(subId) or demand
			local extraCap = math.max(overdrive - demand, 0)
			local extraAlloc = math.max(alloc - demand, 0)
			local ratio = extraCap > 0 and (extraAlloc / extraCap) or 0
			local severity = computeSeverityFromRatio(ratio)

			local watchKey = makeDamageKey(normalizedLoc, subId)
			local entry = EPS._overpowerWatch[watchKey]
			if not entry then
				entry = { since = 0 }
				EPS._overpowerWatch[watchKey] = entry
			end
			entry.since = entry.since or 0
			entry.severity = severity
			entry.respawnMultiplier = entry.respawnMultiplier or 1
			local baseDelay = severityLerp(severity, OVERPOWER_DAMAGE_DELAY_MIN, OVERPOWER_DAMAGE_DELAY_MAX)
			entry.baseDelay = baseDelay
			local scaledDelay = math.max(baseDelay * (entry.respawnMultiplier or 1), DAMAGE_RESPAWN_MIN_DELAY)
			entry.delay = scaledDelay

			local damageState = EPS._damageStates[watchKey]
			if damageState then
				damageState.liveSeverity = severity
			end

			if not damageState then
				if ratio >= OVERPOWER_THRESHOLD then
					if entry.since == 0 then
						entry.since = now
					end
					if now - entry.since >= (entry.delay or OVERPOWER_DAMAGE_DELAY_MAX) then
						startSubsystemDamage(normalizedLoc, subId, severity)
						entry.since = now
					end
				else
					entry.since = 0
					entry.respawnMultiplier = 1
				end
			else
				entry.since = now
			end
		end
	end

	for key, state in pairs(EPS._damageStates) do
		if not state or state.repaired then
			EPS._damageStates[key] = nil
		else
			local panel = state.panel
			if not IsValid(panel) then
				EPS._CompleteDamageRepair(state, nil, { silent = true })
			else
				local severity = math.Clamp(state.lockedSeverity or state.severity or 0, 0, 1)
				local sparkInterval = severityLerp(severity, DAMAGE_SPARK_INTERVAL_MIN, DAMAGE_SPARK_INTERVAL_MAX)
				if now >= (state.lastSpark or 0) + sparkInterval then
					panel:TriggerOverpowerSparks()
					state.lastSpark = now
				end

				local fireDelay = severityLerp(severity, DAMAGE_FIRE_DELAY_MIN, DAMAGE_FIRE_DELAY_MAX)
				if not state.fireSpawned and now - state.started >= fireDelay then
					spawnDamageFire(state)
				end

				if state.progress and state.progress > 0 then
					local last = state.lastRepair or 0
					if now - last > 0.4 then
						state.progress = math.max(0, state.progress - dt * 2)
					end
				end
			end
		end
	end
end)

local function pickSubsystemForPanel(panelInfo)
	if not panelInfo then return end

	local layout = panelInfo.layout
	if not layout then
		layout = select(1, buildLayoutFor(panelInfo.deck, panelInfo.sectionName))
		panelInfo.layout = layout
		if IsValid(panelInfo.entity) then
			registerPanelLayout(panelInfo.entity, layout)
		end
	end
	if not layout or #layout == 0 then return end

	local cfg = EPS.Config.Spikes or {}
	local weights = cfg.Weights or {}

	local weighted, total = {}, 0
	for _, id in ipairs(layout) do
		local weight = weights[id] or 1
		if weight > 0 then
			total = total + weight
			weighted[#weighted + 1] = { id = id, weight = weight }
		end
	end

	if total <= 0 then
		return layout[math.random(#layout)]
	end

	local roll = math.Rand(0, total)
	for _, entry in ipairs(weighted) do
		if roll <= entry.weight then
			return entry.id
		end
		roll = roll - entry.weight
	end

	return weighted[#weighted] and weighted[#weighted].id or layout[1]
end

haveActivePanels = function()
	if not EPS._panelRefs then return false end
	for panel in pairs(EPS._panelRefs) do
		if IsValid(panel) then
			return true
		end
	end
	return false
end

local function safeFormat(template, fallback, ...)
	local args = { ... }
	local ok, formatted = pcall(string.format, template, unpack(args))
	if ok then return formatted end
	MsgN("[EPS] Invalid spike alert template, falling back to default.")
	local okFallback, fallbackMsg = pcall(string.format, fallback, unpack(args))
	if okFallback then return fallbackMsg end
	return fallback
end

local function broadcastSpikeAlert(spike)
	if not spike or not haveActivePanels() then return end
	local panel = spike.panel
	if not IsValid(panel) then return end

	local info = EPS._panelRefs and EPS._panelRefs[panel]
	if not info or type(info) ~= "table" then
		EPS._UpdatePanelSection(panel)
		info = EPS._panelRefs and EPS._panelRefs[panel]
	end

	local supportsTarget = info and panelSupportsSubsystem(info, spike.target)

	local cfg = EPS.Config.Spikes or {}
	local cmd = cfg.AlertCommand
	if not cmd or cmd == "" then return end

	local subLabel = spike.sub and (spike.sub.label or spike.sub.id) or tostring(spike.target or "EPS subsystem")
	local deck = spike.deck or (supportsTarget and info and info.deck)
	local section = spike.sectionName or (supportsTarget and info and info.sectionName)
	spike.deck = deck
	spike.sectionName = section

	local deckText = deck and tostring(deck) or "?"
	local sectionName = section or "Unknown Section"

	local fallback = "Power fluctuations detected in %s. Deck %s, %s."
	local template = cfg.AlertMessage or fallback
	local message = safeFormat(template, fallback, subLabel, deckText, sectionName)

	local full = string.Trim(cmd .. " " .. message)
	if full == "" then return end

	if RunConsoleCommand then
		RunConsoleCommand("say", full)
	else
		game.ConsoleCommand("say " .. full .. "\n")
	end
end

local function broadcastRecoveryAlert(spike)
	if not spike or not haveActivePanels() then return end
	local panel = spike.panel
	if not IsValid(panel) then return end

	local info = EPS._panelRefs and EPS._panelRefs[panel]
	if not info or type(info) ~= "table" then
		EPS._UpdatePanelSection(panel)
		info = EPS._panelRefs and EPS._panelRefs[panel]
	end

	local supportsTarget = info and panelSupportsSubsystem(info, spike.target)

	local cfg = EPS.Config.Spikes or {}
	local cmd = cfg.AlertCommand
	if not cmd or cmd == "" then return end

	local subLabel = spike.sub and (spike.sub.label or spike.sub.id) or tostring(spike.target or "EPS subsystem")
	local deck = spike.deck or (supportsTarget and info and info.deck)
	local section = spike.sectionName or (supportsTarget and info and info.sectionName)
	spike.deck = deck
	spike.sectionName = section

	local deckText = deck and tostring(deck) or "?"
	local sectionName = section or "Unknown Section"

	local fallback = "Power allocation stabilized for %s. Deck %s, %s."
	local template = cfg.AlertRecoveryMessage or fallback
	local message = safeFormat(template, fallback, subLabel, deckText, sectionName)

	local full = string.Trim(cmd .. " " .. message)
	if full == "" then return end

	if RunConsoleCommand then
		RunConsoleCommand("say", full)
	else
		game.ConsoleCommand("say " .. full .. "\n")
	end
end

local function beginSpike(target, panelInfo, opts)
	local cfg = EPS.Config.Spikes or {}
	if not cfg.Enabled then return nil, "disabled" end

	opts = opts or {}

	if opts.force and currentSpike then
		currentSpike.responded = true
		currentSpike = nil
	elseif currentSpike and not opts.allowConcurrent then
		return nil, "active"
	end

	if opts.resetTimer then
		timer.Remove(spikeTimerId)
	end

	local targetId = target
	local info = panelInfo
	if info and not IsValid(info.entity) then
		info = nil
	end

	if not info then
		-- Only choose from panels that actually exist and support the subsystem
		if not targetId then
			local panelInfos = collectPanelInfos()
			if #panelInfos == 0 then
				return nil, "no_panel"
			end

			local candidatePanels = {}
			for _, pInfo in ipairs(panelInfos) do
				local layout = select(1, buildLayoutFor(pInfo.deck, pInfo.sectionName))
				for _, id in ipairs(layout or {}) do
					candidatePanels[#candidatePanels + 1] = { panelInfo = pInfo, subsystem = id }
				end
			end

			if #candidatePanels == 0 then
				return nil, "no_target"
			end

			local weights = cfg.Weights or {}
			local weightedPool = {}
			local totalWeight = 0
			for _, entry in ipairs(candidatePanels) do
				local weight = weights[entry.subsystem] or 1
				if weight > 0 then
					totalWeight = totalWeight + weight
					weightedPool[#weightedPool + 1] = { entry = entry, weight = weight }
				end
			end

			if totalWeight <= 0 then
				return nil, "no_target"
			end

			local roll = math.Rand(0, totalWeight)
			local picked
			for _, weighted in ipairs(weightedPool) do
				if roll <= weighted.weight then
					picked = weighted.entry
					break
				end
				roll = roll - weighted.weight
			end

			picked = picked or weightedPool[#weightedPool].entry
			info = picked.panelInfo
			targetId = picked.subsystem
		else
			info = pickPanelForSubsystem(targetId)
		end
	end

	if not info or not IsValid(info.entity) then
		return nil, "no_panel"
	end

	if not targetId then
		return nil, "no_target"
	end
	if opts.requirePanel and (not info or not IsValid(info.entity)) then
		return nil, "no_panel"
	end

	local panel = info and info.entity or nil
	local locKey = info and info.locationKey
	if locKey then
		local _, normalized = EPS.GetLocationState(locKey)
		locKey = normalized
	else
		local _, normalized = EPS.GetLocationState(nil)
		locKey = normalized
	end

	local extraMin = cfg.ExtraDemandMin or 5
	local extraMax = cfg.ExtraDemandMax or 10
	if extraMax < extraMin then extraMin, extraMax = extraMax, extraMin end
	local extra = opts.extra or math.random(extraMin, extraMax)

	local defaultDemand = EPS.GetSubsystemDefault and EPS.GetSubsystemDefault(targetId) or 0
	local currentDemand = EPS.GetDemand(locKey, targetId) or defaultDemand
	local baseDemand = math.max(currentDemand, defaultDemand)
	local overdrive = EPS.GetSubsystemOverdrive and EPS.GetSubsystemOverdrive(targetId) or (defaultDemand + extra)
	local newDemand = math.min(baseDemand + extra, overdrive)
	EPS.SetDemand(locKey, targetId, newDemand)
	sendFullState(nil, false)

	local durMin = cfg.DurationMin or 10
	local durMax = cfg.DurationMax or 20
	if durMax < durMin then durMin, durMax = durMax, durMin end
	local duration = opts.duration or math.Rand(durMin, durMax)

	local subsystem = EPS.GetSubsystem and EPS.GetSubsystem(targetId) or nil
	local deck = info and info.deck or nil
	local sectionName = info and info.sectionName or nil

	local spikeContext = {
		target = targetId,
		sub = subsystem,
		panel = panel,
		deck = deck,
		sectionName = sectionName,
		sectionId = info and info.sectionId or nil,
		startAlloc = EPS.GetAllocation(locKey, targetId) or 0,
		responded = false,
		expires = CurTime() + duration,
		manual = opts.manual or false,
		locKey = locKey,
	}

	currentSpike = spikeContext

	if IsValid(panel) then
		broadcastSpikeAlert(spikeContext)
	end

	timer.Simple(duration, function()
		if not EPS.State then return end

		local baseline = EPS.GetSubsystemDefault and EPS.GetSubsystemDefault(targetId)
		if baseline == nil then
			baseline = 0
			for _, sub in EPS.IterSubsystems() do
				if sub.id == targetId then
					baseline = sub.default or sub.min or 0
					break
				end
			end
		end
		EPS.SetDemand(locKey, targetId, baseline)
		sendFullState(nil, false)

		if currentSpike == spikeContext then
			if not spikeContext.responded then
				broadcastRecoveryAlert(spikeContext)
			end
			currentSpike = nil
		elseif not spikeContext.responded then
			broadcastRecoveryAlert(spikeContext)
		end
		scheduleNextSpike()
	end)

	return spikeContext
end

scheduleNextSpike = function()
	local cfg = EPS.Config.Spikes
	if not cfg or not cfg.Enabled then return end

	local intervalMin = cfg.IntervalMin or 30
	local intervalMax = cfg.IntervalMax or 60
	if intervalMax < intervalMin then intervalMin, intervalMax = intervalMax, intervalMin end

	local interval = math.Rand(intervalMin, intervalMax)
	if timer.Exists(spikeTimerId) then
		timer.Remove(spikeTimerId)
	end

	timer.Create(spikeTimerId, interval, 1, function()
		local context, reason = beginSpike(nil, nil, {})
		if not context then
			if reason ~= "disabled" then
				scheduleNextSpike()
			end
		end
	end)
end

local function triggerManualSpike(ply)
	if not isPlayerPrivileged(ply) then
		if IsValid(ply) and ply.ChatPrint then
			ply:ChatPrint("[EPS] You need command clearance to inject a power spike.")
		end
		return false
	end

	local panelInfo = pickRandomPanelInfo()
	local panel = panelInfo and panelInfo.entity
	if not IsValid(panel) then
		if IsValid(ply) and ply.ChatPrint then
			ply:ChatPrint("[EPS] No EPS panels are active to anchor that spike.")
		end
		return false
	end

	local subsystemId = pickSubsystemForPanel(panelInfo)
	if not subsystemId then
		if IsValid(ply) and ply.ChatPrint then
			ply:ChatPrint("[EPS] That panel has no routed subsystems to spike right now.")
		end
		return false
	end

	local context, reason = beginSpike(subsystemId, panelInfo, {
		requirePanel = true,
		manual = true,
		force = true,
		resetTimer = true,
	})

	if not context then
		if IsValid(ply) and ply.ChatPrint then
			local err = "[EPS] Unable to trigger a spike."
			if reason == "active" then
				err = "[EPS] A spike is already underway."
			elseif reason == "no_panel" then
				err = "[EPS] Couldn't find a panel to host the spike."
			elseif reason == "no_target" then
				err = "[EPS] No subsystem could be selected for that spike."
			elseif reason == "disabled" then
				err = "[EPS] Automated spikes are currently disabled."
			end
			ply:ChatPrint(err)
		end
		return false
	end

	if IsValid(ply) and ply.ChatPrint then
		local label = context.sub and (context.sub.label or context.sub.id) or subsystemId
		local deckText = context.deck and tostring(context.deck) or "?"
		local sectionName = context.sectionName or "Unknown Section"
		ply:ChatPrint(string.format("[EPS] Manual spike engaged on %s (Deck %s, %s).", label, deckText, sectionName))
	end

	return true
end

local function triggerManualDamage(ply)
	if not isPlayerPrivileged(ply) then
		if IsValid(ply) and ply.ChatPrint then
			ply:ChatPrint("[EPS] You need command clearance to sabotage a panel.")
		end
		return false
	end

	local panelInfo = pickRandomPanelInfo()
	local panel = panelInfo and panelInfo.entity
	if not IsValid(panel) then
		if IsValid(ply) and ply.ChatPrint then
			ply:ChatPrint("[EPS] No EPS panels are active to damage.")
		end
		return false
	end

	local subsystemId = pickSubsystemForPanel(panelInfo)
	if not subsystemId then
		if IsValid(ply) and ply.ChatPrint then
			ply:ChatPrint("[EPS] That panel has no routed subsystems to overload.")
		end
		return false
	end

	local locKey = panelInfo.locationKey
	local _, normalizedLoc = EPS.GetLocationState(locKey)
	locKey = normalizedLoc

	local baseDemand = EPS.GetSubsystemDefault(subsystemId) or 0
	local overdrive = EPS.GetSubsystemOverdrive(subsystemId) or baseDemand
	if overdrive <= baseDemand then
		overdrive = baseDemand + 5
	end

	local clampedOverdrive = EPS.ClampAllocationForSubsystem and EPS.ClampAllocationForSubsystem(subsystemId, overdrive) or overdrive
	if clampedOverdrive then
		overdrive = clampedOverdrive
	end

	local desiredDemand = math.floor(overdrive * 0.6)
	if desiredDemand < baseDemand then
		desiredDemand = baseDemand
	end
	if desiredDemand >= overdrive then
		desiredDemand = math.max(overdrive - 5, 0)
	end

	EPS.SetDemand(locKey, subsystemId, desiredDemand)
	EPS.SetAllocation(locKey, subsystemId, overdrive)
	EPS._RunChangeHookIfNeeded(locKey)
	sendFullState(nil, false)

	local damageState = startSubsystemDamage(locKey, subsystemId, 1)
	if not damageState then
		if IsValid(ply) and ply.ChatPrint then
			ply:ChatPrint("[EPS] Failed to induce a damage cascade.")
		end
		return false
	end

	if IsValid(ply) and ply.ChatPrint then
		local label = subsystemId
		local sub = EPS.GetSubsystem and EPS.GetSubsystem(subsystemId)
		if sub and sub.label then
			label = sub.label
		end
		local deckText = panelInfo.deck and tostring(panelInfo.deck) or "?"
		local sectionName = panelInfo.sectionName or "Unknown Section"
		ply:ChatPrint(string.format("[EPS] Forced overload on %s (Deck %s, %s).", label, deckText, sectionName))
	end

	return true
end

hook.Add("Initialize", "EPS_StartSpikesOnInit", function()
	scheduleNextSpike()
end)

hook.Add("PlayerInitialSpawn", "EPS_SendInitialState", function(ply)
	timer.Simple(3, function()
		if IsValid(ply) then
			sendFullState(ply, false)
		end
	end)
end)

local function handleChatCommand(ply, text)
	local trimmed = string.Trim(text or "")
	if trimmed == "" then return end

	local lowered = trimmed:lower()

	local cmd = EPS.Config.Commands and EPS.Config.Commands.Chat
	if cmd and cmd ~= "" and lowered == cmd:lower() then
		if isPlayerAllowed(ply) then
			sendFullState(ply, true)
			return ""
		end
		return
	end

	local spikeCfg = EPS.Config.Spikes or {}
	local forceCmd = spikeCfg.ForceCommand
	if forceCmd and forceCmd ~= "" and lowered == forceCmd:lower() then
		triggerManualSpike(ply)
		return ""
	end

	local damageCmd = EPS.Config.Commands and EPS.Config.Commands.Damage
	local matchedDamage = false
	if damageCmd and damageCmd ~= "" then
		matchedDamage = lowered == damageCmd:lower()
	else
		matchedDamage = lowered == "/epsdamage"
	end

	if matchedDamage then
		triggerManualDamage(ply)
		return ""
	end
end

hook.Add("PlayerSay", "EPS_ChatCommand", handleChatCommand)

hook.Add("Star_Trek.tools.sonic_driver.trace_hit", "EPS_SonicRepair", function(ply, swep, ent, hitPos)
	if not IsValid(ent) or ent:GetClass() ~= "ent_eps_panel" then return end
	if ent.HandleSonicRepair then
		return ent:HandleSonicRepair(ply, swep, hitPos)
	end
end)

local function cancelMaintenanceAttempt(ply, message)
	local attempts = EPS._maintenanceScanAttempts
	if not attempts then return end
	local attempt = attempts[ply]
	if not attempt then return end
	attempts[ply] = nil
	if attempt.timerId then
		timer.Remove(attempt.timerId)
	end
	if IsValid(ply) and message and message ~= "" then
		ply:PrintMessage(HUD_PRINTCENTER, message)
	end
end

local function startMaintenanceAttempt(ply, ent, info, normalized)
	EPS._maintenanceScanAttempts = EPS._maintenanceScanAttempts or setmetatable({}, { __mode = "k" })
	local attempts = EPS._maintenanceScanAttempts
	local attempt = {
		panel = ent,
		info = info,
		normalized = normalized,
		started = CurTime(),
		lastProgressMsg = 0,
	}
	attempts[ply] = attempt

	local timerId = string.format("EPS_MaintScan_%d", ply:EntIndex())
	attempt.timerId = timerId

	local function abort(msg)
		cancelMaintenanceAttempt(ply, msg or "EPS maintenance scan aborted.")
	end

	local function finalize()
		cancelMaintenanceAttempt(ply)
		local ok, data, report = EPS.EnterMaintenance(ent, ply)
		if ok then
			if report then
				sendTricorderReport(ply, ent, report)
			end
			return
		end
		if type(data) == "string" and data ~= "" and IsValid(ply) and ply.ChatPrint then
			ply:ChatPrint("[EPS] " .. data)
		end
		local fallback = buildPanelPowerReport(info, normalized, "Summary: EPS diagnostics available; maintenance clamp not engaged.", "[Tricorder] EPS Diagnostic Scan")
		sendTricorderReport(ply, ent, fallback)
	end

	timer.Create(timerId, MAINTENANCE_SCAN_INTERVAL, 0, function()
		if not IsValid(ply) or not ply:IsPlayer() then
			abort()
			return
		end
		if not ply:KeyDown(IN_ATTACK) then
			abort("EPS maintenance scan aborted.")
			return
		end
		local weapon = ply:GetActiveWeapon()
		if not IsValid(weapon) or weapon:GetClass() ~= "odn_scanner" then
			abort("EPS maintenance scan aborted.")
			return
		end

		local startPos = ply:GetShootPos()
		local dir = ply:GetAimVector()
		local trace = util.TraceLine({
			start = startPos,
			endpos = startPos + dir * ODN_SCAN_RANGE,
			filter = ply,
			mask = MASK_SHOT,
		})

		if not IsValid(trace.Entity) or trace.Entity ~= ent then
			abort("EPS maintenance alignment lost.")
			return
		end

		attempt.anchor = attempt.anchor or trace.HitPos
		if attempt.anchor and trace.HitPos and attempt.anchor:DistToSqr(trace.HitPos) > (MAINTENANCE_AIM_TOLERANCE * MAINTENANCE_AIM_TOLERANCE) then
			abort("EPS maintenance alignment lost.")
			return
		end

		local elapsed = CurTime() - attempt.started
		local progress = math.Clamp(elapsed / MAINTENANCE_SCAN_TIME, 0, 1)

		if CurTime() - (attempt.lastProgressMsg or 0) >= 0.35 then
			attempt.lastProgressMsg = CurTime()
			ply:PrintMessage(HUD_PRINTCENTER, string.format("Channeling plasma purge... %d%%", math.floor(progress * 100)))
		end

		if elapsed >= MAINTENANCE_SCAN_TIME then
			timer.Remove(timerId)
			finalize()
		end
	end)
end

local function tryStartMaintenanceFromScan(ply)
	if not IsValid(ply) or not ply:IsPlayer() then return end

	local startPos = ply:GetShootPos()
	local dir = ply:GetAimVector()
	local trace = util.TraceLine({
		start = startPos,
		endpos = startPos + dir * ODN_SCAN_RANGE,
		filter = ply,
		mask = MASK_SHOT,
	})

	local ent = trace.Entity
	if not IsValid(ent) or ent:GetClass() ~= "ent_eps_panel" then return end

	local info = getPanelInfo(ent)
	if not info then return end

	local locKey = info.locationKey or info.locationKeyLower or "global"
	local normalized = normalizeLocKey(locKey)
	local lockRecord = getMaintenanceState(normalized)

	if lockRecord and lockRecord.active then
		local savedDemand = lockRecord.savedDemand or {}
		local reportLines

		if lockRecord.telemetry then
			reportLines = buildMaintenanceReport(info, normalized, savedDemand, lockRecord.telemetry)
		else
			local cachedLines
			if EPS.GetPanelTelemetry then
				cachedLines = EPS.GetPanelTelemetry(ent)
			end
			if istable(cachedLines) and #cachedLines > 0 then
				reportLines = cachedLines
			end
		end

		if not reportLines then
			reportLines = buildMaintenanceReport(info, normalized, savedDemand)
		end

		sendTricorderReport(ply, ent, reportLines)
		return
	end

	local attempts = EPS._maintenanceScanAttempts
	if attempts then
		local existing = attempts[ply]
		if existing and (not IsValid(existing.panel) or existing.panel ~= ent) then
			cancelMaintenanceAttempt(ply)
		end
		if existing and existing.panel == ent then
			return -- timer already running for this panel
		end
	end

	startMaintenanceAttempt(ply, ent, info, normalized)
end

local function processReenergizeContact(ply, ent, info, normalized)
	local record = getMaintenanceState(normalized)
	if not record or not record.active then
		return false, buildPanelPowerReport(info, normalized, "Summary: EPS manifold already reading within nominal tolerances.", "[Tricorder] EPS Power Diagnostics")
	end

	record.reenergizeDuration = record.reenergizeDuration or REENERGIZE_REQUIRED_TIME
	record.reenergizeProgress = math.max(record.reenergizeProgress or 0, 0)
	record.lastReenergizeHit = CurTime()
	record.reenergizeProgress = math.min(record.reenergizeProgress + REENERGIZE_STEP, record.reenergizeDuration)

	local percent = math.floor((record.reenergizeProgress / record.reenergizeDuration) * 100)
	if IsValid(ply) then
		ply:PrintMessage(HUD_PRINTCENTER, string.format("Re-energizing EPS manifold... %d%%", percent))
	end

	local timerId = buildTimerName("EPS_ReenergizeDecay", normalized)
	timer.Create(timerId, REENERGIZE_DECAY, 1, function()
		local active = getMaintenanceState(normalized)
		if not active or not active.active then return end
		if CurTime() - (active.lastReenergizeHit or 0) >= REENERGIZE_DECAY then
			active.reenergizeProgress = 0
		end
	end)

	if record.reenergizeProgress >= record.reenergizeDuration then
		local ok, exitRecord, report = EPS.ExitMaintenance(ent, ply)
		return ok, report, exitRecord
	end

	return false
end

hook.Add("KeyPress", "EPS_ODNScannerMaintenance", function(ply, key)
	if key ~= IN_ATTACK then return end
	if not IsValid(ply) then return end
	local weapon = ply:GetActiveWeapon()
	if not IsValid(weapon) then return end
	if weapon:GetClass() ~= "odn_scanner" then return end
	tryStartMaintenanceFromScan(ply)
end)

hook.Add("Star_Trek.tools.hyperspanner.trace_hit", "EPS_HyperspannerReenergize", function(ply, swep, ent, hitPos)
	if not IsValid(ent) or ent:GetClass() ~= "ent_eps_panel" then return end
	local info = getPanelInfo(ent)
	if not info then return end
	local locKey = info.locationKey or info.locationKeyLower or "global"
	local normalized = normalizeLocKey(locKey)

	local ok, report, err = processReenergizeContact(ply, ent, info, normalized)
	if ok then
		sendTricorderReport(ply, ent, report)
		return true
	end

	if report then
		sendTricorderReport(ply, ent, report)
	else
		local fallback = buildPanelPowerReport(info, normalized, "Summary: EPS manifold already reading within nominal tolerances.", "[Tricorder] EPS Power Diagnostics")
		sendTricorderReport(ply, ent, fallback)
	end

	return true
end)

local conCommand = EPS.Config.Commands and EPS.Config.Commands.ConCommand or "eps_open"

concommand.Add(conCommand, function(ply)
	if not IsValid(ply) then return end
	if not isPlayerAllowed(ply) then return end
	sendFullState(ply, true)
end, nil, "Open the EPS routing interface")

concommand.Add("eps_sync", function(ply)
	if IsValid(ply) then
		sendFullState(ply, false)
	else
		sendFullState(nil, false)
	end
end, nil, "Sync EPS state to yourself (or everyone from server console)")

concommand.Add("eps_damage", function(ply)
	if IsValid(ply) and not isPlayerPrivileged(ply) then return end
	triggerManualDamage(ply)
end, nil, "Force an EPS overload on a random routed subsystem")

hook.Add("PlayerDisconnected", "EPS_ClearLayoutCache", function(ply)
	if EPS._playerLayouts then
		EPS._playerLayouts[ply] = nil
	end
	if EPS._lastPanelPerPlayer then
		EPS._lastPanelPerPlayer[ply] = nil
	end
end)

hook.Add("ShutDown", "EPS_StopSpikeTimer", function()
	if timer.Exists(spikeTimerId) then
		timer.Remove(spikeTimerId)
	end
end)