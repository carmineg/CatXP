-- Drives CatXP through the mock WoW API. ADDON_DIR is set by run_tests.py.
local failures, passes = {}, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else failures[#failures + 1] = msg; io.write("FAIL: ", msg, "\n") end
end
local function near(a, b, eps) return math.abs((a or 0) - (b or 0)) <= (eps or 1e-6) end
local function printsContain(s)
  for _, p in ipairs(MOCK.prints) do if p:find(s, 1, true) then return true end end
  return false
end
local function dumpPrints() for _, p in ipairs(MOCK.prints) do io.write("  > ", p, "\n") end end

local function loadAddon()
  local ns = {}
  for _, file in ipairs({ "Core.lua", "FactBank.lua", "Facts.lua", "Charts.lua", "Roster.lua", "UI.lua", "Graphs.lua", "Board.lua" }) do
    local chunk, err = loadfile(ADDON_DIR .. "/" .. file)
    assert(chunk, err)
    chunk("CatXP", ns)
  end
  return ns
end

-- 1. load + login -----------------------------------------------------------
local ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
CatXP.settings.chatPace = 1   -- these scenarios were written for one automatic line a minute; the default is five
check(CatXPDB and CatXPDB.settings and CatXPDB.settings.autoStart == true, "defaults applied")
check(CatXPMainFrame ~= nil, "main frame created")
check(CatXPDetailsFrame ~= nil and not CatXPDetailsFrame:IsShown(), "details frame created hidden")
MOCK.fire("PLAYER_ENTERING_WORLD", true, false)
check(printsContain("loaded"), "login greeting printed")
check(CatXP.lastLevel == 10 and CatXP.lastXP == 500 and CatXP.lastMax == 10000, "snapshot taken at login")
local st = CatXP:GetStats()
check(st.running == false and st.tier.name == "Napping Kitten", "idle shows Napping Kitten")
check(CatXPMainFrame.tierLine:GetText():find("no session yet", 1, true) ~= nil, "idle tier line")

-- 2. first kill auto-starts ----------------------------------------------------
MOCK.xp = 545
MOCK.fire("CHAT_MSG_COMBAT_XP_GAIN", "Kobold Vermin dies, you gain 45 experience.")
MOCK.fire("PLAYER_XP_UPDATE", "player")
check(CatXP:IsRunning(), "auto-start on first XP")
check(CatXP.session.xp == 45, "session xp 45, got " .. tostring(CatXP.session.xp))
check(CatXP.session.kills == 1 and CatXP.session.recentKills[1] == 45, "kill counted")
check(CatXPCharDB.levels[10] and CatXPCharDB.levels[10].xp == 45 and CatXPCharDB.levels[10].kills == 1, "level 10 record")
check(MOCK.activeTickers() == 2, "session ticker and leaderboard heartbeat running")
check(printsContain("XP spotted"), "auto-start message")
check(CatXPMainFrame.tierLine:GetText():find("Warming up", 1, true) ~= nil, "warming up shown")

-- 3. time accrual -------------------------------------------------------------
MOCK.advance(120)
check(near(CatXP.session.secs, 120), "session secs 120, got " .. tostring(CatXP.session.secs))
check(near(CatXPCharDB.levels[10].secs, 120), "level secs 120")
st = CatXP:GetStats()
check(near(st.rate, 45 / 120 * 3600), "rate 1350/h")
check(st.tier.name == "Napping Kitten", "Napping Kitten at 1.35k/h, got " .. st.tier.name)
check(st.warming == false, "warm after 60s")
check(near(st.ttl, (10000 - 545) / 1350 * 3600), "time to level")
check(st.ktl == math.ceil((10000 - 545) / 45), "kills to level")
check(CatXPMainFrame.tierLine:GetText():find("Napping Kitten", 1, true) ~= nil, "tier line shows the cat")
check(near(CatXPMainFrame.borderColor[1], 0x9d / 255), "border takes tier colour")

-- 4. quest xp raises the tier and announces --------------------------------------
MOCK.xp = 2545
MOCK.fire("CHAT_MSG_COMBAT_XP_GAIN", "You gain 2000 experience.")
MOCK.fire("PLAYER_XP_UPDATE", "player")
check(CatXP.session.xp == 2045 and CatXP.session.kills == 1, "quest xp counted, not a kill")
st = CatXP:GetStats()
check(st.tier.name == "Nyan Cat", "Nyan Cat at " .. tostring(st.rate) .. ", got " .. st.tier.name)
check(printsContain("Promoted to"), "promotion announced")
check(CatXP.session.bestTier == 17, "best tier of the session recorded")
check(near(st.otherXP, 2000), "other xp 2000")

-- 5. level up: PLAYER_LEVEL_UP then PLAYER_XP_UPDATE, both reporting new values ---
MOCK.level, MOCK.xp, MOCK.xpMax = 11, 300, 12000
MOCK.fire("PLAYER_LEVEL_UP", 11)
MOCK.fire("PLAYER_XP_UPDATE", "player")
local expectedGain = (10000 - 2545) + 300
check(CatXP.session.xp == 2045 + expectedGain, "level-up xp booked once, got " .. tostring(CatXP.session.xp))
check(CatXPCharDB.levels[10].done == true, "level 10 finished")
check(CatXPCharDB.levels[10].xp == 2045 + (10000 - 2545), "overflow credited to level 10, got " .. tostring(CatXPCharDB.levels[10].xp))
check(CatXPCharDB.levels[11] and CatXPCharDB.levels[11].xp == 300, "level 11 record started with 300")
check(printsContain("Level 10 cleared"), "level summary printed")
check(CatXP.session.levelUps == 1, "levelUps counter")

-- 6. xp wraps before UnitLevel updates, then a late PLAYER_LEVEL_UP: no double count
MOCK.advance(60)
MOCK.xp = 100
MOCK.fire("PLAYER_XP_UPDATE", "player")
local afterWrap = CatXP.session.xp
check(afterWrap == 2045 + expectedGain + (12000 - 300) + 100, "wrap booked as level-up, got " .. tostring(afterWrap))
MOCK.level, MOCK.xpMax = 12, 14000
MOCK.fire("PLAYER_LEVEL_UP", 12)
check(CatXP.session.xp == afterWrap, "no double count after late PLAYER_LEVEL_UP, got " .. tostring(CatXP.session.xp))
check(CatXPCharDB.levels[11].done == true and CatXPCharDB.levels[12] ~= nil, "level 11 closed, 12 opened")
MOCK.xp = 150
MOCK.fire("PLAYER_XP_UPDATE", "player")
check(CatXP.session.xp == afterWrap + 50, "normal gain resumes after wrap")

-- 7. pause / resume -------------------------------------------------------------
CatXP:Pause()
check(not CatXP:IsRunning() and CatXPCharDB.manualPause == true, "manual pause")
check(MOCK.activeTickers() == 1, "session ticker cancelled on pause, heartbeat stays")
local secsAtPause = CatXP.session.secs
MOCK.advance(30)
check(near(CatXP.session.secs, secsAtPause), "no time while paused")
MOCK.xp = 250
MOCK.fire("PLAYER_XP_UPDATE", "player")
check(CatXP.session.xp == afterWrap + 50, "xp while manually paused is not booked")
check(not CatXP:IsRunning(), "manual pause is not auto-started")
CatXP:Start()
check(CatXP:IsRunning() and CatXPCharDB.manualPause == nil, "resumed")
MOCK.xp = 350
MOCK.fire("PLAYER_XP_UPDATE", "player")
check(CatXP.session.xp == afterWrap + 150, "xp booked after resume")
check(CatXPMainFrame.status:GetText():find("tracking", 1, true) ~= nil, "status shows tracking")

-- 8. going AFK never pauses: only a manual pause does -----------------------------
MOCK.afk = true
pcall(MOCK.fire, "PLAYER_FLAGS_CHANGED", "player")
check(CatXP:IsRunning() and CatXP.afkPaused == nil, "AFK does not pause the clock")
check(CatXPMainFrame.status:GetText():find("tracking", 1, true) ~= nil, "status still shows tracking while AFK")
MOCK.afk = false
pcall(MOCK.fire, "PLAYER_FLAGS_CHANGED", "player")
check(CatXP:IsRunning(), "still tracking after coming back")
CatXPMainFrame:Click("RightButton")
check(CatXPDB.settings.afkPause == nil and not MOCK.menuHas("Pause while AFK") and MOCK.menuHas("Auto-start on XP gain"), "no AFK option anywhere")

-- 9. reset keeps running and keeps history ----------------------------------------
local levelsBefore = #CatXP:SortedLevels()
CatXP:Reset()
check(CatXP.session.xp == 0 and CatXP.session.secs == 0 and CatXP.session.kills == 0, "session cleared")
check(CatXP:IsRunning(), "still tracking after reset")
check(#CatXP:SortedLevels() == levelsBefore, "level history kept")
check(CatXP.session.startedAt == MOCK.wall, "new start time")

-- 10. buckets, recent rate, details panel and chart ---------------------------------
for _ = 1, 10 do
  MOCK.advance(60)
  MOCK.xp = MOCK.xp + 1000
  MOCK.fire("PLAYER_XP_UPDATE", "player")
end
check(near(CatXP.session.secs, 600) and CatXP.session.xp == 10000, "10 minutes, 10k xp")
check(near(CatXP:SessionRate(), 60000), "session rate 60k")
check(near(CatXP:RecentRate(15), 60000), "recent rate 60k, got " .. tostring(CatXP:RecentRate(15)))
check(near(CatXP:RecentRate(5), 5000 / 240 * 3600), "recent 5 min window, got " .. tostring(CatXP:RecentRate(5)))
ns.ToggleDetails()
check(CatXPDetailsFrame:IsShown(), "details open")
local bars = CatXPDetailsFrame.chart.bars
check(bars[12]:IsShown() and near(bars[12].h, 58) and bars[11]:IsShown() and near(bars[11].h, 58), "chart tall bars")
check(bars[10]:IsShown() and near(bars[10].h, 1) and not bars[9]:IsShown(), "chart empty and pre-session bars")
check(CatXPDetailsFrame.chartMax:GetText():find("peak 5.0k", 1, true) ~= nil, "chart peak label")
check(CatXPDetailsFrame.rows.rate:GetText():find("60,000", 1, true) ~= nil, "details rate")
check(CatXPDetailsFrame.levelRows[1][1]:GetText():find("12", 1, true) ~= nil, "current level first in table")
check(CatXPDetailsFrame.avgLine:GetText():find("Average of 2 finished levels", 1, true) ~= nil, "per-level average line")
local avg = CatXP:LevelAverages()
check(avg and avg.count == 2 and near(avg.avgSecs, 90), "level averages: 120s and 60s")
ns.ToggleDetails()
check(not CatXPDetailsFrame:IsShown(), "details closed")

-- 11. tooltip -------------------------------------------------------------------
CatXPMainFrame:Enter()
check(#GameTooltip.lines >= 10, "tooltip has lines: " .. #GameTooltip.lines)
CatXPMainFrame:Leave()

-- 12. menu --------------------------------------------------------------------
CatXPMainFrame:Click("RightButton")
check(MOCK.lastMenu ~= nil and #MOCK.lastMenu.elements >= 10, "menu built")
check(MOCK.menuChecked("Auto-start on XP gain") == true, "autostart checked")
MOCK.menuClick("Auto-start on XP gain")
check(CatXPDB.settings.autoStart == false, "autostart toggled via menu")
MOCK.menuClick("Auto-start on XP gain")
MOCK.menuClick("Pause tracking")
check(not CatXP:IsRunning(), "menu pause")
CatXPMainFrame:Click("RightButton")
MOCK.menuClick("Start tracking")
check(CatXP:IsRunning(), "menu start")
MOCK.menuClick("Clear history...")
check(MOCK.popups[#MOCK.popups] == "CATXP_CLEAR_HISTORY", "clear history asks first")
check(#CatXP:SortedLevels() == 3, "history intact without confirmation")
MOCK.acceptPopups = true
MOCK.menuClick("Clear history...")
check(#CatXP:SortedLevels() == 1, "history cleared keeps the current level only")
MOCK.acceptPopups = false

-- 13. slash commands ------------------------------------------------------------
SlashCmdList.CATXP("scale 1.5")
check(CatXPDB.settings.scale == 1.5 and CatXPMainFrame.scale == 1.5, "scale via slash")
SlashCmdList.CATXP("scale 9")
check(CatXPDB.settings.scale == 1.5, "bad scale rejected")
SlashCmdList.CATXP("lock")
check(CatXPDB.settings.locked == true, "lock via slash")
SlashCmdList.CATXP("unlock")
check(CatXPDB.settings.locked == false, "unlock via slash")
SlashCmdList.CATXP("hide")
check(CatXPDB.settings.shown == false and not CatXPMainFrame:IsShown() and not CatXPDetailsFrame:IsShown(), "hide hides both")
SlashCmdList.CATXP("show")
check(CatXPMainFrame:IsShown(), "show")
SlashCmdList.CATXP("details")
check(CatXPDetailsFrame:IsShown() and CatXPDB.settings.detailsShown == true, "details via slash")
SlashCmdList.CATXP("details")
check(not CatXPDetailsFrame:IsShown() and CatXPDB.settings.detailsShown == false, "details toggled off")
local n = #MOCK.prints
SlashCmdList.CATXP("tiers")
check(#MOCK.prints == n + 1 + #CatXP.TIERS, "tiers listing")
SlashCmdList.CATXP("bogus")
check(MOCK.prints[#MOCK.prints]:find("Unknown command", 1, true) ~= nil, "unknown command")
SlashCmdList.CATXP("")
check(MOCK.prints[#MOCK.prints]:find("help", 1, true) ~= nil, "bare command points at help")
SlashCmdList.CATXP("  STATUS  ")
check(MOCK.prints[#MOCK.prints]:find("Tracking", 1, true) ~= nil, "status line")

-- 14. reload persistence ----------------------------------------------------------
local savedDB, savedChar = MOCK.deepcopy(CatXPDB), MOCK.deepcopy(CatXPCharDB)
local xpBefore, secsBefore = CatXP.session.xp, CatXP.session.secs
MOCK.resetUI()
CatXPDB, CatXPCharDB = savedDB, savedChar
_G.CatXP = nil
ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
MOCK.fire("PLAYER_ENTERING_WORLD", false, true)
check(CatXP:IsRunning() and MOCK.activeTickers() == 2, "tracking resumes after reload")
check(CatXP.session.xp == xpBefore and near(CatXP.session.secs, secsBefore), "session survives reload")
check(CatXPDB.settings.scale == 1.5, "settings survive reload")
check(not printsContain("loaded"), "no greeting on reload")
MOCK.advance(10)
check(near(CatXP.session.secs, secsBefore + 10), "clock continues after reload")

-- 15. secret values and garbage never raise ----------------------------------------
MOCK.secretTest = function(v) return v == "SECRET" end
local ok = pcall(MOCK.fire, "CHAT_MSG_COMBAT_XP_GAIN", "SECRET")
check(ok, "secret chat text ignored safely")
ok = pcall(MOCK.fire, "CHAT_MSG_COMBAT_XP_GAIN", { nope = true })
check(ok, "non-string chat text ignored safely")
local kills = CatXP.session.kills
MOCK.fire("CHAT_MSG_COMBAT_XP_GAIN", "Defias Thug dies, you gain 120 experience. (+20 group bonus)")
check(CatXP.session.kills == kills + 1 and CatXP.session.recentKills[#CatXP.session.recentKills] == 120, "group kill line parsed")
MOCK.fire("CHAT_MSG_COMBAT_XP_GAIN", "Defias Thug dies, you gain 130 experience. (10 exp Rested bonus)")
check(CatXP.session.kills == kills + 2, "rested kill line parsed")
MOCK.secretTest = function(v) return type(v) == "number" end
ok = pcall(MOCK.fire, "PLAYER_XP_UPDATE", "player")
check(ok and CatXP.session.xp == xpBefore, "secret XP values skipped without error")
ok = pcall(ns.Refresh)
check(ok, "refresh survives secret values")
MOCK.secretTest = nil

-- 16. max level ------------------------------------------------------------------
MOCK.level, MOCK.xp, MOCK.xpMax = 60, 0, 0
MOCK.fire("PLAYER_LEVEL_UP", 60)
st = CatXP:GetStats()
check(st.atMax == true and st.ttl == nil and st.ktl == nil, "max level handled")
check(CatXPMainFrame.line2:GetText():find("max level", 1, true) ~= nil, "max level shown")

-- 17. helpers --------------------------------------------------------------------
check(ns.fmtNum(1234567) == "1,234,567" and ns.fmtNum(999) == "999" and ns.fmtNum(1000) == "1,000" and ns.fmtNum(0) == "0", "fmtNum")
check(ns.fmtShort(18230) == "18.2k" and ns.fmtShort(1200000) == "1.2m" and ns.fmtShort(950) == "950", "fmtShort")
check(ns.fmtTime(5025) == "1h 23m" and ns.fmtTime(125) == "2m 05s" and ns.fmtTime(90000) == "1d 1h" and ns.fmtTime(7) == "7s", "fmtTime")
local pat = ns.formatToPattern("%s dies, you gain %d experience.")
check(("Kobold Vermin dies, you gain 45 experience."):match(pat) == "Kobold Vermin", "pattern from format")
local pat2 = ns.formatToPattern("%2$d experience from %1$s.")
check(("45 experience from Kobold."):match(pat2) == "45", "positional format handled")
check(select(2, CatXP:TierFor(0)) == 1 and CatXP:TierFor(9999).name == "Napping Kitten"
  and CatXP:TierFor(10000).name == "Sleepy Kitten" and CatXP:TierFor(19999).name == "Wildcat"
  and CatXP:TierFor(20000).name == "Bobcat" and CatXP:TierFor(27500).name == "Puma"
  and CatXP:TierFor(34999).name == "Cheetah" and CatXP:TierFor(35000).name == "Nyan Cat"
  and CatXP:TierFor(1e9).name == "Nyan Cat", "tier boundaries")
check(#CatXP.TIERS == 17 and CatXP.TIERS[2].min == 10000 and CatXP.TIERS[16].min == 33500, "one cat below 10k, fifteen in the band, one above 35k")
check(ns.fmtK(20000) == "20k" and ns.fmtK(35000) == "35k" and ns.fmtK(21500) == "21.5k" and ns.fmtK(0) == "0", "fmtK")

io.write(string.format("\n%d checks passed, %d failed\n", passes, #failures))
if #failures > 0 then dumpPrints() end
io.flush()
return #failures
