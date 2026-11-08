-- Version 2 scenarios: zones, level marks, session history, projection, the graphs window,
-- the main-window buttons and the portraits. ADDON_DIR is set by run_tests.py.
local failures, passes = {}, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else failures[#failures + 1] = msg; io.write("FAIL: ", msg, "\n") end
end
local function near(a, b, eps) return math.abs((a or 0) - (b or 0)) <= (eps or 1e-6) end
local function has(s, needle) return type(s) == "string" and s:find(needle, 1, true) ~= nil end
local function printsContain(s)
  for _, p in ipairs(MOCK.prints) do if has(p, s) then return true end end
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

-- 1. login at level 12 in Elwynn ---------------------------------------------------
MOCK.level, MOCK.xp, MOCK.xpMax = 12, 350, 14000
local ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
MOCK.fire("PLAYER_ENTERING_WORLD", true, false)
check(CatXP.zone == "Elwynn Forest", "zone read at login")
check(CatXPMainFrame.icon.texture == CatXP.TIERS[1].image, "idle portrait is the napping kitten")
check(has(CatXP.TIERS[1].image, "Interface\\AddOns\\CatXP\\Media\\cat_napping.tga"), "portrait path")
check(CatXPMainFrame.btnStart.label:GetText() == "Start", "footer button says Start")
check(CatXPGraphFrame ~= nil and not CatXPGraphFrame:IsShown(), "graphs window built hidden")

-- 2. ten minutes of grinding in Elwynn ------------------------------------------------
CatXPMainFrame.btnStart:Click()
check(CatXP:IsRunning() and CatXPMainFrame.btnStart.label:GetText() == "Pause", "footer Start button starts tracking")
for _ = 1, 10 do
  MOCK.advance(60)
  MOCK.xp = MOCK.xp + 1000
  MOCK.fire("CHAT_MSG_COMBAT_XP_GAIN", "Murloc dies, you gain 100 experience.")
  MOCK.fire("PLAYER_XP_UPDATE", "player")
end
local elwynn = CatXP.session.zones["Elwynn Forest"]
check(elwynn and near(elwynn.secs, 600) and elwynn.xp == 10000 and elwynn.kills == 10, "zone record for Elwynn")
check(CatXPCharDB.levels[12].xpMax == 14000, "level bar size recorded")

-- 3. zone change -----------------------------------------------------------------
MOCK.zone = "Westfall"
MOCK.fire("ZONE_CHANGED_NEW_AREA")
check(CatXP.zone == "Westfall", "zone updated on ZONE_CHANGED_NEW_AREA")
MOCK.advance(120)
MOCK.xp = MOCK.xp + 3000
MOCK.fire("PLAYER_XP_UPDATE", "player")
local westfall = CatXP.session.zones["Westfall"]
check(westfall and near(westfall.secs, 120) and westfall.xp == 3000 and westfall.kills == 0, "zone record for Westfall")
check(near(elwynn.secs, 600) and elwynn.xp == 10000, "Elwynn untouched after leaving")
local zs = CatXP:SortedZones()
check(zs[1].name == "Elwynn Forest" and zs[2].name == "Westfall" and near(zs[2].rate, 90000), "zones sorted by xp with rates")

-- 4. rate series -----------------------------------------------------------------
local pts, k = CatXP:RateSeries(5, 110)
check(#pts == 12 and k == 1, "series has one point per completed minute, got " .. #pts)
check(near(pts[1], 0) and near(pts[6], 60000) and near(pts[12], 48000), "series values")

-- 5. level-up mark and projection ---------------------------------------------------
MOCK.level, MOCK.xp, MOCK.xpMax = 13, 100, 16000
MOCK.fire("PLAYER_LEVEL_UP", 13)
MOCK.fire("PLAYER_XP_UPDATE", "player")
check(#CatXP.session.marks == 1 and CatXP.session.marks[1].level == 13 and CatXP.session.marks[1].m == 13, "level-up mark recorded")
check(CatXP.session.xp == 13750, "session xp after level-up, got " .. tostring(CatXP.session.xp))
check(CatXPCharDB.levels[13].xpMax == 16000, "new level bar size recorded")
local expected = 16000 - 100
for L = 14, 59 do expected = expected + CatXP.XP_TABLE[L] end
check(CatXP:XPToMaxLevel() == expected, "xp to 60 uses the real bar plus the table")
local proj = CatXP:Projection()
check(proj and proj.xp == expected and proj.fromLevels == true and near(proj.rate, 13650 / 720 * 3600), "projection from finished levels")
check(printsContain("Level 12 cleared") and printsContain("|TInterface"), "level summary carries the portrait")

-- 6. graphs window: session tab ----------------------------------------------------
ns.ToggleGraphs()
check(CatXPGraphFrame:IsShown() and ns.graphDraws >= 1, "graphs open and drawn")
local drawn = ns.graphDraws
ns.RefreshGraphs()
check(ns.graphDraws == drawn, "automatic refresh is throttled")
MOCK.advance(6)
check(ns.graphDraws > drawn, "redraws after the throttle window")
pts = CatXP:RateSeries(5, 110)
check(ns.graphChart.used.lines == #pts - 1, "one line segment between each pair of points")
check(has(CatXPGraphFrame.lines[1]:GetText(), "Rolling"), "session summary line")
check(ns.graphChart.used.grid >= 3, "grid, reference line and level mark drawn")

-- 7. levels, zones, history and cats tabs -------------------------------------------
ns.ShowGraphTab("levels")
check(ns.graphChart.used.bars == 2, "levels tab: one bar per level, got " .. ns.graphChart.used.bars)
check(has(CatXPGraphFrame.lines[2]:GetText(), "Average of 1 finished level"), "levels average line")
check(has(CatXPGraphFrame.lines[5]:GetText(), "Level 60 in about"), "level 60 estimate line")
check(CatXPDB.settings.graphTab == "levels", "tab remembered")

ns.ShowGraphTab("zones")
check(ns.graphChart.used.bars == 2, "zones tab: two zones with enough time")
check(has(CatXPGraphFrame.lines[2]:GetText(), "Elwynn Forest"), "zones summary lists Elwynn first")

ns.ShowGraphTab("history")
check(ns.graphChart.used.bars == 1, "history tab: only the current session so far")
check(has(CatXPGraphFrame.lines[1]:GetText(), "XP/hour per session"), "history summary line")

ns.ShowGraphTab("cats")
check(ns.graphLadder:IsShown() and not ns.graphChart.frame:IsShown(), "cats tab shows the ladder")
local st = CatXP:GetStats()
check(st.tier.name == "Nyan Cat", "session rate is Nyan Cat, got " .. st.tier.name)
local lit = 0
for i, cell in ipairs(ns.graphLadder.cells) do if cell.glow:IsShown() then lit = lit + 1; check(i == 17, "highlighted cell is the Nyan Cat") end end
check(lit == 1, "exactly one cat highlighted")
check(#ns.graphLadder.cells == #CatXP.TIERS and ns.graphLadder.cells[17].pic.texture == CatXP.TIERS[17].image, "every tier has a portrait")
check(has(CatXPGraphFrame.lines[3]:GetText(), "Top of the ladder"), "top of the ladder named")
check(has(ns.graphLadder.cells[1].min:GetText(), "under 10k") and has(ns.graphLadder.cells[2].min:GetText(), "10k+")
  and has(ns.graphLadder.cells[8].min:GetText(), "21.5k+") and has(ns.graphLadder.cells[17].min:GetText(), "35k+"), "ladder labels")
ns.ShowGraphTab("session")
check(ns.graphChart.frame:IsShown() and not ns.graphLadder:IsShown(), "back to the chart")

-- 8. reset archives the session ----------------------------------------------------
CatXP:Reset()
local hist = CatXPCharDB.history
check(#hist == 1 and hist[1].xp == 13750 and near(hist[1].secs, 726) and hist[1].startLevel == 12 and hist[1].endLevel == 13 and hist[1].levelUps == 1 and hist[1].kills == 10, "session archived on reset")
check(printsContain("saved to history"), "reset message mentions the archive")
check(CatXP.session.xp == 0 and next(CatXP.session.zones) == nil and #CatXP.session.marks == 0, "fresh session")
MOCK.advance(10)
CatXP:Reset()
check(#hist == 1, "short sessions are not archived")
ns.ShowGraphTab("history")
check(ns.graphChart.used.bars == 1 and has(CatXPGraphFrame.lines[2]:GetText(), "1 session:"), "history tab shows the archived session")

-- 9. reload keeps history and zone ----------------------------------------------------
local savedDB, savedChar = MOCK.deepcopy(CatXPDB), MOCK.deepcopy(CatXPCharDB)
MOCK.resetUI()
CatXPDB, CatXPCharDB = savedDB, savedChar
_G.CatXP = nil
ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
MOCK.fire("PLAYER_ENTERING_WORLD", false, true)
check(#CatXPCharDB.history == 1 and CatXP.zone == "Westfall" and type(CatXP.session.zones) == "table", "history and zone after reload")
check(CatXPDB.settings.graphTab == "history" and not CatXPGraphFrame:IsShown(), "graph tab remembered, window closed after reload")

-- 10. controls: slash, shift-click, footer, menu -------------------------------------------
SlashCmdList.CATXP("graphs")
check(CatXPGraphFrame:IsShown(), "slash graphs opens")
SlashCmdList.CATXP("graphs")
check(not CatXPGraphFrame:IsShown(), "slash graphs closes")
MOCK.shift = true
CatXPMainFrame:Click("LeftButton")
check(CatXPGraphFrame:IsShown() and not CatXPDetailsFrame:IsShown(), "shift-click opens graphs, not details")
MOCK.shift = false
CatXPMainFrame:Click("LeftButton")
check(CatXPDetailsFrame:IsShown(), "plain click opens details")
check(CatXPDetailsFrame.portrait.texture == CatXP.TIERS[1].image, "details portrait follows the tier")
CatXPMainFrame.btnDetails:Click()
check(not CatXPDetailsFrame:IsShown(), "footer Details toggles")
CatXPMainFrame.btnGraphs:Click()
check(not CatXPGraphFrame:IsShown(), "footer Graphs toggles")
CatXPDetailsFrame.btnGraphs:Click()
check(CatXPGraphFrame:IsShown(), "details Graphs button opens graphs")
CatXPMainFrame:Click("RightButton")
check(MOCK.menuHas("Hide graphs") and MOCK.menuHas("Clear history..."), "menu lists graphs and clear history")
MOCK.menuClick("Hide graphs")
check(not CatXPGraphFrame:IsShown(), "menu hides graphs")
check(CatXP:IsRunning(), "still tracking after reload")
CatXPMainFrame.btnStart:Click()
check(not CatXP:IsRunning() and CatXPMainFrame.btnStart.label:GetText() == "Start", "footer Pause pauses")
CatXPMainFrame.btnStart:Click()
MOCK.advance(90)
MOCK.xp = MOCK.xp + 500
MOCK.fire("PLAYER_XP_UPDATE", "player")
CatXPMainFrame.btnReset:Click()
check(CatXP.session.xp == 0 and #CatXPCharDB.history == 2, "footer Reset resets and archives")
SlashCmdList.CATXP("resetsessions")
check(#CatXPCharDB.history == 0 and printsContain("Session history cleared"), "resetsessions clears history")
CatXPMainFrame:Enter()
check(has(GameTooltip.lines[2], "|T") and has(GameTooltip.lines[2], "Napping Kitten"), "tooltip shows the portrait")
CatXPMainFrame:Leave()

-- 11. long sessions are downsampled ------------------------------------------------------
CatXP.session.secs = 300 * 60
for i = 1, 300 do CatXP.session.buckets[i] = 1000 end
pts, k = CatXP:RateSeries(5, 110)
check(#pts == 100 and k == 3 and near(pts[50], 60000), "300 minutes become 100 points of 3 minutes")
ns.ToggleGraphs()
ns.ShowGraphTab("session")
check(ns.graphChart.used.lines == 99, "long session draws 99 segments")

-- 12. party chat: promotions, sad demotions, the margin, the gap, toggles, solo ----------------
CatXP:Reset()
if not CatXP:IsRunning() then CatXP:Toggle() end
MOCK.inGroup = true
MOCK.sent = {}
MOCK.advance(61)                    -- past the warm-up and the announce gap
MOCK.xp = MOCK.xp + 500             -- 500 xp in 61 s is about 29.5k/h: Leopard
MOCK.fire("PLAYER_XP_UPDATE", "player")
local last = MOCK.sent[#MOCK.sent]
check(last and last.chan == "PARTY" and has(last.msg, "Tester reached Leopard") and has(last.msg, "xp/h") and not has(last.msg, "|"),
  "promotion sent to party chat as plain text, got " .. tostring(last and last.msg))
-- from here the clock and the rate are set by hand, so every step is exact
local s = CatXP.session
local function at(secsLater, rate)
  MOCK.now = MOCK.now + secsLater
  s.xp = rate * s.secs / 3600
  CatXP:CheckTier()
end
at(61, 16200)                       -- Alley Cat
last = MOCK.sent[#MOCK.sent]
check(#MOCK.sent == 2 and has(last.msg, "Tester slipped to Alley Cat") and has(last.msg, CatXP.TIERS[5].sad),
  "demotion sent to party with the sad line, got " .. tostring(last.msg))
check(printsContain("Demoted to"), "demotion printed locally too")
at(61, 29500)                       -- back up to Leopard
last = MOCK.sent[#MOCK.sent]
check(#MOCK.sent == 3 and has(last.msg, "Tester is back to Leopard"), "returning to a known cat is a comeback, not a record")
at(61, 28800)                       -- a hair under Leopard: inside the margin
check(#MOCK.sent == 3, "a dip inside the margin is not announced")
at(1, 28500)                        -- clearly under
check(#MOCK.sent == 4 and has(MOCK.sent[4].msg, "slipped to Puma"), "a real drop is announced once past the margin")
at(10, 35500)                       -- Nyan Cat, but too soon after the last message
check(#MOCK.sent == 4, "the one-minute gap holds for party messages")
SlashCmdList.CATXP("party")
check(CatXPDB.settings.partyAnnounce == false, "party setting toggled off and saved")
MOCK.prints = {}
at(61, 36000)
check(#MOCK.sent == 4 and printsContain("Promoted to") and s.bestTier == 17, "party announcements off: local message only")
SlashCmdList.CATXP("party")
MOCK.inGroup = false
CatXP:Reset()
MOCK.advance(61)
MOCK.xp = MOCK.xp + 600
MOCK.fire("PLAYER_XP_UPDATE", "player")
check(#MOCK.sent == 4 and CatXP.session.bestTier >= 2, "solo: promotion stays local")

io.write(string.format("\n%d checks passed, %d failed\n", passes, #failures))
if #failures > 0 then dumpPrints() end
io.flush()
return #failures
