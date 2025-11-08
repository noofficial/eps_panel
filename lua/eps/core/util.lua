EPS = EPS or {}
EPS.Util = EPS.Util or {}

local Util = EPS.Util

function Util.NormalizeLocKey(locKey)
    if not locKey or locKey == "" then return "global" end
    return string.lower(locKey)
end

function Util.BuildTimerName(prefix, locKey)
    local safe = Util.NormalizeLocKey(locKey or "global")
    safe = string.gsub(safe, "[^%w_]", "_")
    return string.format("%s_%s", prefix or "EPS_Timer", safe)
end

function Util.CopyMap(input)
    local output = {}
    if istable(input) then
        for key, value in pairs(input) do
            output[key] = value
        end
    end
    return output
end

function Util.CopyList(values)
    local result = {}
    if istable(values) then
        for _, value in ipairs(values) do
            result[#result + 1] = value
        end
    end
    return result
end

function Util.UniqueInsert(list, value)
    if not istable(list) or value == nil then return end
    for _, existing in ipairs(list) do
        if existing == value then return end
    end
    list[#list + 1] = value
end

function Util.ClampToUInt(value, bits)
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

return Util
