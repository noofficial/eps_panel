if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Layout = include("eps/systems/layout.lua")
local Panels = include("eps/systems/panels.lua")

local Spikes = {}

local TIMER_ID = "EPS_SpikeTimer"

local function haveActivePanels()
	if not EPS._panelRefs then return false end
	for panel in pairs(EPS._panelRefs) do
		if IsValid(panel) then
			return true
		end
	end
	return false
end

local function sendFullState(target, shouldOpen)
	if Spikes._sendFullState then
		Spikes._sendFullState(target, shouldOpen)
	end
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

local function announcePanelAlert(panel, message)
	if not IsValid(panel) or message == "" then return end
	panel:EmitSound("buttons/button14.wav", 60, 110, 0.65)
	for _, ply in ipairs(player.GetHumans()) do
		if IsValid(ply) then
			ply:ChatPrint("[EPS] " .. message)
		end
	end
	local effect = EffectData()
	effect:SetOrigin(panel:LocalToWorld(panel.GetSparkOffset and panel:GetSparkOffset() or Vector(0, 0, 26)))
	effect:SetNormal(panel:GetForward())
	effect:SetMagnitude(1.5)
	effect:SetScale(0.8)
	effect:SetRadius(4)
	util.Effect("cball_explode", effect, true, true)
end

local function broadcastSpikeAlert(context)
	if not context or not haveActivePanels() then return end
	local panel = context.panel
	if not IsValid(panel) then return end

	local info = EPS._panelRefs and EPS._panelRefs[panel]
	if not info or type(info) ~= "table" then
		EPS._UpdatePanelSection(panel)
		info = EPS._panelRefs and EPS._panelRefs[panel]
	end

	local supportsTarget = info and Panels.PanelSupportsSubsystem(info, context.target)

	local cfg = EPS.Config.Spikes or {}
	local cmd = cfg.AlertCommand
	if not cmd or cmd == "" then return end

	local subLabel = context.sub and (context.sub.label or context.sub.id) or tostring(context.target or "EPS subsystem")
	local deck = context.deck or (supportsTarget and info and info.deck)
	local section = context.sectionName or (supportsTarget and info and info.sectionName)
	context.deck = deck
	context.sectionName = section

	local deckText = deck and tostring(deck) or "?"
	local sectionName = section or "Unknown Section"

	local fallback = "Power fluctuations detected in %s. Deck %s, %s."
	local template = cfg.AlertMessage or fallback
	local message = safeFormat(template, fallback, subLabel, deckText, sectionName)
	if message ~= "" then
		announcePanelAlert(panel, message)
	end
end

local function broadcastRecoveryAlert(context)
	if not context or not haveActivePanels() then return end
	local panel = context.panel
	if not IsValid(panel) then return end

	local info = EPS._panelRefs and EPS._panelRefs[panel]
	if not info or type(info) ~= "table" then
		EPS._UpdatePanelSection(panel)
		info = EPS._panelRefs and EPS._panelRefs[panel]
	end

	local supportsTarget = info and Panels.PanelSupportsSubsystem(info, context.target)

	local cfg = EPS.Config.Spikes or {}
	local cmd = cfg.AlertCommand
	if not cmd or cmd == "" then return end

	local subLabel = context.sub and (context.sub.label or context.sub.id) or tostring(context.target or "EPS subsystem")
	local deck = context.deck or (supportsTarget and info and info.deck)
	local section = context.sectionName or (supportsTarget and info and info.sectionName)
	context.deck = deck
	context.sectionName = section

	local deckText = deck and tostring(deck) or "?"
	local sectionName = section or "Unknown Section"

	local fallback = "Power allocation stabilized for %s. Deck %s, %s."
	local template = cfg.AlertRecoveryMessage or fallback
	local message = safeFormat(template, fallback, subLabel, deckText, sectionName)
	if message ~= "" then
		announcePanelAlert(panel, message)
	end
end

function Spikes.Setup(sendFullStateFn)
	if type(sendFullStateFn) == "table" then
		sendFullStateFn = sendFullStateFn.sendFullState
	end
	if type(sendFullStateFn) ~= "function" then return end
	Spikes._sendFullState = sendFullStateFn
end

function Spikes.PickSubsystemForPanel(panelInfo)
	if not panelInfo then return end

	local layout = panelInfo.layout
	if not layout then
		layout = select(1, Layout.BuildLayoutFor(panelInfo.deck, panelInfo.sectionName))
		panelInfo.layout = layout
		if IsValid(panelInfo.entity) then
			Panels.RegisterPanelLayout(panelInfo.entity, layout)
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

function Spikes.HandleAllocationChange(locKey, changes)
	local current = Spikes._current
	if not current or current.locKey ~= locKey then return end
	if not current.target then return end

	local newValue = changes[current.target]
	if newValue == nil then return end

	if not current.responded and newValue ~= current.startAlloc then
		current.responded = true
	end
	current.lastAlloc = newValue
end

function Spikes.Begin(target, panelInfo, opts)
	local cfg = EPS.Config.Spikes or {}
	if not cfg.Enabled then return nil, "disabled" end

	opts = opts or {}

	if opts.force and Spikes._current then
		Spikes._current.responded = true
		Spikes._current = nil
	elseif Spikes._current and not opts.allowConcurrent then
		return nil, "active"
	end

	if opts.resetTimer then
		Spikes.CancelSchedule()
	end

	local targetId = target
	local info = panelInfo
	if info and not IsValid(info.entity) then
		info = nil
	end

	if not info then
		if not targetId then
			local panelInfos = Panels.CollectPanelInfos()
			if #panelInfos == 0 then
				return nil, "no_panel"
			end

			local candidatePanels = {}
			for _, pInfo in ipairs(panelInfos) do
				local layout = select(1, Layout.BuildLayoutFor(pInfo.deck, pInfo.sectionName))
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
			info = Panels.PickPanelForSubsystem(targetId)
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

	local context = {
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

	Spikes._current = context

	if IsValid(panel) then
		broadcastSpikeAlert(context)
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

		if Spikes._current == context then
			if not context.responded then
				broadcastRecoveryAlert(context)
			end
			Spikes._current = nil
		elseif not context.responded then
			broadcastRecoveryAlert(context)
		end
		Spikes.ScheduleNext()
	end)

	return context
end

function Spikes.ScheduleNext()
	local cfg = EPS.Config.Spikes
	if not cfg or not cfg.Enabled then return end

	local intervalMin = cfg.IntervalMin or 30
	local intervalMax = cfg.IntervalMax or 60
	if intervalMax < intervalMin then intervalMin, intervalMax = intervalMax, intervalMin end

	local interval = math.Rand(intervalMin, intervalMax)
	timer.Remove(TIMER_ID)

	timer.Create(TIMER_ID, interval, 1, function()
		local context, reason = Spikes.Begin(nil, nil, {})
		if not context and reason ~= "disabled" then
			Spikes.ScheduleNext()
		end
	end)
end

function Spikes.CancelSchedule()
	if timer.Exists(TIMER_ID) then
		timer.Remove(TIMER_ID)
	end
end

function Spikes.GetCurrent()
	return Spikes._current
end

return Spikes
