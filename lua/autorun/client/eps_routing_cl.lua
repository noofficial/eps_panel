local PANEL
local totalLbl
local scrollPanel
local sliders = {}

local cState = {
	maxBudget = EPS.GetBudget and EPS.GetBudget() or (EPS.Config and EPS.Config.MaxBudget) or 0,
	subs = {},
	totalAlloc = 0,
	localBaseline = 0,
}

local COLOR_TEXT = Color(200, 200, 200)
local COLOR_TEXT_OVER = Color(220, 80, 60)
local COLOR_DEMAND_WARN = Color(220, 140, 40)
local COLOR_PANEL = Color(25, 25, 25, 220)
local COLOR_NAME = Color(230, 230, 230)

local function findSubById(id)
	for index, sub in ipairs(cState.subs) do
		if sub.id == id then
			return sub, index
		end
	end
end

local function clampToUInt16(value)
	value = math.floor((value or 0) + 0.5)
	if value < 0 then value = 0 end
	if value > 65535 then value = 65535 end
	return value
end

local function calculateSum()
	local sum = 0
	for _, sub in ipairs(cState.subs) do
		sum = sum + (sub.alloc or 0)
	end
	return sum
end

local function calculateGlobalEstimate()
	local baseline = cState.localBaseline or 0
	local total = cState.totalAlloc or 0
	return (total - baseline) + calculateSum()
end

local function updateDemandRow(row, data)
	if not row or not IsValid(row.demand) then return end

	local demandValue = data.demand or 0
	local allocValue = data.alloc or 0
	row.demand:SetText(string.format("Demand: %d", demandValue))
	if demandValue > allocValue then
		row.demand:SetTextColor(COLOR_DEMAND_WARN)
	else
		row.demand:SetTextColor(COLOR_TEXT)
	end
end

local function refreshTotals()
	if not IsValid(totalLbl) then return end

	local globalSum = calculateGlobalEstimate()
	local over = globalSum > cState.maxBudget
	totalLbl:SetText(string.format("Budget: %d / %d%s", globalSum, cState.maxBudget, over and " (OVER)" or ""))
	totalLbl:SetTextColor(over and COLOR_TEXT_OVER or COLOR_TEXT)
end

local function populateRows()
	if not IsValid(scrollPanel) then return end

	if scrollPanel.Clear then
		scrollPanel:Clear()
	else
		local canvas = scrollPanel.GetCanvas and scrollPanel:GetCanvas()
		if IsValid(canvas) and canvas.Clear then
			canvas:Clear()
		end
	end
	sliders = {}

	for _, sub in ipairs(cState.subs) do
		local holder = scrollPanel:Add("DPanel")
		holder:Dock(TOP)
		holder:SetTall(78)
		holder:DockMargin(0, 0, 0, 8)
		function holder:Paint(w, h)
			surface.SetDrawColor(COLOR_PANEL.r, COLOR_PANEL.g, COLOR_PANEL.b, COLOR_PANEL.a)
			surface.DrawRect(0, 0, w, h)
		end

		local header = vgui.Create("DPanel", holder)
		header:Dock(TOP)
		header:SetTall(22)
		header:SetPaintBackground(false)

		local name = vgui.Create("DLabel", header)
		name:Dock(LEFT)
		name:SetWide(220)
		name:SetText(sub.label or sub.id)
		name:SetTextColor(COLOR_NAME)
		name:SetContentAlignment(4)

		local demand = vgui.Create("DLabel", header)
		demand:Dock(RIGHT)
		demand:SetWide(140)
		demand:SetContentAlignment(6)
		demand:SetTextColor(COLOR_TEXT)

		local slider = vgui.Create("DNumSlider", holder)
		slider:Dock(TOP)
		slider:DockMargin(10, 4, 10, 8)
		slider:SetTall(32)
		slider:SetDecimals(0)
		slider:SetText("")
		if slider.Label then
			slider.Label:SetText(sub.label or sub.id)
		end

		local id = sub.id
		local row = {
			slider = slider,
			demand = demand,
			updating = true,
		}

		sliders[id] = row

		local minVal = sub.min or 0
		local maxVal = sub.sliderMax or sub.max or cState.maxBudget or minVal
		if maxVal < minVal then maxVal = minVal end

		if slider.SetMinMax then
			slider:SetMinMax(minVal, maxVal)
		else
			if slider.SetMin then slider:SetMin(minVal) end
			if slider.SetMax then slider:SetMax(maxVal) end
		end

		slider:SetValue(sub.alloc or minVal)
		row.updating = false
		updateDemandRow(row, sub)

		function slider:OnValueChanged(value)
			if row.updating then return end
			local entry = findSubById(id)
			if not entry then return end
			entry.alloc = math.floor(value + 0.5)
			updateDemandRow(row, entry)
			refreshTotals()
		end
	end

	refreshTotals()
end

local function sendUpdate()
	if not EPS.NET or not EPS.NET.Update then return end

	local count = math.min(#cState.subs, 255)
	if count <= 0 then return end

	net.Start(EPS.NET.Update)
	net.WriteUInt(count, 8)

	for i = 1, count do
		local sub = cState.subs[i]
		net.WriteString(sub.id)
		net.WriteUInt(clampToUInt16(sub.alloc or 0), 16)
	end

	net.SendToServer()
end

local function buildUI()
	if IsValid(PANEL) then
		PANEL:Remove()
	end

	local w, h = 480, 440
	PANEL = vgui.Create("DFrame")
	PANEL:SetSize(w, h)
	PANEL:Center()
	PANEL:SetTitle("EPS Power Routing")
	PANEL:MakePopup()

	function PANEL:OnRemove()
		if PANEL == self then
			PANEL = nil
			totalLbl = nil
			scrollPanel = nil
			sliders = {}
		end
	end

	totalLbl = vgui.Create("DLabel", PANEL)
	totalLbl:SetPos(16, 34)
	totalLbl:SetSize(w - 32, 18)
	totalLbl:SetTextColor(COLOR_TEXT)
	totalLbl:SetText("Budget: 0 / 0")

	scrollPanel = vgui.Create("DScrollPanel", PANEL)
	scrollPanel:SetPos(12, 58)
	scrollPanel:SetSize(w - 24, h - 130)

	local apply = vgui.Create("DButton", PANEL)
	apply:SetPos(12, h - 56)
	apply:SetSize(120, 30)
	apply:SetText("Apply")
	apply.DoClick = function()
		local over = calculateGlobalEstimate() > cState.maxBudget
		if over then
			surface.PlaySound("buttons/button10.wav")
		else
			surface.PlaySound("buttons/button15.wav")
		end
		sendUpdate()
	end

	local revert = vgui.Create("DButton", PANEL)
	revert:SetPos(148, h - 56)
	revert:SetSize(120, 30)
	revert:SetText("Revert")
	revert.DoClick = function()
		for _, sub in ipairs(cState.subs) do
			if sub.serverAlloc ~= nil then
				sub.alloc = sub.serverAlloc
			end
		end
		populateRows()
	end

	local close = vgui.Create("DButton", PANEL)
	close:SetPos(w - 132, h - 56)
	close:SetSize(120, 30)
	close:SetText("Close")
	close.DoClick = function()
		if IsValid(PANEL) then
			PANEL:Close()
		end
	end

	populateRows()
end

local function requestOpen()
	if not EPS.NET or not EPS.NET.Open then return end
	net.Start(EPS.NET.Open)
	net.SendToServer()
end

net.Receive(EPS.NET.FullState, function()
	local shouldOpen = net.ReadBool()
	local maxBudget = net.ReadUInt(16)
	local totalAlloc = net.ReadUInt(16)
	local count = net.ReadUInt(8)

	cState.maxBudget = maxBudget
	cState.totalAlloc = totalAlloc
	cState.subs = {}
	cState.localBaseline = 0

	for i = 1, count do
		cState.subs[i] = {
			id = net.ReadString(),
			label = net.ReadString(),
			min = net.ReadUInt(16),
			max = net.ReadUInt(16),
			sliderMax = net.ReadUInt(16),
			alloc = net.ReadUInt(16),
			demand = net.ReadUInt(16),
		}
		cState.subs[i].serverAlloc = cState.subs[i].alloc
		cState.localBaseline = cState.localBaseline + (cState.subs[i].alloc or 0)
	end

	if shouldOpen then
		buildUI()
	elseif IsValid(PANEL) then
		populateRows()
	end

	refreshTotals()
end)

local commandName = EPS.Config and EPS.Config.Commands and EPS.Config.Commands.ConCommand or "eps_open"

concommand.Add(commandName, function()
	requestOpen()
end)

hook.Add("OnPlayerChat", "EPS_ClientChatOpen", function(ply, text)
	if ply ~= LocalPlayer() then return end
	local chatCmd = EPS.Config and EPS.Config.Commands and EPS.Config.Commands.Chat
	if not chatCmd or chatCmd == "" then return end
	if string.Trim(text or ""):lower() ~= chatCmd:lower() then return end
	timer.Simple(0, requestOpen)
end)
