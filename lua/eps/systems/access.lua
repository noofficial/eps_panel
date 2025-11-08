EPS = EPS or {}

local Access = {}

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

function Access.IsAllowed(ply)
    if not IsValid(ply) then return true end
    if ply:IsAdmin() then return true end
    local groups = EPS.Config and EPS.Config.AllowedGroups
    if istable(groups) and #groups > 0 then
        return matchesAccessList(ply, groups)
    end
    return true
end

function Access.IsPrivileged(ply)
    if not IsValid(ply) then return true end
    local spikeCfg = EPS.Config and EPS.Config.Spikes or {}
    local groups = spikeCfg.PrivilegedGroups
    if istable(groups) and #groups > 0 then
        return matchesAccessList(ply, groups)
    end
    return ply:IsAdmin()
end

Access.MatchesAccessList = matchesAccessList

return Access
