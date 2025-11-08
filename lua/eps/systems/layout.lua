EPS = EPS or {}

include("eps/core/init.lua")

local Util = EPS.Util or {}

local Layout = {}

function Layout.SubsystemExists(id)
    return id ~= nil and EPS.GetSubsystem and EPS.GetSubsystem(id) ~= nil
end

function Layout.SanitizeLayout(layout, useDefaultFallback)
    local output = {}
    if istable(layout) then
        for _, id in ipairs(layout) do
            if Layout.SubsystemExists(id) then
                Util.UniqueInsert(output, id)
            end
        end
    end

    local dyn = EPS.Config.DynamicLayouts or {}
    local always = dyn.alwaysInclude
    if istable(always) then
        for _, id in ipairs(always) do
            if Layout.SubsystemExists(id) then
                Util.UniqueInsert(output, id)
            end
        end
    elseif Layout.SubsystemExists("life_support") then
        Util.UniqueInsert(output, "life_support")
    end

    if #output == 0 and useDefaultFallback then
        local default = dyn.default or { "replicators.general", "forcefields" }
        for _, id in ipairs(default) do
            if Layout.SubsystemExists(id) then
                Util.UniqueInsert(output, id)
            end
        end
        if istable(always) then
            for _, id in ipairs(always) do
                if Layout.SubsystemExists(id) then
                    Util.UniqueInsert(output, id)
                end
            end
        end
    end

    if #output == 0 and Layout.SubsystemExists("life_support") then
        Util.UniqueInsert(output, "life_support")
    end

    return output
end

function Layout.NormalizeSectionKey(key)
    if not isstring(key) then return nil end
    return string.Trim(string.lower(key))
end

function Layout.DetermineSectionForPos(pos)
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

function Layout.BuildLayoutFor(deck, sectionName)
    local dyn = EPS.Config.DynamicLayouts or {}
    local layout
    local usedDefault = false

    local matchedLayout
    if sectionName and dyn.sectionNames then
        local normalized = Layout.NormalizeSectionKey(sectionName)
        matchedLayout = dyn.sectionNames[sectionName]
        if not matchedLayout and normalized then
            matchedLayout = dyn.sectionNames[normalized]
        end
        if not matchedLayout and normalized then
            for key, value in pairs(dyn.sectionNames) do
                local keyNormalized = Layout.NormalizeSectionKey(key)
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
        layout = Util.CopyList(matchedLayout)
        chosenLayout = layout
        chosenSource = "section"
    elseif deck and dyn.deckOverrides and dyn.deckOverrides[deck] then
        layout = Util.CopyList(dyn.deckOverrides[deck])
        chosenLayout = layout
        chosenSource = "deck"
    else
        layout = Util.CopyList(dyn.default)
        usedDefault = true
        chosenLayout = layout
        chosenSource = "default"
    end

    if not layout or #layout == 0 then
        layout = Util.CopyList(dyn.default)
        usedDefault = true
    end

    local sanitized = Layout.SanitizeLayout(layout, usedDefault)
    return sanitized, { source = chosenSource, deck = deck, section = sectionName }
end

return Layout
