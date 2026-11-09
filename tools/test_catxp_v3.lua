-- Version 3: the leaderboard. Addon messages, the live roster, records, races and
-- the board window. ADDON_DIR is set by run_tests.py.
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
local function lastAddon(kind)
  for i = #MOCK.addonSent, 1, -1 do
    local m = MOCK.addonSent[i]
    if m.msg:sub(1, 1) == kind then return m end
  end
end
local function addonCount(kind)
  local n = 0
  for _, m in ipairs(MOCK.addonSent) do if m.msg:sub(1, 1) == kind then n = n + 1 end end
  return n
end
local function fields(msg)
  local out = {}
  for piece in string.gmatch(msg .. ",", "([^,]*),") do out[#out + 1] = piece end
  return out
end

local function loadAddon()
  local ns = {}
  for _, file in ipairs({ "Core.lua", "FactBank.lua", "Facts.lua", "Charts.lua", "Roster.lua", "UI.lua", "Graphs.lua", "Board.lua" }) do
    local chunk, err = loadfile(ADDON_DIR .. "/" .. file)
    assert(chunk, err)
    chunk("CatXP", ns)
  end
  return ns
end

-- 1. login at level 20, in a guild, solo -------------------------------------------------
MOCK.level, MOCK.xp, MOCK.xpMax = 20, 1000, 20000
MOCK.inGuild = true
local ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
CatXP.settings.chatPace = 1   -- these scenarios were written for one automatic line a minute; the default is five
MOCK.fire("PLAYER_ENTERING_WORLD", true, false)
check(MOCK.prefixes.CatXP == true, "addon message prefix registered")
local q = lastAddon("Q")
check(q and q.chan == "GUILD" and q.msg == "Q,3," .. ns.Board.token, "asks the guild who is running CatXP at login")
check(CatXPBoardFrame ~= nil and not CatXPBoardFrame:IsShown(), "board built hidden")
check(CatXPMainFrame.btnBoard ~= nil, "main window has a Board button")
check(ns.Board:Identity().key == "Tester-Realm" and ns.Board:Identity().class == "WARRIOR", "identity is name-realm with class")

-- 2. tracking broadcasts state every 20 seconds -----------------------------------------------
CatXPMainFrame.btnStart:Click()
MOCK.xp = MOCK.xp + 400
MOCK.fire("PLAYER_XP_UPDATE", "player")
MOCK.advance(25)
local s = lastAddon("S")
check(s and s.chan == "GUILD", "state broadcast to the guild")
local f = fields(s.msg)
check(f[1] == "S" and f[2] == "3" and f[3] == "400" and tonumber(f[4]) >= 20 and f[5] == "20" and f[8] == "WARRIOR" and f[9] == "1",
  "state fields carry xp, secs, level, class and running, got " .. tostring(s and s.msg))
local before = addonCount("S")
MOCK.advance(15)
check(addonCount("S") == before, "no second broadcast inside 20 seconds")
MOCK.advance(10)
check(addonCount("S") == before + 1, "next broadcast after 20 seconds")

-- 3. Jesse shows up through the guild, faster ------------------------------------------------------
MOCK.receiveAddon("S,3,9000,600,22,30,0,MAGE,1,52000,2400,21,0,0,Westfall", "GUILD", "Jesse-Realm")
local rows = ns.Board:Rows()
check(#rows == 2 and rows[1].name == "Jesse" and rows[1].class == "MAGE" and rows[1].source == "guild" and near(rows[1].rate, 54000) and rows[2].isMe,
  "Jesse leads the live rows via the guild")
check(rows[1].tier.name == "Nyan Cat" and rows[1].level == 22 and rows[1].zone == "Westfall" and rows[1].rank == 1 and rows[2].rank == 2, "rows carry tier, level, zone and rank")
local jr = ns.Board.db.records["Jesse-Realm"]
check(jr and near(jr.bestRate, 52000) and jr.bestLevelSecs == 2400 and jr.bestLevel == 21 and jr.class == "MAGE", "Jesse's bests recorded from the state message")
check(ns.Board:OnlineCount() == 1, "one other cat online")

-- 4. a who-is-there query gets a prompt answer ------------------------------------------------------
before = addonCount("S")
MOCK.now = MOCK.now + 5
MOCK.receiveAddon("Q,3", "GUILD", "Jesse-Realm")
check(addonCount("S") == before + 1, "replies to a query with the current state")
MOCK.receiveAddon("S,3,1,1,1,0,0,MAGE,1,0,0,0,0,0,", "GUILD", "Tester-Realm")
check(ns.Board.roster["Tester-Realm"] == nil, "own messages are ignored")

-- 5. taking the lead in a party -------------------------------------------------------------
MOCK.inGroup = true
MOCK.sent = {}
MOCK.receiveAddon("S,3,9000,600,22,30,0,MAGE,1,52000,2400,21,0,0,Westfall", "PARTY", "Jesse-Realm")
rows = ns.Board:Rows()
check(rows[1].source == "party+guild", "seen on both channels")
MOCK.advance(65)
check(ns.Board.leader == "Jesse-Realm", "Jesse holds the lead while you are slower")
MOCK.xp = MOCK.xp + 2000
MOCK.fire("PLAYER_XP_UPDATE", "player")
local sentBefore = #MOCK.sent
MOCK.prints = {}
CatXP.lastAutoLine = GetTime()   -- as if a new cat had just been announced
ns.Board:CheckLead()
check(#MOCK.sent == sentBefore and ns.Board.leader == "Jesse-Realm" and not has(CatXP.pendingGroupSay, "takes the lead"),
  "one automatic line per pace: the lead change waits its turn, unsaid and unqueued")
CatXP.lastAutoLine, CatXP.lastGroupSay = nil, nil   -- the pace has passed
ns.Board:CheckLead()
local lead = MOCK.sent[#MOCK.sent]
check(#MOCK.sent == sentBefore + 1 and lead.chan == "PARTY" and has(lead.msg, "Tester takes the lead from Jesse") and has(lead.msg, "Cat fact:") and #lead.msg <= 250,
  "lead change posted to party with a cat fact once it is due, got " .. tostring(lead and lead.msg))
check(not printsContain("You take the lead"), "the party line is not repeated in your own chat")
local n = #MOCK.sent
ns.Board:CheckLead()
check(#MOCK.sent == n, "lead message not repeated while the lead holds")
check(ns.Board:Rows()[1].isMe, "you are on top of the live rows")

-- 6. silent cats drop off the live board -------------------------------------------------------
MOCK.advance(100)
rows = ns.Board:Rows()
check(#rows == 1 and rows[1].isMe, "Jesse dropped after 90 seconds of silence")

-- 7. records from your own sessions and levels ---------------------------------------------------
CatXP.session.secs = 1800
CatXP.session.xp = 15000
for i = 1, 30 do CatXP.session.buckets[i] = 500 end
CatXP:Reset()
local mine = ns.Board:MyRecord()
check(near(mine.bestRate, 30000, 60) and mine.bestXP == 15000 and mine.sessions == 1 and mine.longest >= 1800, "session record kept")
local h = CatXPCharDB.history[#CatXPCharDB.history]
check(h.xp == 15000 and h.curve == nil, "archived session saved without a ghost curve")
local lvl = CatXPCharDB.levels[20]
lvl.full, lvl.secs, lvl.xp = true, 1234, 20000
MOCK.level, MOCK.xp, MOCK.xpMax = 21, 50, 22000
MOCK.fire("PLAYER_LEVEL_UP", 21)
MOCK.fire("PLAYER_XP_UPDATE", "player")
check(mine.bestLevel == 20 and mine.bestLevelSecs == 1234, "fastest fully tracked level recorded")
check(CatXPCharDB.levels[21].full == true, "a level started at a level-up counts as fully tracked")
local recs = ns.Board:RecordRows()
check(#recs == 2 and recs[1].name == "Jesse" and recs[2].name == "Tester" and recs[2].isMe and recs[2].mine, "records sorted by best rate, you flagged")

-- 8. only real people on the board ------------------------------------------------------------
MOCK.advance(120)
MOCK.xp = MOCK.xp + 600
MOCK.fire("PLAYER_XP_UPDATE", "player")
rows = ns.Board:Rows()
check(#rows == 1 and rows[1].isMe and CatXPDB.settings.showGhost == nil, "alone on the board: no ghost row, no ghost setting")

-- 9. races ---------------------------------------------------------------------------------------
MOCK.sent, MOCK.addonSent = {}, {}
MOCK.receiveAddon("R,3,start,777,5," .. MOCK.wall, "PARTY", "Jesse-Realm")
local race = ns.Board.race
check(race and race.active and race.id == 777 and race.starter == "Jesse" and not race.mine and printsContain("Jesse started a 5-minute CatXP race"), "joined a race Jesse started")
MOCK.receiveAddon("R,3,end,777", "PARTY", "Jesse-Realm")
check(not race.active and race.cancelled and printsContain("Jesse called off the race") and CatXPDB.board.lastRace == nil, "race called off by its starter, nothing saved")
ns.Board:StartRace(10)
race = ns.Board.race
local r = lastAddon("R")
check(race and race.active and race.mine and race.minutes == 10, "race started locally")
check(r and has(r.msg, "R,3,start," .. race.id .. ",10,"), "race start broadcast, got " .. tostring(r and r.msg))
check(has(MOCK.sent[#MOCK.sent].msg, "CatXP race: 10 minutes"), "race announced to party chat")
MOCK.receiveAddon("S,3,9800,700,22,30,0,MAGE,1,52000,2400,21," .. race.id .. ",800,Westfall", "PARTY", "Jesse-Realm")
MOCK.advance(60)
MOCK.xp = MOCK.xp + 500
MOCK.fire("PLAYER_XP_UPDATE", "player")
local standings = ns.Board:RaceRows()
check(#standings == 2 and standings[1].name == "Jesse" and standings[1].xp == 800 and standings[2].isMe and near(standings[2].xp, 500), "standings count XP since the start")
check(ns.Board:RaceLeft() > 0 and ns.Board:RaceLeft() <= 540, "countdown running")
MOCK.advance(10)
s = lastAddon("S")
f = fields(s.msg)
check(f[13] == tostring(race.id) and f[14] == "500", "state carries the race id and race xp during a race, got " .. tostring(s and s.msg))
MOCK.advance(600)
check(race.active == false and CatXPDB.board.lastRace and CatXPDB.board.lastRace.results[1].name == "Jesse" and CatXPDB.board.lastRace.results[2].isMe, "race finished on time and saved")
check(has(MOCK.sent[#MOCK.sent].msg, "Race over! 1. Jesse 800 xp  2. Tester 500 xp"), "results posted to party, got " .. tostring(MOCK.sent[#MOCK.sent].msg))

-- 10. the board window ---------------------------------------------------------------------------
SlashCmdList.CATXP("board")
check(CatXPBoardFrame:IsShown() and ns.boardDraws >= 1, "slash opens the board")
check(ns.boardRows[1]:IsShown() and has(ns.boardRows[1].name:GetText(), "Tester"), "live rows render names")
local row = ns.boardRows[1]
row:GetScript("OnEnter")(row)
check(#GameTooltip.lines >= 6 and has(table.concat(GameTooltip.lines, "\n"), "XP / hour"), "live row tooltip has the numbers")
row:GetScript("OnLeave")(row)
local slot = ns.boardPodium[1]
check(slot:IsShown(), "podium shows the leader")
slot:GetScript("OnEnter")(slot)
check(#GameTooltip.lines >= 6, "podium tooltip has the numbers")
slot:GetScript("OnLeave")(slot)
ns.ShowBoardTab("records")
check(CatXPDB.settings.boardTab == "records" and has(ns.boardRecordRows[1].name:GetText(), "Jesse") and has(ns.boardRecordRows[2].name:GetText(), "(you)"), "records tab lists Jesse, then you")
local rrow = ns.boardRecordRows[1]
rrow:GetScript("OnEnter")(rrow)
check(#GameTooltip.lines >= 4 and has(table.concat(GameTooltip.lines, "\n"), "Best XP / hour"), "record tooltip lists the bests")
rrow:GetScript("OnLeave")(rrow)
ns.ShowBoardTab("race")
check(has(ns.boardRace.status:GetText(), "Last race") and has(ns.boardRace.lines[1]:GetText(), "Jesse"), "race tab shows the last race")
CatXPMainFrame.btnBoard:Click()
check(not CatXPBoardFrame:IsShown(), "Board button toggles the window")
MOCK.ctrl = true
CatXPMainFrame:Click("LeftButton")
check(CatXPBoardFrame:IsShown() and not CatXPDetailsFrame:IsShown(), "ctrl-click opens the board")
MOCK.ctrl = false
CatXPMainFrame:Click("RightButton")
check(MOCK.menuHas("Hide leaderboard"), "menu lists the leaderboard")
MOCK.menuClick("Hide leaderboard")
check(not CatXPBoardFrame:IsShown(), "menu hides the board")
SlashCmdList.CATXP("shareguild")
check(CatXPDB.settings.shareGuild == false, "shareguild toggles")
MOCK.addonSent = {}
MOCK.advance(25)
check(lastAddon("S") and lastAddon("S").chan == "PARTY" and addonCount("S") == 1, "guild no longer hears you, the party still does")
SlashCmdList.CATXP("shareguild")
check(not printsContain("Leaderboard error"), "no leaderboard draw errors")

-- 11. reload keeps records and settings ------------------------------------------------------------------
local savedDB, savedChar = MOCK.deepcopy(CatXPDB), MOCK.deepcopy(CatXPCharDB)
MOCK.resetUI()
CatXPDB, CatXPCharDB = savedDB, savedChar
_G.CatXP = nil
ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
MOCK.fire("PLAYER_ENTERING_WORLD", false, true)
check(CatXPDB.board.records["Jesse-Realm"] and ns.Board:RecordRows()[1].name == "Jesse", "records survive a reload")
check(CatXPDB.settings.boardTab == "race" and CatXPDB.board.lastRace ~= nil, "board tab and last race survive a reload")
check(MOCK.activeTickers() >= 1, "heartbeat running after reload")

-- 12. cat facts on every announcement -------------------------------------------------------------
local tiersWithFacts, badFacts = 0, {}
for _, tier in ipairs(CatXP.TIERS) do
  if tier.facts and #tier.facts >= 3 then tiersWithFacts = tiersWithFacts + 1 end
  for _, f in ipairs(tier.facts or {}) do
    if #f > 140 or f:find("|", 1, true) or f:sub(-1) ~= "." or f:sub(1, 1) ~= f:sub(1, 1):upper() then badFacts[#badFacts + 1] = f end
  end
end
for _, f in ipairs(ns.GENERAL_FACTS) do
  if #f > 140 or f:find("|", 1, true) or f:sub(-1) ~= "." then badFacts[#badFacts + 1] = f end
end
check(tiersWithFacts == #CatXP.TIERS, "every cat has at least three facts")
check(#badFacts == 0, "facts are short, end with a full stop and have no pipes: " .. table.concat(badFacts, " / "))
check(#ns.GENERAL_FACTS >= 10, "a general pool for races and lead changes")
local f1, f2, f3 = ns.CatFact(CatXP.TIERS[16]), ns.CatFact(CatXP.TIERS[16]), ns.CatFact(CatXP.TIERS[16])
check(f1 ~= f2 and f2 ~= f3 and f1 ~= f3, "facts do not repeat straight away")
check(type(ns.CatFact(nil)) == "string", "a fact without a cat comes from the general pool")

if not CatXP:IsRunning() then CatXP:Start("silent") end
MOCK.prints, MOCK.sent = {}, {}
MOCK.inGroup = true
CatXP.session.secs, CatXP.session.xp = 600, 600 * 31000 / 3600
CatXP.session.announcedTier, CatXP.session.bestTier, CatXP.lastAutoLine, CatXP.lastGroupSay = 1, 1, nil, nil
CatXP:CheckTier(true)
local party = MOCK.sent[#MOCK.sent]
check(party and has(party.msg, "reached Jaguar") and has(party.msg, "Cat fact:") and #party.msg <= 250, "party promotion carries a cat fact under the chat limit, got " .. tostring(party and party.msg))
check(not printsContain("Promoted to"), "in a group the promotion is said once, to the group, and not again in your own chat")
local jaguarFact = party and party.msg:match("Cat fact: (.*)$")
local isJaguar = false
for _, f in ipairs(CatXP.TIERS[14].facts) do if f == jaguarFact then isJaguar = true end end
check(isJaguar, "the fact is about the cat you just became")

-- alone, the same news is printed in your own chat, fact and all
MOCK.inGroup = false
MOCK.prints = {}
CatXP.session.announcedTier, CatXP.session.bestTier, CatXP.lastAutoLine, CatXP.lastGroupSay = 1, 1, nil, nil
CatXP:CheckTier(true)
local promo = MOCK.prints[#MOCK.prints]
check(promo and has(promo, "Promoted to") and has(promo, "Jaguar") and has(promo, "Cat fact:"), "solo promotion line carries a cat fact, got " .. tostring(promo))
check(#MOCK.sent == 1, "and nothing more is sent to anyone")

MOCK.prints = {}
CatXP.session.announcedTier, CatXP.lastAutoLine, CatXP.lastGroupSay = 14, nil, nil
CatXP.session.xp = 600 * 15000 / 3600
CatXP:CheckTier(true)
local demo = MOCK.prints[#MOCK.prints]
check(demo and has(demo, "Demoted to") and has(demo, "House Cat") and has(demo, "Cat fact:"), "demotion line carries a cat fact, got " .. tostring(demo))
MOCK.inGroup = true

MOCK.prints = {}
local lvl = CatXP:LevelRecord(CatXP.lastLevel, true)
lvl.secs, lvl.xp = 600, 5000
MOCK.level, MOCK.xp, MOCK.xpMax = MOCK.level + 1, 10, 30000
MOCK.fire("PLAYER_LEVEL_UP", MOCK.level)
MOCK.fire("PLAYER_XP_UPDATE", "player")
check(printsContain("cleared in") and printsContain("Cat fact:"), "level cleared line carries a cat fact")

MOCK.prints, MOCK.sent = {}, {}
ns.Board:StartRace(10)
check(printsContain("Race started") and printsContain("Cat fact:") and has(MOCK.sent[#MOCK.sent].msg, "Cat fact:"), "race start carries a cat fact")
ns.Board:CancelRace()

-- 13. own messages are known by token, not by name --------------------------------------------
local token = ns.Board.token
check(type(token) == "string" and #token >= 6, "a token is made at load")
MOCK.addonSent = {}
ns.Board:Broadcast(true)
s = lastAddon("S")
f = fields(s.msg)
check(f[16] == token, "state messages end with the token, got " .. tostring(s and s.msg))
ns.Board.lastQuery = 0
ns.Board:Query()
q = lastAddon("Q")
check(q and q.msg == "Q,3," .. token, "queries carry the token, got " .. tostring(q and q.msg))
-- the game shows us under a longer name than UnitName gives; our own echo must not become a second cat
MOCK.receiveAddon(s.msg, "PARTY", "Tester Thecat-Realm")
check(ns.Board.roster["Tester Thecat-Realm"] == nil and ns.Board:OnlineCount() == 0, "own echo under a longer display name is ignored")
check(ns.Board:MyName() == "Tester Thecat" and ns.Board:Rows()[1].name == "Tester Thecat", "the echo teaches us the name the game shows")
-- a stale record an older copy kept about our echo goes away
CatXPDB.board.records["Tester Thecat-Realm"] = { name = "Tester Thecat", class = "WARRIOR", realm = "Realm", bestRate = 1, sessions = 0 }
MOCK.receiveAddon(s.msg, "PARTY", "Tester Thecat-Realm")
check(CatXPDB.board.records["Tester Thecat-Realm"] == nil, "echo purges the record filed under our display name")
-- and at login, by first name and class, before any echo
CatXPDB.board.records["Tester Thecat-Realm"] = { name = "Tester Thecat", class = "WARRIOR", realm = "Realm", bestRate = 1, sessions = 0 }
CatXPDB.board.records["Tester Smith-Realm"] = { name = "Tester Smith", class = "MAGE", realm = "Realm", bestRate = 1, sessions = 0 }
ns.Board:PurgeSelfRecords()
check(CatXPDB.board.records["Tester Thecat-Realm"] == nil and CatXPDB.board.records["Tester Smith-Realm"] ~= nil, "login purge removes our stray record and keeps a different class")
-- messages from older copies without a token still work
MOCK.receiveAddon("S,3,9000,600,22,30,0,MAGE,1,52000,2400,21,0,0,Westfall", "PARTY", "Jesse-Realm")
check(ns.Board.roster["Jesse-Realm"] ~= nil, "tokenless messages from older copies are accepted")
MOCK.receiveAddon("S,3,1,1,1,0,0,MAGE,1,0,0,0,0,0,", "PARTY", "Tester-Realm")
check(ns.Board.roster["Tester-Realm"] == nil, "own name without a token is still ignored")

io.write(string.format("\n%d checks passed, %d failed\n", passes, #failures))
if #failures > 0 then dumpPrints() end
io.flush()
return #failures
