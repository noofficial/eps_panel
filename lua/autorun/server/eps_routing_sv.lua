if CLIENT then return end

util.AddNetworkString(EPS.NET.Open)
util.AddNetworkString(EPS.NET.Update)
util.AddNetworkString(EPS.NET.FullState)

EPS._playerLayouts = EPS._playerLayouts or setmetatable({}, { __mode = "k" })
-- Keep tabs on the deployed panels so they all read the same power ledger.
EPS._panelRefs = EPS._panelRefs or setmetatable({}, { __mode = "k" })

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
end

local function syncPanelNetworkState(panel)
	if not IsValid(panel) then return end

	local maxBudget = EPS.GetBudget()
	local totalAllocation = EPS.GetTotalAllocation()
	panel:SetNWInt("eps_max_budget", maxBudget)
	panel:SetNWInt("eps_total_allocation", totalAllocation)
	panel:SetNWInt("eps_available_power", math.max(maxBudget - totalAllocation, 0))
end

function EPS._SyncPanels()
	if not EPS._panelRefs then return end

	for panel in pairs(EPS._panelRefs) do
		if IsValid(panel) then
			EPS._UpdatePanelSection(panel)
			syncPanelNetworkState(panel)
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


local function buildLayoutFor(deck, sectionName)
	local dyn = EPS.Config.DynamicLayouts or {}
	local layout
	local usedDefault = false

	local matchedLayout
	if sectionName and dyn.sectionNames then
		matchedLayout = dyn.sectionNames[sectionName]
		if not matchedLayout and isstring(sectionName) then
			local lowered = string.lower(sectionName)
			matchedLayout = dyn.sectionNames[lowered]
			if not matchedLayout then
				for key, value in pairs(dyn.sectionNames) do
					if isstring(key) and string.lower(key) == lowered then
						matchedLayout = value
						break
					end
				end
			end
		end
	end

	if matchedLayout then
		layout = copyList(matchedLayout)
	elseif deck and dyn.deckOverrides and dyn.deckOverrides[deck] then
		layout = copyList(dyn.deckOverrides[deck])
	else
		layout = copyList(dyn.default)
		usedDefault = true
	end

	if not layout or #layout == 0 then
		layout = copyList(dyn.default)
		usedDefault = true
	end

	return sanitizeLayout(layout, usedDefault)
end

local function getPlayerLayout(ply, forceRefresh)
	if not IsValid(ply) then
		return buildLayoutFor(nil, nil)
	end

	if forceRefresh or not EPS._playerLayouts[ply] then
		local deck, _, sectionName = determineSectionForPos(ply:GetPos())
		EPS._playerLayouts[ply] = buildLayoutFor(deck, sectionName)
	end

	return EPS._playerLayouts[ply]
end

local function normalizeRecipients(target)
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

local function isPlayerAllowed(ply)
	if not IsValid(ply) then return true end

	local allowed = EPS.Config.AllowedGroups or {}
	if #allowed == 0 then return true end

	local plyTeamName
	if team and ply.Team then
		plyTeamName = team.GetName(ply:Team())
	end

	for _, group in ipairs(allowed) do
		if group == "*" then return true end
		if ply:IsUserGroup(group) then return true end
		if plyTeamName and plyTeamName:lower() == group:lower() then return true end
	end

	return false
end

local function isPlayerPrivileged(ply)
	if not IsValid(ply) then return true end
	if ply.IsSuperAdmin and ply:IsSuperAdmin() then return true end
	if ply.IsAdmin and ply:IsAdmin() then return true end
	return isPlayerAllowed(ply)
end

local function clampToUInt(value, bits)
	local maxValue = (2 ^ bits) - 1
	value = math.floor((value or 0) + 0.5)
	if value < 0 then value = 0 end
	if value > maxValue then value = maxValue end
	return value
end

local function sendFullState(target, shouldOpen)
	if not EPS.State then return end

	local recipients = normalizeRecipients(target)
	if #recipients == 0 then return end

	for _, ply in ipairs(recipients) do
		if not IsValid(ply) then continue end

		local layout = getPlayerLayout(ply, shouldOpen)
		local defs = {}
		for _, id in ipairs(layout or {}) do
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

		net.Start(EPS.NET.FullState)
		net.WriteBool(shouldOpen or false)
		net.WriteUInt(clampToUInt(EPS.GetBudget(), 16), 16)
		net.WriteUInt(clampToUInt(EPS.GetTotalAllocation(), 16), 16)
		net.WriteUInt(clampToUInt(#defs, 8), 8)

		for _, sub in ipairs(defs) do
			local baseMax = EPS.GetSubsystemBaseMax and EPS.GetSubsystemBaseMax(sub.id) or (sub.max or EPS.GetBudget())
			local overdrive = EPS.GetSubsystemOverdrive and EPS.GetSubsystemOverdrive(sub.id) or baseMax
			if overdrive < baseMax then overdrive = baseMax end
			net.WriteString(sub.id)
			net.WriteString(sub.label or "")
			net.WriteUInt(clampToUInt(sub.min or 0, 16), 16)
			net.WriteUInt(clampToUInt(baseMax, 16), 16)
			net.WriteUInt(clampToUInt(overdrive, 16), 16)
			net.WriteUInt(clampToUInt(EPS.State.allocations[sub.id] or 0, 16), 16)
			net.WriteUInt(clampToUInt(EPS.State.demand[sub.id] or 0, 16), 16)
		end

		net.Send(ply)
	end
end

function EPS.BroadcastState(target, shouldOpen)
	sendFullState(target, shouldOpen)
end

local function applyAllocations(ply, incoming)
	if not EPS.State then
		EPS.ResetState()
	end

	EPS.State.allocations = EPS.State.allocations or {}
	EPS.State.demand = EPS.State.demand or {}

	local newAlloc = {}
	local sum = 0

	for _, sub in EPS.IterSubsystems() do
		local id = sub.id
		local raw = incoming[id]
		local clamped = raw and EPS.ClampAllocationForSubsystem(id, raw) or EPS.State.allocations[id]
		clamped = clamped or 0
		newAlloc[id] = clamped
		sum = sum + clamped
	end

	if sum > EPS.GetBudget() then
		return false, "Budget exceeded"
	end

	if currentSpike and currentSpike.target then
		local targetId = currentSpike.target
		local newValue = newAlloc[targetId]
		if newValue ~= nil then
			if not currentSpike.responded and newValue ~= currentSpike.startAlloc then
				currentSpike.responded = true
			end
			currentSpike.lastAlloc = newValue
		end
	end

	for id, value in pairs(newAlloc) do
		EPS.State.allocations[id] = value
		EPS.State.demand[id] = math.max(EPS.State.demand[id] or value, value)
	end

	EPS._RunChangeHookIfNeeded()

	return true
end

net.Receive(EPS.NET.Open, function(_, ply)
	if not isPlayerAllowed(ply) then return end
	sendFullState(ply, true)
end)

net.Receive(EPS.NET.Update, function(_, ply)
	if not isPlayerAllowed(ply) then return end

	local count = net.ReadUInt(8)
	local received = {}

	for _ = 1, count do
		local id = net.ReadString()
		local value = net.ReadUInt(16)
		received[id] = value
	end

	local ok, reason = applyAllocations(ply, received)

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
	local layout = buildLayoutFor(panelInfo.deck, panelInfo.sectionName)
	for _, id in ipairs(layout) do
		if id == subsystemId then return true end
	end
	return false
end

local function collectPanelInfos()
	local list = {}
	if not EPS._panelRefs then return list end

	for panel, info in pairs(EPS._panelRefs) do
		if IsValid(panel) and info then
			EPS._UpdatePanelSection(panel)
			info = EPS._panelRefs[panel]
			if info then
				info.entity = panel
				list[#list + 1] = info
			end
		else
			EPS._panelRefs[panel] = nil
		end
	end

	return list
end

local function pickRandomPanelInfo()
	local infos = collectPanelInfos()
	if #infos == 0 then return end
	return infos[math.random(#infos)]
end

local function pickPanelForSubsystem(subsystemId)
	local infos = collectPanelInfos()
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

local function pickSubsystemForPanel(panelInfo)
	if not panelInfo then return end

	local layout = buildLayoutFor(panelInfo.deck, panelInfo.sectionName)
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

local function haveActivePanels()
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

	if not EPS.State or not EPS.State.allocations then
		EPS.ResetState()
	end

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
	if not targetId then
		targetId = pickWeighted(cfg.Weights or {})
	end
	if not targetId then
		return nil, "no_target"
	end

	local info = panelInfo
	if info and not IsValid(info.entity) then
		info = nil
	end
	if not info then
		info = pickPanelForSubsystem(targetId)
	end
	if opts.requirePanel and (not info or not IsValid(info.entity)) then
		return nil, "no_panel"
	end

	local panel = info and info.entity or nil

	local extraMin = cfg.ExtraDemandMin or 5
	local extraMax = cfg.ExtraDemandMax or 10
	if extraMax < extraMin then extraMin, extraMax = extraMax, extraMin end
	local extra = opts.extra or math.random(extraMin, extraMax)
	EPS.State.demand[targetId] = (EPS.State.demand[targetId] or EPS.State.allocations[targetId] or 0) + extra
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
		startAlloc = (EPS.State.allocations and EPS.State.allocations[targetId]) or 0,
		responded = false,
		expires = CurTime() + duration,
		manual = opts.manual or false,
	}

	currentSpike = spikeContext

	if IsValid(panel) then
		broadcastSpikeAlert(spikeContext)
	end

	timer.Simple(duration, function()
		if not EPS.State then return end

		local baseline = 0
		for _, sub in EPS.IterSubsystems() do
			if sub.id == targetId then
				baseline = sub.default or sub.min or 0
				break
			end
		end
		local current = EPS.State.allocations[targetId] or baseline
		EPS.State.demand[targetId] = math.max(baseline, current)
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
end

hook.Add("PlayerSay", "EPS_ChatCommand", handleChatCommand)

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

hook.Add("PlayerDisconnected", "EPS_ClearLayoutCache", function(ply)
	if EPS._playerLayouts then
		EPS._playerLayouts[ply] = nil
	end
end)

hook.Add("ShutDown", "EPS_StopSpikeTimer", function()
	if timer.Exists(spikeTimerId) then
		timer.Remove(spikeTimerId)
	end
end)