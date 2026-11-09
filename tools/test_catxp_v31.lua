-- Drives CatXP 3.1 through the mock WoW API: the fact bank and its no-repeat deck, the rate
-- windows on the main window and the one-a-minute gate on party chat. ADDON_DIR is set by run_tests.py.
local BANK_MIN = 1500

local failures, passes = {}, 0
local function check(cond, msg)
  if cond then passes = passes + 1 else failures[#failures + 1] = msg; io.write("FAIL: ", msg, "\n") end
end
local function near(a, b, eps) return math.abs((a or 0) - (b or 0)) <= (eps or 1e-6) end
local function has(s, sub) return type(s) == "string" and s:find(sub, 1, true) ~= nil end
local function printsContain(s)
  for _, p in ipairs(MOCK.prints) do if p:find(s, 1, true) then return true end end
  return false
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

-- 1. load + login -------------------------------------------------------------------------------
local ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
CatXP.settings.chatPace = 1   -- these scenarios were written for one automatic line a minute; the default is five
MOCK.fire("PLAYER_ENTERING_WORLD", true, false)
check(CatXPMainFrame ~= nil and #CatXPMainFrame.windows == 5, "main window has five rate windows")
check(CatXPDB.settings.windowsShown == true, "rate windows on by default")

-- 2. the bank: thousands of facts, every one well formed, no two the same --------------------------
local BANK = ns.GENERAL_FACTS
check(#BANK >= BANK_MIN, "the bank holds at least " .. BANK_MIN .. " facts, got " .. #BANK)
local function badFact(f)
  if type(f) ~= "string" or #f > 140 or #f < 20 then return true end
  if f:find("|", 1, true) or f:sub(-1) ~= "." then return true end
  if f:find("[^%w%p ]") then return true end
  if f:sub(1, 1) ~= f:sub(1, 1):upper() then return true end
  return false
end
local bad, seen, dupes = {}, {}, 0
for _, f in ipairs(BANK) do
  if badFact(f) then bad[#bad + 1] = tostring(f) end
  local k = f:lower():gsub("[^%w]", "")
  if seen[k] then dupes = dupes + 1 else seen[k] = true end
end
check(#bad == 0, "bank facts are plain ASCII, short, capitalised and end with a full stop: " .. table.concat(bad, " / "))
check(dupes == 0, "no two bank facts are the same, found " .. dupes)
local richCats, catBad = 0, {}
for _, tier in ipairs(CatXP.TIERS) do
  if tier.facts and #tier.facts >= 12 then richCats = richCats + 1 end
  for _, f in ipairs(tier.facts or {}) do if badFact(f) then catBad[#catBad + 1] = f end end
end
check(richCats == #CatXP.TIERS, "every cat has at least a dozen facts of its own, " .. richCats .. " of " .. #CatXP.TIERS .. " do")
check(#catBad == 0, "cat facts are well formed: " .. table.concat(catBad, " / "))

-- 3. the deck: no repeats until the whole bank has been heard ---------------------------------------
local said, repeats = {}, 0
for _ = 1, 400 do
  local f = ns.CatFact(nil)
  if said[f] then repeats = repeats + 1 end
  said[f] = true
end
check(repeats == 0, "400 facts in a row without a repeat, got " .. repeats .. " repeats")
check(CatXPDB.facts and CatXPDB.facts.pos == 401 and CatXPDB.facts.size == #BANK, "the place in the deck is saved account-wide")

-- 4. a reload carries on where the deck left off ------------------------------------------------
local savedDB, savedChar = MOCK.deepcopy(CatXPDB), MOCK.deepcopy(CatXPCharDB)
MOCK.resetUI()
CatXPDB, CatXPCharDB = savedDB, savedChar
_G.CatXP = nil
ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
MOCK.fire("PLAYER_ENTERING_WORLD", false, true)
local again = 0
for _ = 1, 300 do
  local f = ns.CatFact(nil)
  if said[f] then again = again + 1 end
  said[f] = true
end
check(again == 0, "after a reload the next 300 facts are all new ones, " .. again .. " came back")
check(CatXPDB.facts.pos == 701, "deck position carried on after the reload, got " .. tostring(CatXPDB.facts.pos))

-- 5. the end of the deck starts a fresh shuffle ---------------------------------------------------
CatXPDB.facts.pos = #BANK
local lastOfPass = ns.CatFact(nil)
local firstOfNext = ns.CatFact(nil)
check(type(lastOfPass) == "string" and type(firstOfNext) == "string" and lastOfPass ~= firstOfNext, "a new pass begins after the last fact")
check(CatXPDB.facts.pos >= 2 and CatXPDB.facts.pos <= 3, "the new pass starts at the top, pos " .. tostring(CatXPDB.facts.pos))

-- 6. a cat says its own facts first, each once, then draws from the bank ------------------------------
local tier = CatXP.TIERS[16]   -- Cheetah
CatXPDB.facts.heard = {}
local own, fromOwn, mine = {}, 0, {}
for _, f in ipairs(tier.facts) do own[f] = true end
for _ = 1, #tier.facts do
  local f = ns.CatFact(tier)
  if own[f] and not mine[f] then fromOwn = fromOwn + 1 end
  mine[f] = true
end
check(fromOwn == #tier.facts, "every one of the facts a cat has of its own is said once before anything else, got " .. fromOwn .. " of " .. #tier.facts)
check(not own[ns.CatFact(tier)], "once its own facts are used up the cat draws from the bank")
check(CatXPDB.facts.heard[tier.name] == #tier.facts, "how many of its facts a cat has said is saved")

-- 7. /catxp fact ---------------------------------------------------------------------------------
MOCK.prints = {}
CatXP:SlashCommand("fact")
check(printsContain("Cat fact:") and printsContain("pass through the bank"), "/catxp fact tells a fact and where the deck stands")

-- 8. the rate windows ------------------------------------------------------------------------------
MOCK.inGroup = false
CatXP:Reset(true)
if not CatXP:IsRunning() then CatXP:Start("silent") end
MOCK.xp = 3500
MOCK.fire("PLAYER_XP_UPDATE", "player")
MOCK.advance(120)
local st = CatXP:GetStats()
local W = st.windows
check(W and #W == 5 and W[1].key == "recent" and W[2].key == "hour" and W[3].key == "session" and W[4].key == "level" and W[5].key == "today",
  "five windows: 15 min, hour, session, level, today")
check(near(W[3].xp, 3000) and near(W[3].secs, 120) and near(W[3].rate, 3000 / 120 * 3600), "session window matches the session")
check(near(W[1].rate, CatXP:RecentRate(15)) and near(W[2].rate, CatXP:RecentRate(60)) and near(W[1].secs, 120), "recent windows use the bucket maths")
check(near(W[4].xp, 3000) and near(W[4].secs, 120), "level window matches the level record")
check(near(W[5].xp, 3000) and near(W[5].secs, 120), "today window matches on the first session of the day")
local rows = CatXPMainFrame.windows
check(rows[1].label:GetText() == "15 min" and rows[2].label:GetText() == "Hour" and rows[5].label:GetText() == "Today", "row labels")
check(has(rows[3].xp:GetText(), "3.0k xp") and has(rows[3].rate:GetText(), "/h") and has(rows[3].cat:GetText(), "Nyan Cat"),
  "session row shows xp, rate and the cat, got " .. tostring(rows[3].rate:GetText()) .. " " .. tostring(rows[3].cat:GetText()))
check(rows[3].icon:IsShown() and rows[3].icon.texture == CatXP.TIERS[17].image, "session row carries the cat portrait")
check(rows[3].time:GetText() == "2m 00s", "session row shows the time, got " .. tostring(rows[3].time:GetText()))
-- a reset keeps today
CatXP:Reset(true)
MOCK.advance(60)
W = CatXP:GetStats().windows
check(near(W[3].xp, 0) and near(W[3].secs, 60), "session starts over after a reset")
check(near(W[5].xp, 3000) and near(W[5].secs, 180), "today survives the reset, got " .. tostring(W[5].xp) .. " xp in " .. tostring(W[5].secs) .. "s")
check(has(rows[5].rate:GetText(), "/h") and rows[3].rate:GetText():find("warming", 1, true) == nil, "today row has a rate, session row is a minute old")
-- a new day starts a new today
MOCK.wall = MOCK.wall + 86400
MOCK.advance(5)
W = CatXP:GetStats().windows
check(W[5].secs <= 5 and near(W[5].xp, 0), "a new day starts today over, got " .. tostring(W[5].secs) .. "s " .. tostring(W[5].xp) .. " xp")
check(CatXPCharDB.today and CatXPCharDB.today.day == date("%Y-%m-%d"), "today is saved per character with its date")
check(has(rows[5].rate:GetText(), "warming"), "a fresh window reads warming")
CatXPMainFrame:Enter()
local tipHasHour = false
for _, l in ipairs(GameTooltip.lines) do if l:find("Last hour", 1, true) then tipHasHour = true end end
check(tipHasHour, "tooltip lists the last hour")

-- 9. hiding the windows shrinks the main window ---------------------------------------------------
local tall = CatXPMainFrame:GetHeight()
CatXP:SlashCommand("windows")
check(CatXPDB.settings.windowsShown == false and CatXPMainFrame:GetHeight() < tall and not rows[1].label:IsShown() and not rows[3].icon:IsShown(),
  "/catxp windows hides the rows and shrinks the window")
check(CatXPMainFrame.btnStart.y == -72 and CatXPMainFrame.btnBoard.y == -72, "buttons move back up, y " .. tostring(CatXPMainFrame.btnStart.y))
CatXPMainFrame:Click("RightButton")
check(MOCK.menuHas("Show rate windows") and MOCK.menuChecked("Show rate windows") == false, "menu lists the rate windows, unticked")
MOCK.menuClick("Show rate windows")
check(CatXPDB.settings.windowsShown == true and CatXPMainFrame:GetHeight() == tall and rows[1].label:IsShown() and CatXPMainFrame.btnStart.y < -72,
  "the menu puts them back")
check(MOCK.menuHas("A cat fact, please"), "menu offers a cat fact")
MOCK.prints = {}
MOCK.menuClick("A cat fact, please")
check(printsContain("Cat fact:"), "the menu button tells one")

-- 10. party chat: the last-resort gate keeps any two lines a minute apart ----------------------------
MOCK.inGroup = true
MOCK.sent = {}
CatXP.lastGroupSay, CatXP.pendingGroupSay = nil, nil
check(CatXP:GroupSay("CatXP: one") == true and #MOCK.sent == 1, "first line goes out")
check(CatXP:GroupSay("CatXP: two") == false and #MOCK.sent == 1 and CatXP.pendingGroupSay == "CatXP: two", "a second automatic line inside the minute waits")
check(CatXP:GroupSay("CatXP: three") == false and #MOCK.sent == 1 and CatXP.pendingGroupSay == "CatXP: three", "a newer line takes the place of the waiting one")
check(CatXP:GroupSay("CatXP race: go", true) == true and #MOCK.sent == 2 and CatXP.pendingGroupSay == "CatXP: three", "race lines go at once and the waiting line keeps waiting")
MOCK.advance(61)
check(#MOCK.sent == 3 and MOCK.sent[3].msg == "CatXP: three" and CatXP.pendingGroupSay == nil, "the waiting line goes out when the minute is up, sent " .. #MOCK.sent)
MOCK.inGroup = false
check(CatXP:GroupSay("CatXP: solo") == false and #MOCK.sent == 3 and CatXP.pendingGroupSay == nil, "solo: nothing is said to anyone and nothing waits")
-- a promotion right after another line to the party: it is not said yet, here or there, and it
-- is not queued either. The next XP after the gap tells it once, to the party only.
MOCK.inGroup = true
MOCK.sent = {}
CatXP.lastGroupSay, CatXP.pendingGroupSay, CatXP.lastAutoLine = nil, nil, nil
CatXP:GroupSay("CatXP: Tester takes the lead at 20.0k xp/h.")
CatXP.session.secs, CatXP.session.xp = 600, 600 * 31000 / 3600
CatXP.session.announcedTier, CatXP.session.bestTier = 1, 1
MOCK.prints = {}
CatXP:CheckTier(true)
check(not printsContain("Promoted to") and #MOCK.sent == 1 and CatXP.pendingGroupSay == nil and CatXP.session.announcedTier == 1,
  "a promotion right after another party line is held back, unsaid and unqueued, sent " .. #MOCK.sent)
MOCK.now = MOCK.now + 61   -- the clock moves, the session numbers stay as they are
CatXP:CheckTier(true)
check(#MOCK.sent == 2 and has(MOCK.sent[2].msg, "reached Jaguar") and not printsContain("Promoted to") and CatXP.pendingGroupSay == nil,
  "a minute later the next XP tells the party, and only the party, got " .. tostring(MOCK.sent[2] and MOCK.sent[2].msg))
MOCK.inGroup = false

io.write(string.format("test_catxp_v31: %d checks passed, %d failed\n", passes, #failures))
return #failures
