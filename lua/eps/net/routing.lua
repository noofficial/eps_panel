if CLIENT then return end

EPS = EPS or {}

include("eps/core/init.lua")

local Access = include("eps/systems/access.lua")

local RoutingNet = {}
local initialized = false

local function collectWatchersForLocation(locKey)
	if not locKey or locKey == "" then return end
	local watchers
	local layouts = EPS._playerLayouts
	if not layouts then return end
	for ply, cache in pairs(layouts) do
		if IsValid(ply) and ply:IsPlayer() and cache and cache.locKey == locKey then
			watchers = watchers or {}
			watchers[#watchers + 1] = ply
		end
	end
	return watchers
end

function RoutingNet.Setup(opts)
	if initialized then return end
	opts = opts or {}

	RoutingNet.sendFullState = opts.sendFullState
	RoutingNet.applyAllocations = opts.applyAllocations
	RoutingNet.isPlayerAllowed = opts.isPlayerAllowed or Access.IsAllowed

	if not (net and net.Receive and EPS.NET) then
		initialized = true
		return
	end

	if EPS.NET.Open then
		net.Receive(EPS.NET.Open, function(_, ply)
			if not IsValid(ply) or not ply:IsPlayer() then return end
			if RoutingNet.isPlayerAllowed and not RoutingNet.isPlayerAllowed(ply) then return end
			if RoutingNet.sendFullState then
				RoutingNet.sendFullState(ply, true)
			end
		end)
	end

	if EPS.NET.Update then
		net.Receive(EPS.NET.Update, function(_, ply)
			if not IsValid(ply) or not ply:IsPlayer() then return end
			if RoutingNet.isPlayerAllowed and not RoutingNet.isPlayerAllowed(ply) then return end
			if not RoutingNet.applyAllocations then return end

			local locKey = net.ReadString() or ""
			local count = net.ReadUInt(8) or 0
			if count > 64 then
				count = 64
			end

			local incoming = {}
			for _ = 1, count do
				local id = net.ReadString()
				local value = net.ReadUInt(16)
				if id and id ~= "" then
					incoming[id] = value
				end
			end

			local ok, result = RoutingNet.applyAllocations(ply, incoming, locKey)
			if not ok then
				if IsValid(ply) and ply.ChatPrint then
					local reason = result and tostring(result) or "Unable to process allocation update"
					ply:ChatPrint(string.format("[EPS] %s", reason))
				end
				return
			end

			local normalized = result
			local watchers = collectWatchersForLocation(normalized)
			if watchers and #watchers > 0 then
				if RoutingNet.sendFullState then
					RoutingNet.sendFullState(watchers, false)
				end
			else
				if RoutingNet.sendFullState then
					RoutingNet.sendFullState(ply, false)
				end
			end
		end)
	end

	initialized = true
end

return RoutingNet
