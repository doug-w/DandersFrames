local addonName, DF = ...

-- ============================================================
-- PINNED FRAMES - Separate frame sets for selected players
-- Uses SecureGroupHeaderTemplate with nameList for explicit control
-- ============================================================

local PinnedFrames = {}
DF.PinnedFrames = PinnedFrames

-- Storage for headers and containers
PinnedFrames.containers = {}  -- [setIndex] = container frame
PinnedFrames.headers = {}     -- [setIndex] = SecureGroupHeaderTemplate
PinnedFrames.labels = {}      -- [setIndex] = label fontstring
PinnedFrames.bossFrames = {}  -- [setIndex] = { [1..8] = boss frame }
PinnedFrames.bossHandlers = {}  -- [setIndex] = SecureHandlerBaseTemplate frame (runs compact reposition snippet)
PinnedFrames.preview = { containers = {}, mode = nil }  -- Preview containers for editing inactive mode
PinnedFrames.initialized = false
PinnedFrames.currentMode = nil  -- Track what mode we initialized for

-- Color palette per mode (raid = orange, party = purple-blue)
-- Matches C_RAID / C_ACCENT used across the GUI
local function GetModeColors(isRaid)
    if isRaid then
        return {
            containerBg     = { 0.30, 0.15, 0.05, 0.30 },
            containerBorder = { 0.80, 0.40, 0.15, 0.80 },
            moverBg         = { 0.40, 0.20, 0.05, 0.90 },
            moverBorder     = { 1.00, 0.50, 0.20, 1.00 },
            moverText       = { 1.00, 0.80, 0.50 },
        }
    end
    return {
        containerBg     = { 0.10, 0.10, 0.30, 0.30 },
        containerBorder = { 0.40, 0.40, 0.80, 0.80 },
        moverBg         = { 0.20, 0.20, 0.40, 0.90 },
        moverBorder     = { 0.50, 0.50, 0.90, 1.00 },
        moverText       = { 0.80, 0.80, 1.00 },
    }
end

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

-- Get pinned frames config for actual current mode
local function GetPinnedDB()
    local db = IsInRaid() and DF:GetRaidDB() or DF:GetDB()
    return db and db.pinnedFrames
end

-- Get the current actual mode (not cached)
local function GetActualMode()
    return IsInRaid() and "raid" or "party"
end

-- Get a specific set's config
local function GetSetDB(setIndex)
    local hlDB = GetPinnedDB()
    return hlDB and hlDB.sets and hlDB.sets[setIndex]
end

-- Returns true if the set is configured to show friendly boss NPCs instead of players
local function IsBossSet(set)
    return set and set.frameType == "friendlyBoss"
end

-- Build nameList from player array
-- Uses full names (including realm for cross-realm players) to match WoW's nameList format
local function BuildNameList(players)
    if not players or #players == 0 then
        return ""
    end
    
    -- Just join the names with commas - don't strip realms
    return table.concat(players, ",")
end

-- Get current group roster as a lookup table
-- Returns both the roster lookup AND the actual names from GetRaidRosterInfo
local function GetGroupRoster()
    local roster = {}          -- shortName -> rosterName (for lookup)
    local rosterNames = {}     -- list of actual roster names (for nameList)
    local numMembers = GetNumGroupMembers()
    
    if numMembers == 0 then
        local name = GetUnitName("player", true)  -- Returns "Name-Realm"
        roster[name] = name
        table.insert(rosterNames, name)
        return roster, rosterNames
    end
    
    local isRaid = IsInRaid()
    
    if isRaid then
        -- Use GetRaidRosterInfo which returns exact name format for nameList
        for i = 1, numMembers do
            local name = GetRaidRosterInfo(i)
            if name then
                -- Store both the full name and short name for lookup
                roster[name] = name
                local shortName = name:match("([^%-]+)") or name
                if shortName ~= name then
                    roster[shortName] = name  -- Map short name to full roster name
                end
                table.insert(rosterNames, name)
            end
        end
    else
        -- Party mode
        local playerName = GetUnitName("player", true)  -- Returns "Name-Realm"
        roster[playerName] = playerName
        table.insert(rosterNames, playerName)
        
        for i = 1, 4 do
            local unit = "party" .. i
            if UnitExists(unit) then
                local fullName = GetUnitName(unit, true)  -- Returns "Name-Realm", avoids secret value taint
                if fullName then
                    local name = fullName:match("([^%-]+)") or fullName
                    roster[fullName] = fullName
                    roster[name] = fullName  -- Map short name too
                    table.insert(rosterNames, fullName)
                end
            end
        end
    end
    
    return roster, rosterNames
end

-- Check if player is in current group, returns the roster name if found
local function IsPlayerInGroup(fullName, roster)
    roster = roster or GetGroupRoster()
    
    -- First check if full name (with realm) is in roster
    if roster[fullName] then
        return roster[fullName]  -- Return the actual roster name
    end
    
    -- For same-realm players, also check short name
    local shortName = fullName:match("([^%-]+)") or fullName
    if roster[shortName] then
        return roster[shortName]  -- Return the actual roster name
    end
    
    return nil
end

-- ============================================================
-- AUTO-POPULATION
-- ============================================================

-- Auto-populate a single pinned set based on its settings
function PinnedFrames:AutoPopulateSet(set, roster)
    if not set then return false end

    local changed = false
    roster = roster or GetGroupRoster()

    -- Ensure manualPlayers table exists (migration for existing profiles)
    if not set.manualPlayers then set.manualPlayers = {} end

    local hasAnyAutoFilter = set.autoAddTanks or set.autoAddHealers or set.autoAddDPS

    -- Build lookup of current players in set
    local existingPlayers = {}
    for _, p in ipairs(set.players) do
        local name = p:match("([^%-]+)") or p
        existingPlayers[name] = true
    end

    -- Get group roster with role info
    local numMembers = GetNumGroupMembers()
    if numMembers == 0 then
        -- Solo mode: player role is always DAMAGER (no group role assignment)
        local fullName = GetUnitName("player", true)
        local shortName = fullName and fullName:match("([^%-]+)") or fullName

        -- Auto-add player if DPS filter is on
        if set.autoAddDPS and shortName and not existingPlayers[shortName] then
            table.insert(set.players, fullName)
            changed = true
        end

        -- Auto-remove: remove non-manual players whose role (DAMAGER) doesn't match filters
        if hasAnyAutoFilter then
            for i = #set.players, 1, -1 do
                local playerName = set.players[i]
                if not set.manualPlayers[playerName] then
                    -- Solo player is always DAMAGER
                    local pShort = playerName:match("([^%-]+)") or playerName
                    if pShort == shortName then
                        if not set.autoAddDPS then
                            table.remove(set.players, i)
                            changed = true
                        end
                    else
                        -- Not the current player — they left the group
                        -- CleanOfflinePlayers handles this case
                    end
                end
            end
        end

        return changed
    end

    -- Build name → role map for the removal pass
    local rosterRoles = {}  -- shortName -> role
    local isRaid = IsInRaid()
    for i = 1, numMembers do
        local unit = isRaid and ("raid" .. i) or (i == 1 and "player" or "party" .. (i - 1))
        local fullName = GetUnitName(unit, true)

        if fullName then
            local shortName = fullName:match("([^%-]+)") or fullName
            local role = UnitGroupRolesAssigned(unit)
            if role == "NONE" then role = "DAMAGER" end
            rosterRoles[shortName] = role
            rosterRoles[fullName] = role

            -- Auto-add pass: add players matching enabled role filters
            if not existingPlayers[shortName] then
                local shouldAdd = false
                if set.autoAddTanks and role == "TANK" then
                    shouldAdd = true
                elseif set.autoAddHealers and role == "HEALER" then
                    shouldAdd = true
                elseif set.autoAddDPS and role == "DAMAGER" then
                    shouldAdd = true
                end

                if shouldAdd then
                    table.insert(set.players, fullName)
                    existingPlayers[shortName] = true
                    changed = true
                end
            end
        end
    end

    -- Auto-remove pass: remove players whose role no longer matches any filter
    -- Only runs when at least one auto-add filter is active
    if hasAnyAutoFilter then
        for i = #set.players, 1, -1 do
            local playerName = set.players[i]

            -- Never remove manually added players
            if set.manualPlayers[playerName] then
                -- skip
            else
                -- Only evaluate players still in the group
                -- (offline/left players are handled by CleanOfflinePlayers)
                local role = rosterRoles[playerName]
                if role then
                    local matchesFilter = false
                    if set.autoAddTanks and role == "TANK" then
                        matchesFilter = true
                    elseif set.autoAddHealers and role == "HEALER" then
                        matchesFilter = true
                    elseif set.autoAddDPS and role == "DAMAGER" then
                        matchesFilter = true
                    end

                    if not matchesFilter then
                        table.remove(set.players, i)
                        changed = true
                    end
                end
            end
        end
    end

    return changed
end

-- Clean up offline players from a set
function PinnedFrames:CleanOfflinePlayers(set, roster)
    if not set or set.keepOfflinePlayers then return false end
    
    roster = roster or GetGroupRoster()
    local changed = false
    
    for i = #set.players, 1, -1 do
        local fullName = set.players[i]
        if not IsPlayerInGroup(fullName, roster) then
            table.remove(set.players, i)
            changed = true
        end
    end
    
    return changed
end

-- Process all pinned sets for current mode
function PinnedFrames:ProcessAllSets()
    local hlDB = GetPinnedDB()
    if not hlDB or not hlDB.sets then return false end

    -- Skip processing if no sets are enabled (avoids unnecessary work in arena)
    local anyEnabled = false
    for i = 1, 2 do
        if hlDB.sets[i] and hlDB.sets[i].enabled then
            anyEnabled = true
            break
        end
    end
    if not anyEnabled then return false end

    local roster = GetGroupRoster()
    local changed = false
    
    for i = 1, 2 do
        local set = hlDB.sets[i]
        if set then
            if self:AutoPopulateSet(set, roster) then
                changed = true
            end
            if self:CleanOfflinePlayers(set, roster) then
                changed = true
            end
        end
    end
    
    if changed then
        self:UpdateAllHeaders()
    end

    return changed
end

-- Register/unregister boss frames in unitFrameMap based on visibility
function PinnedFrames:UpdateBossFrameMapEntries(setIndex)
    if not DF.unitFrameMap then return end
    local frames = self.bossFrames[setIndex]
    if not frames then return end

    for i = 1, 8 do
        local f = frames[i]
        if f then
            local unit = "boss" .. i
            if f:IsShown() then
                DF.unitFrameMap[unit] = f
                f.dfEventsEnabled = true
            else
                if DF.unitFrameMap[unit] == f then
                    DF.unitFrameMap[unit] = nil
                end
                f.dfEventsEnabled = false
            end
        end
    end
end

-- Called when boss units change (appear, die, change faction)
function PinnedFrames:OnBossFramesChanged()
    if not self.initialized then return end

    for setIndex = 1, 2 do
        local set = GetSetDB(setIndex)
        if set and set.enabled and IsBossSet(set) then
            -- unitFrameMap and frame refresh are safe during combat (purely visual/data)
            self:UpdateBossFrameMapEntries(setIndex)
            self:RefreshChildFrames(setIndex)

            -- Recompact positioning + container resize need out-of-combat
            -- (both call SetPoint/SetSize on secure frames)
            C_Timer.After(0.05, function()
                if not InCombatLockdown() then
                    self:ApplyBossLayout(setIndex)
                    self:ResizeContainer(setIndex)
                end
            end)
        end
    end
end

-- ============================================================
-- ANCHOR CALCULATION
-- ============================================================

-- Get the anchor point for the container based on growth settings
-- This determines which corner the header anchors to AND the container anchors to UIParent
-- Supports START, CENTER, and END for both frameAnchor and columnAnchor
local function GetContainerAnchorPoint(set)
    local horizontal = set.growDirection == "HORIZONTAL"
    local frameAnchor = set.frameAnchor or "START"
    local columnAnchor = set.columnAnchor or "START"

    -- Map each axis to its WoW anchor component
    local xPart, yPart
    if horizontal then
        -- Horizontal: frameAnchor = left/center/right, columnAnchor = top/center/bottom
        xPart = (frameAnchor == "END") and "RIGHT" or (frameAnchor == "CENTER") and "" or "LEFT"
        yPart = (columnAnchor == "END") and "BOTTOM" or (columnAnchor == "CENTER") and "" or "TOP"
    else
        -- Vertical: frameAnchor = top/center/bottom, columnAnchor = left/center/right
        yPart = (frameAnchor == "END") and "BOTTOM" or (frameAnchor == "CENTER") and "" or "TOP"
        xPart = (columnAnchor == "END") and "RIGHT" or (columnAnchor == "CENTER") and "" or "LEFT"
    end

    local anchor = yPart .. xPart
    if anchor == "" then anchor = "CENTER" end
    return anchor
end

-- Convert a container's saved position from one anchor to another
-- Returns new x, y offsets for the target anchor
local function ConvertAnchorPosition(container, oldAnchor, newAnchor)
    if oldAnchor == newAnchor then return end

    -- Get the container's current screen edges
    local left = container:GetLeft()
    local right = container:GetRight()
    local top = container:GetTop()
    local bottom = container:GetBottom()

    if not left or not right or not top or not bottom then return end

    -- Get UIParent edges (in same coordinate space)
    local uiLeft = UIParent:GetLeft() or 0
    local uiRight = UIParent:GetRight() or GetScreenWidth()
    local uiTop = UIParent:GetTop() or GetScreenHeight()
    local uiBottom = UIParent:GetBottom() or 0

    -- Calculate the position of each anchor point on the container
    local anchorX = { LEFT = left, RIGHT = right, CENTER = (left + right) / 2 }
    local anchorY = { TOP = top, BOTTOM = bottom, CENTER = (top + bottom) / 2 }

    -- Parse anchor into x/y components
    local function ParseAnchor(anchor)
        if anchor == "CENTER" then return "CENTER", "CENTER" end
        if anchor == "TOP" then return "CENTER", "TOP" end
        if anchor == "BOTTOM" then return "CENTER", "BOTTOM" end
        if anchor == "LEFT" then return "LEFT", "CENTER" end
        if anchor == "RIGHT" then return "RIGHT", "CENTER" end
        local yPart = anchor:match("^(TOP)") or anchor:match("^(BOTTOM)")
        local xPart = anchor:match("(LEFT)$") or anchor:match("(RIGHT)$")
        return xPart or "CENTER", yPart or "CENTER"
    end

    -- Get the screen position of the container's new anchor point
    local newXPart, newYPart = ParseAnchor(newAnchor)
    local containerX = anchorX[newXPart]
    local containerY = anchorY[newYPart]

    -- Get the screen position of UIParent's new anchor point
    local uiAnchorX = { LEFT = uiLeft, RIGHT = uiRight, CENTER = (uiLeft + uiRight) / 2 }
    local uiAnchorY = { TOP = uiTop, BOTTOM = uiBottom, CENTER = (uiTop + uiBottom) / 2 }
    local uiX = uiAnchorX[newXPart]
    local uiY = uiAnchorY[newYPart]

    -- The offset is the difference between container anchor point and UIParent anchor point
    return containerX - uiX, containerY - uiY
end

-- ============================================================
-- FRAME CREATION
-- ============================================================

-- Create a SecureHandlerStateTemplate handler for this set's boss frames.
-- The handler owns 8 state drivers (one per boss unit), each with an
-- `_onstate-bossN` secure snippet that shows/hides the corresponding boss
-- frame AND runs the compact reposition snippet. All positioning work
-- happens inside the restricted environment, which means `SetPoint` on
-- SecureUnitButtonTemplate frames is legal even during combat — unlike
-- Lua-side SetPoint calls.
--
-- We don't use SecureHandlerWrapScript on the boss frames themselves
-- because SecureUnitButtonTemplate doesn't derive from SecureHandler*Template
-- and therefore doesn't have a restricted-environment setup. The handler
-- (which IS a SecureHandlerStateTemplate) drives everything instead.
function PinnedFrames:CreateBossSecureHandler(setIndex, container, bossFrames)
    if self.bossHandlers[setIndex] then return self.bossHandlers[setIndex] end
    if InCombatLockdown() then return nil end

    -- Parent to UIParent so the handler lifetime is independent of the
    -- container. Handler itself is never rendered.
    local handler = CreateFrame("Frame",
        "DandersBossPositionHandler" .. setIndex,
        UIParent,
        "SecureHandlerStateTemplate")
    handler:Hide()

    -- Frame refs: container + each boss frame, addressable from snippets
    -- via self:GetFrameRef("container") / self:GetFrameRef("bossN")
    SecureHandlerSetFrameRef(handler, "container", container)
    for i = 1, 8 do
        local f = bossFrames[i]
        if f then
            SecureHandlerSetFrameRef(handler, "boss" .. i, f)
        end
    end

    -- Reposition snippet: compacts visible boss frames to the set anchor.
    handler:SetAttribute("repositionBossFrames", [[
        local container = self:GetFrameRef("container")
        if not container then return end

        local frameWidth = tonumber(self:GetAttribute("frameWidth")) or 120
        local frameHeight = tonumber(self:GetAttribute("frameHeight")) or 50
        local hSpacing = tonumber(self:GetAttribute("hSpacing")) or 2
        local vSpacing = tonumber(self:GetAttribute("vSpacing")) or 2
        local unitsPerRow = tonumber(self:GetAttribute("unitsPerRow")) or 5
        local horizontal = self:GetAttribute("horizontal") == "true"
        local anchor = self:GetAttribute("anchor") or "TOPLEFT"
        local frameAnchor = self:GetAttribute("frameAnchor") or "START"
        local columnAnchor = self:GetAttribute("columnAnchor") or "START"

        -- Walk boss1..boss8 in order; collect currently-visible frames
        local visibleFrames = newtable()
        local visibleCount = 0
        for i = 1, 8 do
            local f = self:GetFrameRef("boss" .. i)
            if f and f:IsShown() then
                visibleCount = visibleCount + 1
                visibleFrames[visibleCount] = f
            end
        end

        -- Position each visible frame by its compacted slot index
        for slot = 1, visibleCount do
            local f = visibleFrames[slot]
            local slotIndex = slot - 1
            local row = math.floor(slotIndex / unitsPerRow)
            local col = slotIndex - row * unitsPerRow

            local xStep = frameWidth + hSpacing
            local yStep = frameHeight + vSpacing
            local xOff, yOff
            if horizontal then
                if frameAnchor == "END" then xOff = -col * xStep else xOff = col * xStep end
                if columnAnchor == "END" then yOff = row * yStep else yOff = -row * yStep end
            else
                if frameAnchor == "END" then yOff = col * yStep else yOff = -col * yStep end
                if columnAnchor == "END" then xOff = -row * xStep else xOff = row * xStep end
            end

            f:ClearAllPoints()
            f:SetPoint(anchor, container, anchor, xOff, yOff)
        end

        -- Hidden frames parked at origin; keeps them from hanging out at
        -- stale positions if their visibility later flips.
        for i = 1, 8 do
            local f = self:GetFrameRef("boss" .. i)
            if f and not f:IsShown() then
                f:ClearAllPoints()
                f:SetPoint(anchor, container, anchor, 0, 0)
            end
        end
    ]])

    -- Per-boss state drivers on the handler. The _onstate snippet just
    -- runs the reposition snippet; Show/Hide is handled by each boss
    -- frame's own "visibility" state driver (see CreateBossFrames).
    for i = 1, 8 do
        local stateName = "boss" .. i
        handler:SetAttribute("_onstate-" .. stateName, [[
            self:RunAttribute("repositionBossFrames")
        ]])
        RegisterStateDriver(handler, stateName, "[@boss" .. i .. ",help]yes;no")
    end

    self.bossHandlers[setIndex] = handler

    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "created secure position handler")
    end

    return handler
end

-- Push current layout settings into the secure handler's attributes.
-- Must run out of combat (SetAttribute is restricted on secure frames in combat).
function PinnedFrames:UpdateBossHandlerConfig(setIndex)
    local handler = self.bossHandlers[setIndex]
    local set = GetSetDB(setIndex)
    if not handler or not set then return end
    if InCombatLockdown() then return end

    local db = IsInRaid() and DF:GetRaidDB() or DF:GetDB()
    if not db then return end

    handler:SetAttribute("frameWidth", db.frameWidth or 120)
    handler:SetAttribute("frameHeight", db.frameHeight or 50)
    handler:SetAttribute("hSpacing", set.horizontalSpacing or 2)
    handler:SetAttribute("vSpacing", set.verticalSpacing or 2)
    handler:SetAttribute("unitsPerRow", set.unitsPerRow or 5)
    handler:SetAttribute("horizontal", tostring(set.growDirection == "HORIZONTAL"))
    handler:SetAttribute("anchor", GetContainerAnchorPoint(set))
    handler:SetAttribute("frameAnchor", set.frameAnchor or "START")
    handler:SetAttribute("columnAnchor", set.columnAnchor or "START")
end

-- Run the reposition snippet once from Lua (out of combat).
-- In combat, the state driver triggers it automatically when visibility changes.
function PinnedFrames:TriggerBossReposition(setIndex)
    local handler = self.bossHandlers[setIndex]
    if not handler then return end
    if InCombatLockdown() then return end
    handler:Execute([[ self:RunAttribute("repositionBossFrames") ]])
end

-- Create 8 standalone SecureUnitButtonTemplate frames for a boss-mode set
-- Parented to the container; unit attributes are hardcoded to boss1..boss8
function PinnedFrames:CreateBossFrames(setIndex, container)
    if self.bossFrames[setIndex] then return end
    if InCombatLockdown() then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r CreateBossFrames: In combat, cannot create frames!")
        end
        return
    end

    local modeSuffix = IsInRaid() and "Raid" or "Party"
    local frames = {}

    for i = 1, 8 do
        local name = "DandersPinnedBoss" .. setIndex .. modeSuffix .. "_" .. i
        local frame = CreateFrame(
            "Button",
            name,
            container,
            "DandersUnitButtonTemplate,SecureUnitButtonTemplate"
        )
        frame:SetAttribute("unit", "boss" .. i)
        frame.unit = "boss" .. i
        frame.isPinnedFrame = true
        frame.isPinnedBossFrame = true
        frame.bossIndex = i

        if DF.InitializeHeaderChild then
            DF:InitializeHeaderChild(frame)
        end

        -- Per-frame visibility state driver: shows the frame when bossN
        -- exists AND is friendly. The SecureHandlerStateTemplate handler
        -- (created after this loop) runs a parallel state driver that fires
        -- the compact reposition snippet whenever visibility flips.
        RegisterStateDriver(frame, "visibility", "[@boss" .. i .. ",help]show;hide")

        -- Self-sufficient event system (ElvUI/oUF-style).
        -- Register all unit-specific events directly on the frame with
        -- `RegisterUnitEvent` so they're filtered at the C level — the handler
        -- only fires when the event is for this frame's boss unit. No dispatcher
        -- lookup needed. Each event routes to the appropriate DF update
        -- function on `self`. This avoids "dispatcher forgot boss frames"
        -- bugs because each frame listens for what it needs directly.
        local bossUnit = "boss" .. i
        frame:RegisterUnitEvent("UNIT_HEALTH", bossUnit)
        frame:RegisterUnitEvent("UNIT_MAXHEALTH", bossUnit)
        frame:RegisterUnitEvent("UNIT_MAX_HEALTH_MODIFIERS_CHANGED", bossUnit)
        frame:RegisterUnitEvent("UNIT_POWER_UPDATE", bossUnit)
        frame:RegisterUnitEvent("UNIT_MAXPOWER", bossUnit)
        frame:RegisterUnitEvent("UNIT_DISPLAYPOWER", bossUnit)
        frame:RegisterUnitEvent("UNIT_AURA", bossUnit)
        frame:RegisterUnitEvent("UNIT_NAME_UPDATE", bossUnit)
        frame:RegisterUnitEvent("UNIT_FACTION", bossUnit)
        frame:RegisterUnitEvent("UNIT_ABSORB_AMOUNT_CHANGED", bossUnit)
        frame:RegisterUnitEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED", bossUnit)
        frame:RegisterUnitEvent("UNIT_HEAL_PREDICTION", bossUnit)

        frame:SetScript("OnEvent", function(self, event, unit, updateInfo)
            -- Skip work if hidden (state driver keeps us hidden when bossN
            -- doesn't exist / isn't friendly, so events shouldn't really
            -- fire then, but cheap to guard).
            if not self:IsShown() then return end

            if event == "UNIT_HEALTH"
                    or event == "UNIT_MAXHEALTH"
                    or event == "UNIT_MAX_HEALTH_MODIFIERS_CHANGED" then
                if DF.UpdateHealthFast then DF:UpdateHealthFast(self) end

            elseif event == "UNIT_POWER_UPDATE"
                    or event == "UNIT_MAXPOWER"
                    or event == "UNIT_DISPLAYPOWER" then
                if DF.UpdatePower then DF:UpdatePower(self) end

            elseif event == "UNIT_AURA" then
                -- Populate aura cache (same logic as directModeSubscriber)
                local cache = DF.AuraCache and DF.AuraCache[unit]
                local needsFull = not updateInfo or updateInfo.isFullUpdate
                    or not cache or not cache.hasFullScan
                if needsFull then
                    if DF.ScanUnitFull then DF:ScanUnitFull(unit) end
                else
                    if DF.ApplyAuraDelta and not DF:ApplyAuraDelta(unit, updateInfo) then
                        if DF.ScanUnitFull then DF:ScanUnitFull(unit) end
                    end
                end
                -- Trigger the full filtered aura update pipeline (same path as
                -- party/raid frames — applies filters, limits, dedup, etc.)
                if DF.TriggerAuraUpdateForUnit then
                    DF:TriggerAuraUpdateForUnit(unit)
                end

            elseif event == "UNIT_NAME_UPDATE" then
                if DF.UpdateName then DF:UpdateName(self) end

            elseif event == "UNIT_FACTION" then
                -- Faction change can flip friendly→hostile — full refresh
                -- (state driver will then hide the frame if no longer friendly)
                if DF.FullFrameRefresh then DF:FullFrameRefresh(self) end

            elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
                if DF.UpdateAbsorb then DF:UpdateAbsorb(self) end

            elseif event == "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" then
                if DF.UpdateHealAbsorb then DF:UpdateHealAbsorb(self) end

            elseif event == "UNIT_HEAL_PREDICTION" then
                if DF.UpdateHealPrediction then DF:UpdateHealPrediction(self) end
            end
        end)

        -- OnShow hook: when state driver makes this frame visible, register in
        -- unitFrameMap synchronously so UNIT_HEALTH/UNIT_AURA/etc. events route
        -- here immediately (otherwise the health bar won't update until
        -- OnBossFramesChanged's deferred registration fires).
        frame:HookScript("OnShow", function(self)
            if DF.unitFrameMap and self.unit then
                DF.unitFrameMap[self.unit] = self
                self.dfEventsEnabled = true
            end
            C_Timer.After(0.1, function()
                if self and self.unit and self:IsVisible() then
                    -- Populate aura cache for this unit if not yet done
                    if DF.ScanUnitFull then DF:ScanUnitFull(self.unit) end
                    -- Full refresh ensures Aura Designer BeginFrame/EnsureFrameState runs
                    if DF.FullFrameRefresh then DF:FullFrameRefresh(self) end
                end
            end)
        end)

        -- OnHide hook: clear Aura Designer state so the next OnShow reinitializes
        -- from scratch. Without this, when a boss slot is reassigned to a new NPC,
        -- the stale dfAD_* pools cause AD indicators to not apply on first render.
        -- Also remove from unitFrameMap so events don't route to a hidden frame.
        frame:HookScript("OnHide", function(self)
            if DF.unitFrameMap and self.unit and DF.unitFrameMap[self.unit] == self then
                DF.unitFrameMap[self.unit] = nil
            end
            self.dfEventsEnabled = false
            self.dfAD = nil
            self.dfAD_icons = nil
            self.dfAD_squares = nil
            self.dfAD_bars = nil
            self.dfAD_configVersion = nil
            self.dfAD_activeInstanceIDs = nil
        end)

        -- Register with click-casting system
        if ClickCastFrames then
            ClickCastFrames[frame] = true
        end

        frame:Hide()
        frames[i] = frame
    end

    self.bossFrames[setIndex] = frames

    -- Secure handler that repositions these frames compactly, even in combat
    self:CreateBossSecureHandler(setIndex, container, frames)

    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "created 8 boss frames")
    end
end

function PinnedFrames:CreateSetFrames(setIndex)
    if self.containers[setIndex] then return end
    
    -- CRITICAL: Cannot create frames during combat
    if InCombatLockdown() then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r CreateSetFrames: In combat, cannot create frames!")
        end
        return
    end
    
    local set = GetSetDB(setIndex)
    if not set then return end
    
    local modeSuffix = IsInRaid() and "Raid" or "Party"
    
    -- Create container (movable anchor frame)
    local container = CreateFrame("Frame", "DandersPinned" .. setIndex .. modeSuffix .. "Container", UIParent)
    container:SetSize(200, 100)  -- Will be resized based on content
    container:SetFrameStrata("MEDIUM")
    container:SetClampedToScreen(true)
    
    -- Position from saved settings — use growth-direction anchor
    local containerAnchor = GetContainerAnchorPoint(set)
    local pos = set.position or { point = containerAnchor, x = 0, y = 200 * (setIndex == 1 and 1 or -1) }
    -- If saved anchor doesn't match current growth anchor, convert on first layout pass
    local useAnchor = pos.point or containerAnchor
    local initScale = set.scale or 1.0
    container:SetScale(initScale)
    container:ClearAllPoints()
    container:SetPoint(useAnchor, UIParent, useAnchor, (pos.x or 0) / initScale, (pos.y or 0) / initScale)
    
    -- Make draggable when unlocked
    container:SetMovable(true)
    container:EnableMouse(false)  -- Don't capture mouse on container - mover handles dragging

    -- Mode-aware colors: raid = orange, party = purple-blue
    local colors = GetModeColors(IsInRaid())

    -- Visual background when unlocked (for visibility)
    container.bg = container:CreateTexture(nil, "BACKGROUND")
    container.bg:SetAllPoints()
    container.bg:SetColorTexture(unpack(colors.containerBg))
    container.bg:SetShown(not set.locked)

    -- Border when unlocked
    container.border = CreateFrame("Frame", nil, container, "BackdropTemplate")
    container.border:SetAllPoints()
    container.border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    container.border:SetBackdropBorderColor(unpack(colors.containerBorder))
    container.border:SetShown(not set.locked)

    -- Mover frame (parented to UIParent for scale independence)
    local mover = CreateFrame("Frame", "DandersPinned" .. setIndex .. "Mover", UIParent)
    mover:SetSize(80, 16)
    mover:SetFrameStrata("HIGH")
    mover:SetPoint("BOTTOM", container, "TOP", 0, 2)

    -- Mover background
    mover.bg = mover:CreateTexture(nil, "BACKGROUND")
    mover.bg:SetAllPoints()
    mover.bg:SetColorTexture(unpack(colors.moverBg))

    -- Mover border (1px)
    mover.border = mover:CreateTexture(nil, "BORDER")
    mover.border:SetAllPoints()
    mover.border:SetColorTexture(unpack(colors.moverBorder))
    local moverInner = mover:CreateTexture(nil, "ARTWORK")
    moverInner:SetPoint("TOPLEFT", 1, -1)
    moverInner:SetPoint("BOTTOMRIGHT", -1, 1)
    moverInner:SetColorTexture(unpack(colors.moverBg))

    -- Mover text
    mover.text = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mover.text:SetPoint("CENTER")
    mover.text:SetText("Drag to Move")
    mover.text:SetTextColor(unpack(colors.moverText))
    
    -- Mover is the drag handle
    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")
    
    -- Track starting mouse and container position
    local startMouseX, startMouseY, startPosX, startPosY
    
    mover:SetScript("OnDragStart", function(self)
        if set.locked then return end

        -- Get the current anchor for this set
        local anchor = GetContainerAnchorPoint(set)

        -- Get starting mouse position in screen coordinates
        local uiScale = UIParent:GetEffectiveScale()
        startMouseX, startMouseY = GetCursorPosition()
        startMouseX = startMouseX / uiScale
        startMouseY = startMouseY / uiScale

        -- Get current container position
        local pos = set.position or { x = 0, y = 0 }
        startPosX = pos.x or 0
        startPosY = pos.y or 0

        self:SetScript("OnUpdate", function()
            local mx, my = GetCursorPosition()
            local ps = UIParent:GetEffectiveScale()
            mx = mx / ps
            my = my / ps

            -- Delta in UIParent space — add directly to logical start position
            local deltaX = mx - startMouseX
            local deltaY = my - startMouseY
            local newX = startPosX + deltaX
            local newY = startPosY + deltaY

            -- Divide by scale for SetPoint — WoW multiplies offsets by frame scale internally
            local s = container:GetScale() or 1
            container:ClearAllPoints()
            container:SetPoint(anchor, UIParent, anchor, newX / s, newY / s)
        end)
    end)

    mover:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if not startMouseX then return end

        -- Get the current anchor for this set
        local anchor = GetContainerAnchorPoint(set)

        -- Get final position from mouse delta
        local uiScale = UIParent:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        mx = mx / uiScale
        my = my / uiScale

        local deltaX = mx - startMouseX
        local deltaY = my - startMouseY
        local finalX = startPosX + deltaX
        local finalY = startPosY + deltaY

        -- Save logical position (unscaled)
        set.position = { point = anchor, x = finalX, y = finalY }

        -- Divide by scale for SetPoint
        local s = container:GetScale() or 1
        container:ClearAllPoints()
        container:SetPoint(anchor, UIParent, anchor, finalX / s, finalY / s)
    end)
    
    -- Mover shows when unlocked AND enabled
    mover:SetShown(set.enabled and not set.locked)
    container.mover = mover
    
    -- Label (parented to UIParent for scale independence)
    local label = UIParent:CreateFontString("DandersPinned" .. setIndex .. "Label", "OVERLAY", "GameFontNormal")
    label:SetPoint("BOTTOM", container, "TOP", 0, 2)
    local labelText = set.name
    if not labelText or labelText == "" then
        labelText = "Pinned " .. setIndex
    end
    label:SetText(labelText)
    label:SetTextColor(0.8, 0.8, 1.0)
    -- Only show label if set is enabled AND showLabel is true
    label:SetShown(set.enabled and set.showLabel)
    
    self.containers[setIndex] = container
    self.labels[setIndex] = label

    if IsBossSet(set) then
        -- BOSS MODE: create 8 standalone boss frames instead of a header
        self:CreateBossFrames(setIndex, container)
        self:ApplyBossLayout(setIndex)

        -- Honor enabled state
        if set.enabled then
            container:Show()
            if label then label:SetShown(set.showLabel) end
            if container.mover then container.mover:SetShown(not set.locked) end
        else
            container:Hide()
            if label then label:Hide() end
            if container.mover then container.mover:Hide() end
        end
        return
    end

    -- Create SecureGroupHeaderTemplate
    local header = CreateFrame("Frame", "DandersPinned" .. setIndex .. modeSuffix .. "Header", container, "SecureGroupHeaderTemplate")
    
    -- Show all unit types - nameList controls which are visible
    header:SetAttribute("showPlayer", true)
    header:SetAttribute("showParty", true)
    header:SetAttribute("showRaid", true)
    header:SetAttribute("showSolo", true)
    
    -- Use same template as main frames
    header:SetAttribute("template", "DandersUnitButtonTemplate")
    
    -- Initial layout
    self:ApplyLayoutSettings(setIndex)
    
    -- Anchor header to container
    header:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    
    self.headers[setIndex] = header
    
    -- STARTINGINDEX TRICK - Force create frames upfront
    -- Must happen BEFORE setting nameList/sortMethod
    -- Use groupFilter temporarily to force frame creation
    header:SetAttribute("groupFilter", "1,2,3,4,5,6,7,8")  -- All groups
    header:SetAttribute("startingIndex", -39)  -- Creates up to 40 frames
    header:Show()
    header:SetAttribute("startingIndex", 1)    -- Reset to normal operation
    
    -- Now switch to nameList mode
    header:SetAttribute("sortMethod", "NAMELIST")
    header:SetAttribute("groupFilter", nil)  -- Clear groupFilter, nameList takes over
    
    -- Initial nameList (may be empty, that's ok now - frames are created)
    self:UpdateHeaderNameList(setIndex)
    
    if DF.debugPinnedFrames then
        -- Debug: count created children
        local count = 0
        for i = 1, 40 do
            if header:GetAttribute("child" .. i) then count = count + 1 end
        end
        print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "created", count, "child frames")
    end
    
    -- Show/hide based on enabled state
    if set.enabled then
        container:Show()
        header:Show()
        -- Label and mover visibility based on their settings
        if label then
            label:SetShown(set.showLabel)
        end
        if container.mover then
            container.mover:SetShown(not set.locked)
        end
    else
        container:Hide()
        header:Hide()
        -- Hide label and mover when disabled
        if label then
            label:Hide()
        end
        if container.mover then
            container.mover:Hide()
        end
        -- Unregister events from child frames (synchronous - no delays for combat safety)
        if DF.SetHeaderChildrenEventsEnabled then
            DF:SetHeaderChildrenEventsEnabled(header, false)
        end
    end
end

-- ============================================================
-- HEADER UPDATES
-- ============================================================

-- Update the nameList for a header
function PinnedFrames:UpdateHeaderNameList(setIndex)
    local header = self.headers[setIndex]
    local set = GetSetDB(setIndex)
    
    if not header or not set then return end
    
    -- Get roster (maps stored names to actual GetRaidRosterInfo names)
    local roster = GetGroupRoster()
    local validRosterNames = {}
    
    -- For each player in set, find their actual roster name
    for _, storedName in ipairs(set.players) do
        local rosterName = IsPlayerInGroup(storedName, roster)
        if rosterName then
            -- Use the actual roster name (what GetRaidRosterInfo returns)
            table.insert(validRosterNames, rosterName)
        end
    end
    
    local nameList = BuildNameList(validRosterNames)
    
    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "updating nameList")
        print("|cFF00FFFF[DF Pinned]|r   Players in set:", #set.players)
        print("|cFF00FFFF[DF Pinned]|r   Valid (in group):", #validRosterNames)
        print("|cFF00FFFF[DF Pinned]|r   nameList:", nameList ~= "" and nameList or "(empty)")
        for i, p in ipairs(set.players) do
            local rosterName = IsPlayerInGroup(p, roster)
            print("|cFF00FFFF[DF Pinned]|r     [" .. i .. "]", p, rosterName and ("-> " .. rosterName) or "(NOT in group)")
        end
    end
    
    -- Only update if not in combat
    if InCombatLockdown() then
        self.pendingNameListUpdate = self.pendingNameListUpdate or {}
        self.pendingNameListUpdate[setIndex] = true
        return
    end
    
    -- Clear ALL filtering/grouping attributes - nameList acts as the filter
    -- (Same approach as flat raid mode in Headers.lua)
    header:SetAttribute("groupBy", nil)
    header:SetAttribute("groupingOrder", nil)
    header:SetAttribute("groupFilter", nil)  -- MUST clear this for nameList to work!
    header:SetAttribute("roleFilter", nil)
    header:SetAttribute("strictFiltering", nil)
    
    -- Set nameList and sortMethod
    header:SetAttribute("nameList", nameList)
    header:SetAttribute("sortMethod", "NAMELIST")
    
    -- Force header to re-layout by toggling visibility
    if set.enabled then
        header:Hide()
        header:Show()
    end
    
    -- Resize container after layout change
    self:ResizeContainer(setIndex)
    
    -- Force visual refresh on all visible children after nameList change
    -- OnAttributeChanged handles unit reassignment, but a small delay ensures
    -- the header has finished re-laying out children before we refresh visuals
    C_Timer.After(0.1, function()
        if header and set.enabled then
            PinnedFrames:RefreshChildFrames(setIndex)
        end
    end)
end

-- Apply layout settings to a header
function PinnedFrames:ApplyLayoutSettings(setIndex)
    local set = GetSetDB(setIndex)
    if not set then return end
    if InCombatLockdown() then return end

    if IsBossSet(set) then
        self:ApplyBossLayout(setIndex)
        self:ResizeContainer(setIndex)
        return
    end

    local header = self.headers[setIndex]
    if not header then return end
    
    local db = IsInRaid() and DF:GetRaidDB() or DF:GetDB()
    if not db then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r ApplyLayoutSettings: db is nil!")
        end
        return
    end
    
    local frameWidth = db.frameWidth or 120
    local frameHeight = db.frameHeight or 50
    
    -- CRITICAL: Resize all child frames to match current raid/party settings
    -- This ensures frames use the correct size when switching between raid and party
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child then
            child:SetSize(frameWidth, frameHeight)
            -- Also update the isRaidFrame flag for proper DB selection in other functions
            child.isRaidFrame = IsInRaid()
        end
    end
    
    local horizontal = set.growDirection == "HORIZONTAL"
    local hSpacing = set.horizontalSpacing or 2
    local vSpacing = set.verticalSpacing or 2
    local unitsPerRow = set.unitsPerRow or 5
    local columnAnchor = set.columnAnchor or "START"
    local frameAnchor = set.frameAnchor or "START"
    
    -- Frame anchor point determines where first frame is placed and growth direction
    -- HORIZONTAL: START=LEFT (grow right), CENTER=LEFT (grow right, expand from center), END=RIGHT (grow left)
    -- VERTICAL: START=TOP (grow down), CENTER=TOP (grow down, expand from center), END=BOTTOM (grow up)
    -- CENTER uses same internal layout as START — the "center" effect comes from the container anchor
    local point, xOff, yOff
    if horizontal then
        if frameAnchor == "END" then
            point = "RIGHT"
            xOff = -hSpacing  -- Negative to grow left
        else
            point = "LEFT"
            xOff = hSpacing   -- Positive to grow right
        end
        yOff = 0
    else
        if frameAnchor == "END" then
            point = "BOTTOM"
            yOff = vSpacing   -- Positive to grow up
        else
            point = "TOP"
            yOff = -vSpacing  -- Negative to grow down
        end
        xOff = 0
    end

    header:SetAttribute("point", point)
    header:SetAttribute("xOffset", xOff)
    header:SetAttribute("yOffset", yOff)

    -- Column anchor point determines where new columns/rows appear
    -- CENTER uses same internal layout as START — container anchor handles the centering
    local colAnchorPoint, colSpacing
    if horizontal then
        colSpacing = vSpacing
        colAnchorPoint = (columnAnchor == "END") and "BOTTOM" or "TOP"
    else
        colSpacing = hSpacing
        colAnchorPoint = (columnAnchor == "END") and "RIGHT" or "LEFT"
    end
    header:SetAttribute("columnSpacing", colSpacing)
    header:SetAttribute("columnAnchorPoint", colAnchorPoint)
    
    header:SetAttribute("maxColumns", math.ceil(40 / unitsPerRow))
    header:SetAttribute("unitsPerColumn", unitsPerRow)
    
    -- Store frame dimensions for the template
    header:SetAttribute("frameWidth", frameWidth)
    header:SetAttribute("frameHeight", frameHeight)
    
    -- Get the anchor point based on growth settings
    local containerAnchorPoint = GetContainerAnchorPoint(set)
    
    -- Apply scale FIRST (before any position work)
    local container = self.containers[setIndex]
    if container then
        container:SetScale(set.scale or 1.0)
    end
    
    -- Anchor the header to the correct corner of container
    if container then
        header:ClearAllPoints()
        header:SetPoint(containerAnchorPoint, container, containerAnchorPoint, 0, 0)

        -- Restore saved position — convert if anchor changed
        local pos = set.position
        if pos then
            local savedAnchor = pos.point or "CENTER"
            if savedAnchor ~= containerAnchorPoint and container:GetLeft() then
                -- Anchor changed (user changed growth direction) — convert coordinates
                -- ConvertAnchorPosition returns screen-space offsets (affected by scale),
                -- so multiply by scale to convert back to logical space for storage
                local newX, newY = ConvertAnchorPosition(container, savedAnchor, containerAnchorPoint)
                if newX and newY then
                    local cs = container:GetScale() or 1
                    pos.point = containerAnchorPoint
                    pos.x = newX * cs
                    pos.y = newY * cs
                end
            end
            container:ClearAllPoints()
            local s = container:GetScale() or 1
            container:SetPoint(containerAnchorPoint, UIParent, containerAnchorPoint, (pos.x or 0) / s, (pos.y or 0) / s)
            pos.point = containerAnchorPoint
        end
    end
    
    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r ApplyLayoutSettings set", setIndex)
        print("|cFF00FFFF[DF Pinned]|r   horizontal:", horizontal)
        print("|cFF00FFFF[DF Pinned]|r   frameAnchor:", frameAnchor, "columnAnchor:", columnAnchor)
        print("|cFF00FFFF[DF Pinned]|r   containerAnchor:", containerAnchorPoint)
        print("|cFF00FFFF[DF Pinned]|r   frameSize:", frameWidth, "x", frameHeight)
        print("|cFF00FFFF[DF Pinned]|r   spacing:", hSpacing, vSpacing)
    end
    
    -- ============================================================
    -- CRITICAL: 4-step refresh to force repositioning
    -- Without this, changing layout settings won't reposition frames
    -- ============================================================
    if set.enabled and header:IsShown() then
        local currentNameList = header:GetAttribute("nameList")
        
        -- Step 1: Clear nameList to remove unit assignments
        header:SetAttribute("nameList", "")
        
        -- Step 2: Clear all child positions
        for i = 1, 40 do
            local child = header:GetAttribute("child" .. i)
            if child then
                child:ClearAllPoints()
            end
        end
        
        -- Step 3: Force header to process by hiding and showing
        header:Hide()
        header:Show()
        
        -- Step 4: Restore nameList - this reassigns units with new layout
        if currentNameList and currentNameList ~= "" then
            header:SetAttribute("nameList", currentNameList)
        end
    end
    
    -- Resize container after layout change
    self:ResizeContainer(setIndex)
end

-- Manually position boss frames in a grid matching the set's layout settings
-- Called when layout settings change or boss visibility changes
function PinnedFrames:ApplyBossLayout(setIndex)
    local frames = self.bossFrames[setIndex]
    local set = GetSetDB(setIndex)
    local container = self.containers[setIndex]

    if not frames or not set or not container then return end
    if InCombatLockdown() then return end

    local db = IsInRaid() and DF:GetRaidDB() or DF:GetDB()
    if not db then return end

    local frameWidth = db.frameWidth or 120
    local frameHeight = db.frameHeight or 50

    -- Resize all frames to current mode's dimensions
    -- (SetSize on secure frames IS combat-restricted, but we already bailed above)
    for i = 1, 8 do
        local f = frames[i]
        if f then
            f:SetSize(frameWidth, frameHeight)
            f.isRaidFrame = IsInRaid()
        end
    end

    -- Determine corner to anchor from (matches GetContainerAnchorPoint logic)
    local anchor = GetContainerAnchorPoint(set)

    -- Apply scale
    container:SetScale(set.scale or 1.0)

    -- Restore/apply saved position
    local pos = set.position
    if pos then
        local savedAnchor = pos.point or anchor
        if savedAnchor ~= anchor and container:GetLeft() then
            local newX, newY = ConvertAnchorPosition(container, savedAnchor, anchor)
            if newX and newY then
                local cs = container:GetScale() or 1
                pos.point = anchor
                pos.x = newX * cs
                pos.y = newY * cs
            end
        end
        container:ClearAllPoints()
        local s = container:GetScale() or 1
        container:SetPoint(anchor, UIParent, anchor, (pos.x or 0) / s, (pos.y or 0) / s)
        pos.point = anchor
    end

    -- Push current layout config into the secure handler's attributes, then
    -- trigger one reposition. The handler will re-run the reposition snippet
    -- automatically whenever any boss frame's visibility changes (even in
    -- combat), so this single call is the only time we need to invoke it
    -- from Lua.
    self:UpdateBossHandlerConfig(setIndex)
    self:TriggerBossReposition(setIndex)
end

-- Resize container to fit content
function PinnedFrames:ResizeContainer(setIndex)
    -- Can't resize secure frames during combat
    if InCombatLockdown() then return end
    
    local container = self.containers[setIndex]
    local header = self.headers[setIndex]
    local set = GetSetDB(setIndex)
    
    if not container or not set then return end
    if not IsBossSet(set) and not header then return end

    local db = IsInRaid() and DF:GetRaidDB() or DF:GetDB()
    local frameWidth = db.frameWidth or 120
    local frameHeight = db.frameHeight or 50

    if IsBossSet(set) then
        local frames = self.bossFrames[setIndex]
        if not frames then return end

        local visibleCount = 0
        for i = 1, 8 do
            if frames[i] and frames[i]:IsShown() then
                visibleCount = visibleCount + 1
            end
        end

        if visibleCount == 0 then
            container:SetSize(frameWidth, frameHeight)
            return
        end

        local horizontal = set.growDirection == "HORIZONTAL"
        local spacing = horizontal and (set.horizontalSpacing or 2) or (set.verticalSpacing or 2)
        local unitsPerRow = set.unitsPerRow or 5

        local rows = math.ceil(visibleCount / unitsPerRow)
        local cols = math.min(visibleCount, unitsPerRow)

        local width, height
        if horizontal then
            width = cols * frameWidth + (cols - 1) * spacing
            height = rows * frameHeight + (rows - 1) * (set.verticalSpacing or 2)
        else
            width = rows * frameWidth + (rows - 1) * (set.horizontalSpacing or 2)
            height = cols * frameHeight + (cols - 1) * spacing
        end

        container:SetSize(math.max(width, 50), math.max(height, 30))
        return
    end

    -- Count visible children
    local visibleCount = 0
    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child and child:IsShown() then
            visibleCount = visibleCount + 1
        end
    end
    
    if visibleCount == 0 then
        container:SetSize(frameWidth, frameHeight)
        return
    end
    
    local horizontal = set.growDirection == "HORIZONTAL"
    local spacing = horizontal and (set.horizontalSpacing or 2) or (set.verticalSpacing or 2)
    local unitsPerRow = set.unitsPerRow or 5
    
    local rows = math.ceil(visibleCount / unitsPerRow)
    local cols = math.min(visibleCount, unitsPerRow)
    
    local width, height
    if horizontal then
        width = cols * frameWidth + (cols - 1) * spacing
        height = rows * frameHeight + (rows - 1) * (set.verticalSpacing or 2)
    else
        width = rows * frameWidth + (rows - 1) * (set.horizontalSpacing or 2)
        height = cols * frameHeight + (cols - 1) * spacing
    end
    
    container:SetSize(math.max(width, 50), math.max(height, 30))
end

-- Update all headers
function PinnedFrames:UpdateAllHeaders()
    for i = 1, 2 do
        self:UpdateHeaderNameList(i)
    end
end

-- ============================================================
-- ENABLE/DISABLE/LOCK
-- ============================================================

-- Iterate through header children and manage their events
local function SetChildFrameEvents(header, enabled)
    if DF.SetHeaderChildrenEventsEnabled then
        DF:SetHeaderChildrenEventsEnabled(header, enabled)
    end
end

-- Toggle enabled state for a set
-- Refresh all child frames for a set (called after enabling for combat reload support)
-- Uses FullFrameRefresh which uses Blizzard aura cache ONLY - no fallback
function PinnedFrames:RefreshChildFrames(setIndex)
    local set = GetSetDB(setIndex)
    if not set then return end

    if IsBossSet(set) then
        local frames = self.bossFrames[setIndex]
        if not frames then return end
        for i = 1, 8 do
            local f = frames[i]
            if f and f.unit and f:IsVisible() then
                if DF.FullFrameRefresh then
                    DF:FullFrameRefresh(f)
                end
            end
        end
        return
    end

    local header = self.headers[setIndex]
    if not header then return end

    for i = 1, 40 do
        local child = header:GetAttribute("child" .. i)
        if child and child.unit and child:IsVisible() then
            if DF.FullFrameRefresh then
                DF:FullFrameRefresh(child)
            end
        end
    end

    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "refreshed all child frames")
    end
end

function PinnedFrames:SetEnabled(setIndex, enabled)
    local set = GetSetDB(setIndex)
    if not set then return end

    set.enabled = enabled

    local container = self.containers[setIndex]
    local header = self.headers[setIndex]
    local isBoss = IsBossSet(set)

    if not container or (not isBoss and not header) then
        if enabled then
            self:CreateSetFrames(setIndex)
        end
        return
    end

    if InCombatLockdown() then
        self.pendingVisibilityUpdate = self.pendingVisibilityUpdate or {}
        self.pendingVisibilityUpdate[setIndex] = enabled
        return
    end

    -- Player mode: toggle header child events
    if not isBoss and header then
        SetChildFrameEvents(header, enabled)
    end

    local label = self.labels[setIndex]

    if enabled then
        container:Show()
        if header then header:Show() end

        if isBoss then
            self:ApplyBossLayout(setIndex)
            self:ResizeContainer(setIndex)
        else
            self:UpdateHeaderNameList(setIndex)
            self:ApplyLayoutSettings(setIndex)
        end

        self:UpdateLabel(setIndex)
        if label then label:SetShown(set.showLabel) end
        if container.mover and not set.locked then
            container.mover:SetShown(true)
        end

        self:RefreshChildFrames(setIndex)
    else
        container:Hide()
        if header then header:Hide() end
        if label then label:Hide() end
        if container.mover then container.mover:Hide() end
    end
end

-- Toggle locked state for a set
function PinnedFrames:SetLocked(setIndex, locked)
    local set = GetSetDB(setIndex)
    local container = self.containers[setIndex]
    
    if not set or not container then return end
    
    -- Unlocking requires frame manipulation that can taint in combat
    if not locked and InCombatLockdown() then
        self.pendingUnlock = self.pendingUnlock or {}
        self.pendingUnlock[setIndex] = true
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Set", setIndex, "unlock queued until after combat")
        end
        return
    end
    
    set.locked = locked
    
    -- Container background/border visibility
    container.bg:SetShown(not locked)
    container.border:SetShown(not locked)
    
    -- Mover shows when unlocked (independent of label)
    if container.mover then
        container.mover:SetShown(not locked and set.enabled)
    end
end

-- Auto-lock all unlocked sets (called on combat start)
function PinnedFrames:LockAllForCombat()
    if not self.initialized then return end
    
    local hlDB = GetPinnedDB()
    if not hlDB or not hlDB.sets then return end
    
    for i = 1, 2 do
        local set = hlDB.sets[i]
        local container = self.containers[i]
        if set and container and not set.locked then
            -- Remember which sets were unlocked so we can restore after combat
            self.unlockedBeforeCombat = self.unlockedBeforeCombat or {}
            self.unlockedBeforeCombat[i] = true
            
            -- Lock visually (hide mover/bg/border) but don't save to DB
            container.bg:Hide()
            container.border:Hide()
            if container.mover then
                container.mover:Hide()
            end
            
            if DF.debugPinnedFrames then
                print("|cFF00FFFF[DF Pinned]|r Set", i, "auto-locked for combat")
            end
        end
    end
end

-- Restore unlock state after combat
function PinnedFrames:RestoreUnlockedAfterCombat()
    -- Restore sets that were unlocked before combat
    if self.unlockedBeforeCombat then
        for setIndex in pairs(self.unlockedBeforeCombat) do
            local set = GetSetDB(setIndex)
            local container = self.containers[setIndex]
            if set and container and not set.locked then
                container.bg:SetShown(true)
                container.border:SetShown(true)
                if container.mover then
                    container.mover:SetShown(set.enabled)
                end
            end
        end
        self.unlockedBeforeCombat = nil
    end
    
    -- Process any unlock requests that came in during combat
    if self.pendingUnlock then
        for setIndex in pairs(self.pendingUnlock) do
            self:SetLocked(setIndex, false)
        end
        self.pendingUnlock = nil
    end
end

-- Toggle label visibility
function PinnedFrames:SetShowLabel(setIndex, show)
    local set = GetSetDB(setIndex)
    local label = self.labels[setIndex]
    
    if not set or not label then return end
    
    set.showLabel = show
    label:SetShown(show)
end

-- Update label text
function PinnedFrames:UpdateLabel(setIndex)
    local set = GetSetDB(setIndex)
    local label = self.labels[setIndex]
    
    if not set or not label then return end
    
    local labelText = set.name
    if not labelText or labelText == "" then
        labelText = "Pinned " .. setIndex
    end
    label:SetText(labelText)
end

-- ============================================================
-- PREVIEW CONTAINERS (for editing inactive mode's position)
-- Created when the options panel is open to a mode that differs
-- from the actual game mode, so users can reposition pinned frames
-- for that mode without joining a raid/party. Previews are purely
-- visual — no SecureGroupHeader, no child frames — just a sized
-- placeholder box plus a drag handle.
-- ============================================================

-- Compute preview container size from the preview mode's DB
local function CalcPreviewSize(modeDb, set)
    local frameWidth = modeDb.frameWidth or 120
    local frameHeight = modeDb.frameHeight or 50

    local count
    if IsBossSet(set) then
        -- Bosses are only known mid-encounter; ResizeContainer falls back to a
        -- single-frame placeholder when no boss is visible, so mirror that.
        count = 1
    else
        count = (set.players and #set.players) or 0
    end
    if count < 1 then count = 1 end

    local horizontal = set.growDirection == "HORIZONTAL"
    local hSpacing = set.horizontalSpacing or 2
    local vSpacing = set.verticalSpacing or 2
    local unitsPerRow = set.unitsPerRow or 5

    local rows = math.ceil(count / unitsPerRow)
    local cols = math.min(count, unitsPerRow)

    local width, height
    if horizontal then
        width = cols * frameWidth + (cols - 1) * hSpacing
        height = rows * frameHeight + (rows - 1) * vSpacing
    else
        width = rows * frameWidth + (rows - 1) * hSpacing
        height = cols * frameHeight + (cols - 1) * vSpacing
    end

    return math.max(width, 50), math.max(height, 30)
end

-- Build label string for a preview, e.g. "Pinned 1  (Raid preview)"
local function BuildPreviewLabel(set, setIndex, isRaid)
    local labelText = set.name
    if not labelText or labelText == "" then
        labelText = "Pinned " .. setIndex
    end
    return labelText .. "  |cffaaaaaa(" .. (isRaid and "Raid" or "Party") .. " preview)|r"
end

-- Create a preview container for setIndex showing `mode`'s settings
function PinnedFrames:CreatePreviewSet(setIndex, mode)
    local modeDb = DF.db and DF.db[mode]
    if not modeDb or not modeDb.pinnedFrames then return end
    local set = modeDb.pinnedFrames.sets and modeDb.pinnedFrames.sets[setIndex]
    if not set then return end

    local isRaid = (mode == "raid")
    local colors = GetModeColors(isRaid)

    local container = CreateFrame("Frame", nil, UIParent)
    container:SetFrameStrata("MEDIUM")
    container:SetClampedToScreen(true)

    local initScale = set.scale or 1.0
    container:SetScale(initScale)

    local w, h = CalcPreviewSize(modeDb, set)
    container:SetSize(w, h)

    local anchor = GetContainerAnchorPoint(set)
    local pos = set.position or { point = anchor, x = 0, y = 200 * (setIndex == 1 and 1 or -1) }
    local useAnchor = pos.point or anchor
    container:ClearAllPoints()
    container:SetPoint(useAnchor, UIParent, useAnchor, (pos.x or 0) / initScale, (pos.y or 0) / initScale)

    -- Background fill
    container.bg = container:CreateTexture(nil, "BACKGROUND")
    container.bg:SetAllPoints()
    container.bg:SetColorTexture(unpack(colors.containerBg))

    -- Border
    container.border = CreateFrame("Frame", nil, container, "BackdropTemplate")
    container.border:SetAllPoints()
    container.border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    container.border:SetBackdropBorderColor(unpack(colors.containerBorder))

    -- Mover frame (parented to UIParent for scale independence)
    local mover = CreateFrame("Frame", nil, UIParent)
    mover:SetSize(140, 16)
    mover:SetFrameStrata("HIGH")
    mover:SetPoint("BOTTOM", container, "TOP", 0, 2)

    mover.bg = mover:CreateTexture(nil, "BACKGROUND")
    mover.bg:SetAllPoints()
    mover.bg:SetColorTexture(unpack(colors.moverBg))

    mover.border = mover:CreateTexture(nil, "BORDER")
    mover.border:SetAllPoints()
    mover.border:SetColorTexture(unpack(colors.moverBorder))

    local moverInner = mover:CreateTexture(nil, "ARTWORK")
    moverInner:SetPoint("TOPLEFT", 1, -1)
    moverInner:SetPoint("BOTTOMRIGHT", -1, 1)
    moverInner:SetColorTexture(unpack(colors.moverBg))

    mover.text = mover:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mover.text:SetPoint("CENTER")
    mover.text:SetText((isRaid and "Raid" or "Party") .. " Preview — Drag")
    mover.text:SetTextColor(unpack(colors.moverText))

    mover:EnableMouse(true)
    mover:RegisterForDrag("LeftButton")

    local startMouseX, startMouseY, startPosX, startPosY

    mover:SetScript("OnDragStart", function(self)
        local dragAnchor = GetContainerAnchorPoint(set)
        local uiScale = UIParent:GetEffectiveScale()
        startMouseX, startMouseY = GetCursorPosition()
        startMouseX = startMouseX / uiScale
        startMouseY = startMouseY / uiScale
        local p = set.position or { x = 0, y = 0 }
        startPosX = p.x or 0
        startPosY = p.y or 0
        self:SetScript("OnUpdate", function()
            local mx, my = GetCursorPosition()
            local ps = UIParent:GetEffectiveScale()
            mx = mx / ps
            my = my / ps
            local newX = startPosX + (mx - startMouseX)
            local newY = startPosY + (my - startMouseY)
            local s = container:GetScale() or 1
            container:ClearAllPoints()
            container:SetPoint(dragAnchor, UIParent, dragAnchor, newX / s, newY / s)
        end)
    end)

    mover:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if not startMouseX then return end
        local dragAnchor = GetContainerAnchorPoint(set)
        local uiScale = UIParent:GetEffectiveScale()
        local mx, my = GetCursorPosition()
        mx = mx / uiScale
        my = my / uiScale
        local finalX = startPosX + (mx - startMouseX)
        local finalY = startPosY + (my - startMouseY)
        set.position = { point = dragAnchor, x = finalX, y = finalY }
        local s = container:GetScale() or 1
        container:ClearAllPoints()
        container:SetPoint(dragAnchor, UIParent, dragAnchor, finalX / s, finalY / s)
    end)

    -- Label above the mover
    local label = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("BOTTOM", mover, "TOP", 0, 2)
    label:SetText(BuildPreviewLabel(set, setIndex, isRaid))
    label:SetTextColor(unpack(colors.moverText))

    container.mover = mover
    container.label = label
    container.previewMode = mode
    container.previewSet = set

    -- Match the real container's visibility rules so the preview reflects the
    -- edited set's enabled/locked/showLabel state.
    local enabled = set.enabled ~= false
    container:SetShown(enabled)
    mover:SetShown(enabled and not set.locked)
    label:SetShown(enabled and set.showLabel)

    self.preview.containers[setIndex] = container
end

-- Refresh a preview set's size/position/label after settings change
function PinnedFrames:UpdatePreviewSet(setIndex)
    if not self.preview or not self.preview.mode then return end
    local c = self.preview.containers and self.preview.containers[setIndex]
    if not c then return end

    local mode = self.preview.mode
    local modeDb = DF.db and DF.db[mode]
    if not modeDb or not modeDb.pinnedFrames then return end
    local set = modeDb.pinnedFrames.sets and modeDb.pinnedFrames.sets[setIndex]
    if not set then return end

    -- Scale
    c:SetScale(set.scale or 1.0)

    -- Size
    local w, h = CalcPreviewSize(modeDb, set)
    c:SetSize(w, h)

    -- Reposition (convert if anchor changed)
    local anchor = GetContainerAnchorPoint(set)
    local pos = set.position
    if pos then
        local savedAnchor = pos.point or anchor
        if savedAnchor ~= anchor and c:GetLeft() then
            local newX, newY = ConvertAnchorPosition(c, savedAnchor, anchor)
            if newX and newY then
                local cs = c:GetScale() or 1
                pos.point = anchor
                pos.x = newX * cs
                pos.y = newY * cs
            end
        end
        c:ClearAllPoints()
        local s = c:GetScale() or 1
        c:SetPoint(anchor, UIParent, anchor, (pos.x or 0) / s, (pos.y or 0) / s)
        pos.point = anchor
    end

    -- Refresh label text and visibility
    local enabled = set.enabled ~= false
    c:SetShown(enabled)
    if c.mover then
        c.mover:SetShown(enabled and not set.locked)
    end
    if c.label then
        c.label:SetText(BuildPreviewLabel(set, setIndex, mode == "raid"))
        c.label:SetShown(enabled and set.showLabel)
    end
end

-- Show previews for the given mode (or hide if mode matches actual)
function PinnedFrames:ShowPreview(mode)
    if not mode or mode == GetActualMode() then
        self:HidePreview()
        return
    end

    -- Already showing for this mode -- just refresh layouts
    if self.preview and self.preview.mode == mode and self.preview.containers then
        for i = 1, 2 do self:UpdatePreviewSet(i) end
        return
    end

    -- Rebuild
    self:HidePreview()
    self.preview = self.preview or { containers = {} }
    self.preview.containers = {}
    self.preview.mode = mode
    for i = 1, 2 do
        self:CreatePreviewSet(i, mode)
    end
end

function PinnedFrames:HidePreview()
    if self.preview and self.preview.containers then
        for i = 1, 2 do
            local c = self.preview.containers[i]
            if c then
                if c.mover then c.mover:Hide() end
                if c.label then c.label:Hide() end
                c:Hide()
            end
            self.preview.containers[i] = nil
        end
    end
    if self.preview then
        self.preview.mode = nil
    end
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

function PinnedFrames:Initialize()
    if self.initialized then return end
    
    -- CRITICAL: Cannot create frames during combat
    if InCombatLockdown() then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Initialize: In combat, deferring...")
        end
        self.pendingInitialize = true
        return
    end
    
    -- Check if DB is ready - if not during ADDON_LOADED, defer to pending
    if not DF.db then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Initialize: DF.db not ready, setting pendingInitialize")
        end
        self.pendingInitialize = true
        return
    end
    
    -- Track what mode we're initializing for
    self.currentMode = GetActualMode()
    
    -- Check if pinnedFrames config exists
    local hlDB = GetPinnedDB()
    if not hlDB then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Initialize: No pinnedFrames config found!")
        end
        return
    end
    
    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Initializing pinned frames...")
        print("|cFF00FFFF[DF Pinned]|r   Mode:", self.currentMode)
    end
    
    -- Create frames for both sets
    for i = 1, 2 do
        self:CreateSetFrames(i)
    end
    
    self.initialized = true
    
    -- Apply layout settings immediately (no delays for combat safety)
    -- Note: ApplyLayoutSettings is also called in CreateSetFrames, but we do it
    -- again here to ensure all settings are applied after headers are fully set up
    for i = 1, 2 do
        local header = self.headers[i]
        local set = GetSetDB(i)
        if set and set.enabled and (header or IsBossSet(set)) then
            self:ApplyLayoutSettings(i)
        end
    end
    
    if DF.debugPinnedFrames then
        print("|cFF00FFFF[DF Pinned]|r Initialized pinned frames")
    end
end

-- Reinitialize for mode change (party <-> raid)
function PinnedFrames:Reinitialize()
    -- Cannot reinitialize during combat
    if InCombatLockdown() then
        if DF.debugPinnedFrames then
            print("|cFF00FFFF[DF Pinned]|r Reinitialize: In combat, deferring...")
        end
        self.pendingReinitialize = true
        return
    end
    
    -- Clean up old frames
    for i = 1, 2 do
        if self.bossHandlers[i] then
            -- Unregister the handler's per-boss state drivers
            for j = 1, 8 do
                UnregisterStateDriver(self.bossHandlers[i], "boss" .. j)
            end
            self.bossHandlers[i]:Hide()
            self.bossHandlers[i] = nil
        end
        if self.bossFrames[i] then
            for j = 1, 8 do
                local f = self.bossFrames[i][j]
                if f then
                    UnregisterStateDriver(f, "visibility")
                    f:UnregisterAllEvents()
                    f:Hide()
                end
            end
            self.bossFrames[i] = nil
        end
        if self.containers[i] then
            if self.containers[i].mover then
                self.containers[i].mover:Hide()
            end
            self.containers[i]:Hide()
            self.containers[i] = nil
        end
        if self.headers[i] then
            self.headers[i]:Hide()
            self.headers[i] = nil
        end
        if self.labels[i] then
            self.labels[i]:Hide()
        end
        self.labels[i] = nil
    end
    
    self.initialized = false
    self:Initialize()

    -- Re-evaluate preview visibility after a mode change:
    -- if the previewed mode is now the actual mode, previews become redundant
    -- and ShowPreview() will hide them automatically.
    if self.preview and self.preview.mode then
        self:ShowPreview(self.preview.mode)
    end
end

-- Refresh all child frames (calls FullFrameRefresh on each)
function PinnedFrames:RefreshAllChildFrames()
    for setIndex = 1, 2 do
        local set = GetSetDB(setIndex)
        if set then
            if IsBossSet(set) then
                local frames = self.bossFrames[setIndex]
                if frames then
                    for i = 1, 8 do
                        local f = frames[i]
                        if f and f:IsShown() and f.unit then
                            if DF.FullFrameRefresh then
                                DF:FullFrameRefresh(f)
                            end
                        end
                    end
                end
            else
                local header = self.headers[setIndex]
                if header then
                    for i = 1, 40 do
                        local child = header:GetAttribute("child" .. i)
                        if child and child:IsShown() and child.unit then
                            if DF.FullFrameRefresh then
                                DF:FullFrameRefresh(child)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================
-- EVENT HANDLING
-- All initialization must happen synchronously during ADDON_LOADED
-- No C_Timer.After delays - they can fire during combat lockdown
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("ROLE_CHANGED_INFORM")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")
eventFrame:RegisterEvent("UNIT_TARGETABLE_CHANGED")
eventFrame:RegisterEvent("UNIT_FACTION")

eventFrame:SetScript("OnEvent", function(self, event, arg1, ...)
    if event == "ADDON_LOADED" then
        if arg1 == "DandersFrames" then
            -- Initialize immediately during ADDON_LOADED
            -- During /reload, this fires BEFORE combat lockdown is re-established
            -- so we can safely create frames here without deferring
            if DF.db then
                PinnedFrames:Initialize()
                
                -- Populate the nameList - always update headers on load
                if PinnedFrames.initialized then
                    PinnedFrames:ProcessAllSets()
                    PinnedFrames:UpdateAllHeaders()  -- Force update even if no changes
                    
                    -- Force visual refresh on all child frames immediately
                    PinnedFrames:RefreshAllChildFrames()
                end
            end
        end
        return
    end
    
    if not DF.db then return end
    
    if event == "PLAYER_REGEN_DISABLED" then
        -- Auto-lock all unlocked pinned sets on combat start
        if PinnedFrames.initialized then
            PinnedFrames:LockAllForCombat()
        end
        return
    end
    
    if event == "PLAYER_REGEN_ENABLED" then
        -- Restore unlock state for sets that were unlocked before combat
        if PinnedFrames.initialized then
            PinnedFrames:RestoreUnlockedAfterCombat()
        end
        
        -- Process pending reinitialization after combat
        if PinnedFrames.pendingReinitialize then
            PinnedFrames.pendingReinitialize = nil
            PinnedFrames:Reinitialize()
            PinnedFrames:ProcessAllSets()
            return  -- Reinitialize handles everything
        end
        
        -- Process pending initialization after combat
        if PinnedFrames.pendingInitialize then
            PinnedFrames.pendingInitialize = nil
            PinnedFrames:Initialize()
            PinnedFrames:ProcessAllSets()
        end
        
        -- Process pending updates after combat
        if PinnedFrames.pendingNameListUpdate then
            for setIndex, _ in pairs(PinnedFrames.pendingNameListUpdate) do
                PinnedFrames:UpdateHeaderNameList(setIndex)
            end
            PinnedFrames.pendingNameListUpdate = nil
        end
        
        if PinnedFrames.pendingVisibilityUpdate then
            for setIndex, enabled in pairs(PinnedFrames.pendingVisibilityUpdate) do
                PinnedFrames:SetEnabled(setIndex, enabled)
            end
            PinnedFrames.pendingVisibilityUpdate = nil
        end

        -- Recompact boss frames — positioning can only happen out of combat
        if PinnedFrames.initialized then
            for setIndex = 1, 2 do
                local set = GetSetDB(setIndex)
                if set and set.enabled and IsBossSet(set) then
                    PinnedFrames:ApplyBossLayout(setIndex)
                    PinnedFrames:ResizeContainer(setIndex)
                end
            end
        end
        return
    end
    
    if event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
        if PinnedFrames.initialized then
            PinnedFrames:OnBossFramesChanged()
        end
        return
    end

    if event == "UNIT_TARGETABLE_CHANGED" then
        if type(arg1) == "string" and arg1:match("^boss%d$") then
            if PinnedFrames.initialized then
                PinnedFrames:OnBossFramesChanged()
            end
        end
        return
    end

    if event == "UNIT_FACTION" then
        if type(arg1) == "string" and arg1:match("^boss%d$") then
            if PinnedFrames.initialized then
                PinnedFrames:OnBossFramesChanged()
            end
        end
        return
    end

    -- GROUP_ROSTER_UPDATE or ROLE_CHANGED_INFORM
    if PinnedFrames.initialized then
        -- Check if mode changed (party <-> raid)
        local actualMode = GetActualMode()
        if PinnedFrames.currentMode and actualMode ~= PinnedFrames.currentMode then
            if DF.debugPinnedFrames then
                print("|cFF00FFFF[DF Pinned]|r Mode changed from", PinnedFrames.currentMode, "to", actualMode, "- reinitializing")
            end
            PinnedFrames:Reinitialize()
            return
        end
        
        PinnedFrames:ProcessAllSets()
    end
end)

-- ============================================================
-- DEBUG
-- ============================================================

function PinnedFrames:DebugPrint()
    print("|cFF00FFFF[DF Pinned]|r === Debug Info ===")
    print("  Initialized:", tostring(self.initialized))
    print("  Current mode:", self.currentMode or "unknown")
    print("  Actual mode:", GetActualMode())
    print("  DF.db exists:", tostring(DF.db ~= nil))
    
    local hlDB = GetPinnedDB()
    print("  pinnedFrames DB exists:", tostring(hlDB ~= nil))
    
    -- Show current group roster
    local roster = GetGroupRoster()
    local rosterCount = 0
    for _ in pairs(roster) do rosterCount = rosterCount + 1 end
    print("  Group roster count:", rosterCount)
    for name, _ in pairs(roster) do
        print("    -", name)
    end
    
    for i = 1, 2 do
        local set = GetSetDB(i)
        print(" ")
        print("  === Set " .. i .. " ===")
        if set then
            print("    Enabled:", tostring(set.enabled))
            print("    Locked:", tostring(set.locked))
            print("    ShowLabel:", tostring(set.showLabel))
            print("    Name:", set.name or "(nil)")
            print("    Players in set:", #set.players)
            for j, p in ipairs(set.players) do
                local inGroup = IsPlayerInGroup(p, roster)
                print("      [" .. j .. "]", p, inGroup and "(IN GROUP)" or "(not in group)")
            end
            
            local container = self.containers[i]
            local header = self.headers[i]
            local label = self.labels[i]
            
            print("    Container exists:", tostring(container ~= nil))
            if container then
                print("      Shown:", tostring(container:IsShown()))
                print("      Size:", container:GetWidth(), "x", container:GetHeight())
            end
            
            print("    Header exists:", tostring(header ~= nil))
            if header then
                print("      Shown:", tostring(header:IsShown()))
                local nameListAttr = header:GetAttribute("nameList") or "(nil)"
                print("      nameList attr:", nameListAttr)
                print("      sortMethod:", header:GetAttribute("sortMethod") or "(nil)")
                print("      template:", header:GetAttribute("template") or "(nil)")
                
                -- Count children
                local childCount = 0
                local shownChildren = 0
                for j = 1, 40 do
                    local child = header:GetAttribute("child" .. j)
                    if child then
                        childCount = childCount + 1
                        if child:IsShown() then
                            shownChildren = shownChildren + 1
                        end
                    end
                end
                print("      Children (total):", childCount)
                print("      Children (shown):", shownChildren)
                
                -- List first few children
                for j = 1, math.min(5, childCount) do
                    local child = header:GetAttribute("child" .. j)
                    if child then
                        local unit = child:GetAttribute("unit") or "none"
                        print("        child" .. j .. ":", child:GetName() or "unnamed", "unit=" .. unit, child:IsShown() and "SHOWN" or "hidden")
                    end
                end
            end
            
            print("    Label exists:", tostring(label ~= nil))
            if label then
                print("      Shown:", tostring(label:IsShown()))
                print("      Text:", label:GetText() or "(nil)")
            end
        else
            print("    (set config is nil)")
        end
    end
end

-- Test function - adds player to set 1 and enables it
function PinnedFrames:Test()
    local set = GetSetDB(1)
    if not set then
        print("|cFF00FFFF[DF Pinned]|r Test: No set 1 config found!")
        return
    end
    
    local fullName = GetUnitName("player", true)  -- Returns "Name-Realm"
    
    -- Add player if not already in list
    local found = false
    for _, p in ipairs(set.players) do
        if p == fullName then
            found = true
            break
        end
    end
    
    if not found then
        table.insert(set.players, fullName)
        print("|cFF00FFFF[DF Pinned]|r Test: Added", fullName, "to set 1")
    else
        print("|cFF00FFFF[DF Pinned]|r Test:", fullName, "already in set 1")
    end
    
    -- Enable set 1
    set.enabled = true
    self:SetEnabled(1, true)
    
    -- Update nameList
    self:UpdateHeaderNameList(1)
    
    print("|cFF00FFFF[DF Pinned]|r Test: Set 1 enabled with player")
    print("|cFF00FFFF[DF Pinned]|r Run /dfpinned info to see details")
end

-- Test mode for boss frames: force N boss frames visible so the secure
-- positioning can be verified without being in an encounter. Runs out of
-- combat only (needs to unregister/re-register state drivers). Passing
-- nil/0/"off" exits test mode and restores the normal `[@bossN,help]` drivers.
function PinnedFrames:SetBossTestMode(visibleCount)
    if InCombatLockdown() then
        print("|cFF00FFFF[DF Pinned]|r Boss test mode cannot toggle during combat")
        return
    end

    visibleCount = tonumber(visibleCount) or 0
    if visibleCount < 0 then visibleCount = 0 end
    if visibleCount > 8 then visibleCount = 8 end

    self.bossTestMode = visibleCount > 0
    self.bossTestCount = visibleCount

    local anyToggled = false
    for setIndex = 1, 2 do
        local set = GetSetDB(setIndex)
        if set and set.enabled and IsBossSet(set) then
            local handler = self.bossHandlers[setIndex]
            local frames = self.bossFrames[setIndex]
            if handler and frames then
                if visibleCount > 0 then
                    -- Test mode: swap BOTH the frame visibility state driver
                    -- AND the handler's reposition-trigger state driver to
                    -- use always-true/always-false conditions so we can
                    -- control visibility without a real boss.
                    for i = 1, 8 do
                        local f = frames[i]
                        if i <= visibleCount then
                            RegisterStateDriver(f, "visibility", "[@player,exists]show;hide")
                            RegisterStateDriver(handler, "boss" .. i, "[@player,exists]yes;no")
                        else
                            RegisterStateDriver(f, "visibility", "[@nonexistent]show;hide")
                            RegisterStateDriver(handler, "boss" .. i, "[@nonexistent]yes;no")
                        end
                    end
                else
                    -- Test mode off: restore real conditions on both drivers
                    for i = 1, 8 do
                        local f = frames[i]
                        if f then
                            RegisterStateDriver(f, "visibility", "[@boss" .. i .. ",help]show;hide")
                        end
                        RegisterStateDriver(handler, "boss" .. i, "[@boss" .. i .. ",help]yes;no")
                    end
                end
                anyToggled = true
            end
        end
    end

    if not anyToggled then
        print("|cFF00FFFF[DF Pinned]|r No enabled boss-mode sets found. Enable a pinned set and set Frame Type to 'Friendly Boss NPCs' first.")
    elseif visibleCount > 0 then
        print(format("|cFF00FFFF[DF Pinned]|r Boss test mode ON: showing %d boss frames. Run '/dfpinned bosstest off' to exit.", visibleCount))
    else
        print("|cFF00FFFF[DF Pinned]|r Boss test mode OFF: restored real state drivers")
    end
end

-- Slash command for debug
SLASH_DFPINNED1 = "/dfpinned"
SlashCmdList["DFPINNED"] = function(msg)
    if msg == "debug" then
        DF.debugPinnedFrames = not DF.debugPinnedFrames
        print("|cFF00FFFF[DF Pinned]|r Debug:", DF.debugPinnedFrames and "ON" or "OFF")
    elseif msg == "info" then
        PinnedFrames:DebugPrint()
    elseif msg == "reinit" then
        PinnedFrames:Reinitialize()
        print("|cFF00FFFF[DF Pinned]|r Reinitialized")
    elseif msg == "test" then
        PinnedFrames:Test()
    elseif msg and msg:match("^bosstest") then
        -- "/dfpinned bosstest 3" or "/dfpinned bosstest off"
        local arg = msg:match("^bosstest%s+(%S+)")
        if arg == "off" or arg == "0" or arg == nil then
            PinnedFrames:SetBossTestMode(0)
        else
            PinnedFrames:SetBossTestMode(tonumber(arg) or 0)
        end
    else
        print("|cFF00FFFF[DF Pinned]|r Commands:")
        print("  debug - Toggle debug output")
        print("  info - Show detailed debug info")
        print("  test - Add player to set 1 and enable")
        print("  bosstest <N> - Force N boss frames visible to test secure positioning (1-8, 'off' to exit)")
        print("  reinit - Reinitialize frames")
    end
end
