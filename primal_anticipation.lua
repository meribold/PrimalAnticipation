-- The function used as the trigger of 'PrimalAnticipationLoader'.
-- Register this trigger for PLAYER_LOGIN.
function()
    -- WeakAuras pretends this fired after leaving its configuration.
    if primalAnticipation then
        WeakAurasAceEvents:SendMessage("ANTICIPATED_COMBO_POINTS", anticipatedCP, GetComboPoints("player"))
        return false
    end
    
    print("Running PrimalAnticipation PLAYER_LOGIN handler.")
    
    primalAnticipation = { _G = _G }
    
    setmetatable(primalAnticipation, {__index = _G})
    setfenv(1, primalAnticipation)
    
    print = function(...)
        if debug then _G.print(...) end
    end
    
    --debug = true
    
    frame = CreateFrame("Frame")
    
    frame:SetScript("OnEvent", function(self, event, ...)
            return self[event] and self[event](self, ...)
    end)
    
    comboTarget, lastMove = nil, nil
    mangled = mangled or false -- Set to true when mangle crits. On UNIT_COMBO_POINTS it gets set to false again.
    anticipatedCP = anticipatedCP or _G.GetComboPoints("player") -- This value is displayed.
    unresolvedComboPointEvents = unresolvedComboPointEvents or 0
    expectedComboPointEvents = expectedComboPointEvents or 0
    cPGenerators = {
        [1822] = true, -- Rake
        [5221] = true, -- Shred
        [6785] = true, -- Ravage
        [33876] = true, -- Mangle
        [102545] = true, -- Ravage!
        [114236] = true, -- Shred!
    }
    mangle = {
        [33876] = true,
    }
    finishers = {
        [1079] = true, -- Rip
        [22568] = true, -- Ferocious Bite
        [22570] = true, -- Maim
        [127538] = true, -- Savage Roar
    }
    swipe = {
        [62078] = true,
    }
    primalFury = {
        [16953] = true,
    }
    redirect = {
        [110730] = true,
    }
    comboPoint = {
        [139546] = true, -- See http://www.wowhead.com/spell=138352
    }
    
    setAnticipatedCP =  function(cP)
        if anticipatedCP ~= cP then
            anticipatedCP  = cP
            WeakAurasAceEvents:SendMessage("ANTICIPATED_COMBO_POINTS", anticipatedCP, GetComboPoints("player"))
        end
    end
    
    resyncCP = function()
        setAnticipatedCP(GetComboPoints("player"))
    end
    
    incrementCP = function()
        if anticipatedCP < 5 then
            setAnticipatedCP(anticipatedCP + 1)
        end
    end
    
    frame.COMBAT_LOG_EVENT_UNFILTERED = function(self, _, subEvent, _, sourceGUID, _, _, _, destGUID, _, _, _, ...)
        -- http://wowpedia.org/API_COMBAT_LOG_EVENT
        
        if subEvent == "SPELL_CAST_SUCCESS" then
            if sourceGUID == UnitGUID("player") then
                local  spellId, spellName =  ...
                if cPGenerators[spellId] then
                    lastMove = nil
                    print(subEvent, spellName, spellId)
                    if mangle[spellId] then
                        -- Mangle is weird. This combat event happens noticeably before the first combo point is added.
                        -- We could still get e.g. parried after this event happened. I'm guessing the combo target won't change
                        -- in that scenario.
                    end
                elseif finishers[spellId] then
                    lastMove = spellId
                    -- We could also speed this up, but it seems pointless.
                    --anticipatedCP = 0
                    print(subEvent, spellName, spellId, "(" .. GetComboPoints("player") .. " cp)")
                elseif swipe[spellId] then
                    lastMove = nil
                    print(subEvent, spellName, spellId)
                    -- ...
                elseif primalFury[spellId] then
                    lastMove = spellId
                    print(subEvent, spellName, spellId)
                elseif comboPoint[spellId] then
                    lastMove = spellId
                    print(subEvent, spellName, spellId)
                end
            end
            
        elseif subEvent == "SPELL_DAMAGE" then
            if sourceGUID == UnitGUID("player") then
                local spellId, spellName, _, _, _, _, _, _, _, critical = ...
                if  cPGenerators[spellId] then
                    -- We got a hit with one of our single-target combo moves.
                    print(subEvent, spellName, (critical and '' or "not ") .. "critical")
                    lastMove = spellId
                    if destGUID == UnitGUID("target") then -- We hit our target.
                        if mangle[spellId] then
                            -- It was Mangle. The game still won't have registered a single combo point.
                            if comboTarget and destGUID == comboTarget then
                                incrementCP()
                            else
                                setAnticipatedCP(1)
                                comboTarget = destGUID
                            end
                            mangled = true -- Don't resync on the next UNIT_COMBO_POINTS event.
                        end
                        if critical then
                            if not mangle[spellId] then -- It's not Mangle: the initial combo point was added at this point.
                                resyncCP()
                            end
                            --print("UnitCanAttack(\"player\", \"target\") == " .. UnitCanAttack("player", "target")  or "nil")
                            --print("UnitHealth(\"target\") == ", UnitHealth("target"))
                            incrementCP() -- Add another combo point.
                        end
                    else -- We hit something, but it's not our target.
                        if not comboTarget or destGUID ~= comboTarget then
                            setAnticipatedCP(0)
                            comboTarget = destGUID
                        end
                        if mangle[spellId] then
                            incrementCP()
                            expectedComboPointEvents = expectedComboPointEvents + 1
                            if critical then
                                incrementCP()
                                expectedComboPointEvents = expectedComboPointEvents + 1
                            end
                            mangled = true -- Don't resync on the next UNIT_COMBO_POINTS event.
                        elseif unresolvedComboPointEvents > 0 then
                            incrementCP()
                            unresolvedComboPointEvents = unresolvedComboPointEvents - 1
                        end
                        if not mangle[spellId] and critical then
                            -- The UNIT_COMBO_POINT event for the fact that it's a crit wasn't posted yet.
                            incrementCP()
                            expectedComboPointEvents = expectedComboPointEvents + 1
                        end
                    end
                elseif swipe[spellId] then
                    print(subEvent, spellName)
                    lastMove = spellId
                    -- When we have a combo target (a target with at leasts one CP; does it have to be alive?), Swipe will always try to
                    -- add combo points to that target. Regardless of wether it's our target. If we didn't hit it, nothing happens.
                    --
                    -- When we don't have a combo target but have a target, combo points can only be added to our target.
                    -- This remains true even if we couldn't even attack our target (e.g. a friendly target). If we didn't hit it nothing happens.
                    --
                    -- When we have neither a combo target nor a target, a combo point will be added to the first unit we hit and it will
                    -- become our combo target.
                    if comboTarget and destGUID == comboTarget then
                        -- We hit our combo target with Swipe.
                        if destGUID == UnitGUID("target") then
                            -- Our combo target is also our target. Do nothing. This was already handled in response to a
                            -- UNIT_COMBO_POINTS event.
                        else
                            -- Add one combo point. Primal Fury isn't involved here.
                            if unresolvedComboPointEvents > 0 then
                                unresolvedComboPointEvents  = 0
                                incrementCP()
                            end
                        end
                    elseif not comboTarget then
                        if UnitExists("target") then
                            if destGUID == UnitGUID("target") then
                                -- Do nothing. This was handled in response to UNIT_COMBO_POINTS.
                            end
                        else -- No combo target, no target.
                            if unresolvedComboPointEvents > 0 then -- There were UNIT_COMBO_POINTS event we couldn't handle. One for
                                -- each target we hit with swipe. This one's the first we hit and it'll be our combo target.
                                comboTarget = destGUID
                                unresolvedComboPointEvents  = 0
                                incrementCP()
                            end
                        end
                    end
                end
            end
            
        elseif subEvent == "UNIT_DIED" or subEvent == "UNIT_DESTROYED" then
            -- Whatever we anticipated is most likely not going to happen since our target died.
            if comboTarget and comboTarget == destGUID and destGUID == UnitGUID("target") then
                resyncCP()
                comboTarget = nil -- This probably needs to be handled more cleverly.
                print(subEvent)
            end
        end
    end
    
    frame.UNIT_COMBO_POINTS = function(self, unit, ...)
        print("UNIT_COMBO_POINTS")
        if GetComboPoints("player") > 0 then
            -- We have at least one  CP on our target thus the target is our combo target.
            -- This event probalby fired in response to using a single-target combo generator.
            comboTarget = UnitGUID("target")
            if not mangled then
                resyncCP()
            else
                -- Mangle was the most recent combo point generator used. The game has just added one CPs in response.
                -- It was a crit. We have been anticipating both combo points for a bit therefore we don't resync yet.
                mangled =  false
            end
        else -- No combo points on the target.
            if lastMove and finishers[lastMove] then -- Did we use a finisher?
                -- SPELL_CAST_SUCCESS is posted before UNIT_COMBO_POINTS
                -- for all finishers so we know.
                setAnticipatedCP(0)
                comboTarget = nil
                lastMove = nil
            else
                -- For Swipe and single-target combo moves other than Mangle,
                -- this event is handled before SPELL_CAST_SUCCESS.
                -- Did we use Swipe while not targeting our combo target?
                -- Did we use Shred on a unit that's not our target (anymore)?
                -- We don't know.
                -- Let's wait for a second so SPELL_DAMAGE can resolve.
                -- If that event isn't posted reset the combo points.
                if expectedComboPointEvents == 0 then
                    unresolvedComboPointEvents = unresolvedComboPointEvents + 1
                    if unresolvedComboPointEvents > 0 then
                        -- Does this restart the timer when called while it's active? This is written assuming so.
                        -- Maybe any UNIT_COMBO_POINT event should stop the timer first.
                        WeakAurasTimers:ScheduleTimer(function()
                                if unresolvedComboPointEvents > 0 then
                                    if GetComboPoints("player") == 0 then
                                        print("Resetting anticipated Combo Points")
                                        mangled = false
                                        comboTarget = nil
                                        setAnticipatedCP(0)
                                    else
                                        comboTarget = UnitGUID("target")
                                    end
                                    unresolvedComboPointEvents = 0
                                    expectedComboPointEvents = 0
                                end
                        end, 1)
                        -- See http://www.wowace.com/addons/ace3/pages/api/ace-timer-3-0
                    end
                end
            end
        end
        if expectedComboPointEvents > 0 then
            expectedComboPointEvents = expectedComboPointEvents - 1
            lastMove = nil
        end
    end
    
    frame.PLAYER_TARGET_CHANGED = function(self, cause)
        -- We have combo points on our new target.
        if GetComboPoints("player") > 0 then
            comboTarget = UnitGUID("target")
            setAnticipatedCP(GetComboPoints("player"))
        elseif UnitGUID("target") == comboTarget then
            -- Looks like that's not really the combo target.
            comboTarget = nil
        end
    end
    
    frame.PLAYER_ENTERING_WORLD = function()
        if GetComboPoints("player") == 0 then
            comboTarget = nil
            setAnticipatedCP(0)
            mangled = false
            unresolvedComboPointEvents = 0
            expectedComboPointEvents = 0
        end
    end
    
    frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    frame:RegisterUnitEvent("UNIT_COMBO_POINTS", "player")
    frame:RegisterEvent("PLAYER_TARGET_CHANGED")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    
    return false
end

-- This function is used as the trigger of PrimalAnticipationCP1.
-- Those for the following combo points are analogous.
-- Register these triggers for ANTICIPATED_COMBO_POINTS.
function(event, anticipatedCP, cP)
    if anticipatedCP >= 1 then
        return true
    end
    return false
end

-- The corressponding untriggers are trivial:
function()
    return true
end

-- The PrimalAnticipationCP1 to PrimalAnticipationCP5 displays have
-- custom animations changing the color. Here's the function for the
-- first combo point. The others are pretty much the same.
-- 'GetComboPoints("player") < 1' only has to be changed to the number
-- of the combo point we're displaying.
function(progress, r1, g1, b1, a1, r2, g2, b2, a2)
    setfenv(1, primalAnticipation)
    if not _G.UnitExists("target") or (_G.UnitGUID("target") ~= comboTarget and anticipatedCP ~= 0) then
        return 192, 0, 0, a1 -- Major danger!
    elseif  _G.UnitGUID("target") == comboTarget and _G.GetComboPoints("player") < 1 then
        return 0, 0, 192, a1 -- Minor danger.
    else
        return 255, 255, 255, a1 -- Everything's fine. Don't worry.
    end
end

