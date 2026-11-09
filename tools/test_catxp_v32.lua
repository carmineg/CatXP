-- Drives CatXP 3.2 through the mock WoW API: the chat pace (one automatic line per pace, said
-- once, and only when XP comes in) and the opt-in gold tracker (looted coin, quest coin and the
-- vendor price of what you pick up, per hour). ADDON_DIR is set by run_tests.py.
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
-- promotion and demotion lines printed in your own chat since the prints were last cleared
local function tierLines()
  local n = 0
  for _, p in ipairs(MOCK.prints) do
    if has(p, "Promoted to") or has(p, "Demoted to") then n = n + 1 end
  end
  return n
end
local function gain(xp)
  MOCK.xp = MOCK.xp + xp
  MOCK.fire("PLAYER_XP_UPDATE", "player")
end
local function gold() return CatXP:GetStats().gold end

local function loadAddon()
  local ns = {}
  for _, file in ipairs({ "Core.lua", "FactBank.lua", "Facts.lua", "Charts.lua", "Roster.lua", "UI.lua", "Graphs.lua", "Board.lua" }) do
    local chunk, err = loadfile(ADDON_DIR .. "/" .. file)
    assert(chunk, err)
    chunk("CatXP", ns)
  end
  return ns
end

-- 1. load + login: the new defaults ----------------------------------------------------------------
MOCK.level, MOCK.xp, MOCK.xpMax = 30, 0, 10000000   -- a bar long enough that nobody levels up here
MOCK.inGuild = true
local ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
MOCK.fire("PLAYER_ENTERING_WORLD", true, false)
check(CatXPDB.settings.chatPace == 5 and CatXP:PaceSecs() == 300 and CatXP:SettleSecs() == 300, "the chat pace is five minutes out of the box")
check(CatXPDB.settings.goldTrack == false and CatXP:GetStats().gold == nil, "gold tracking is off out of the box")

-- 2. a young session is not news --------------------------------------------------------------------
gain(500)
check(CatXP:IsRunning(), "first XP starts the session")
MOCK.advance(120)
MOCK.prints = {}
gain(500)                              -- 1000 xp in 120 s = 30.0k/h
check(CatXP.tierIndex == 13 and CatXP:GetStats().tier.name == "Leopard", "two minutes in, the window shows the cat")
check(tierLines() == 0 and CatXP.session.announcedTier == nil, "but chat hears nothing: the rate still jumps with every kill")
MOCK.advance(180)
gain(1500)                             -- 2500 xp in 300 s = 30.0k/h
check(tierLines() == 1 and printsContain("Promoted to") and printsContain("Leopard") and printsContain("Cat fact:"),
  "at five minutes the cat is announced, with its fact")

-- 3. inside one pace nothing more is said, whatever the rate does ---------------------------------------
MOCK.prints = {}
MOCK.advance(60);  gain(1200)          -- 360 s, 3700 xp = 37.0k/h: Nyan Cat
check(CatXP.tierIndex == 17 and tierLines() == 0, "a minute later you are a Nyan Cat on the window, and chat stays quiet")
MOCK.advance(60);  gain(10)            -- 420 s, 3710 xp = 31.8k/h: Jaguar
check(CatXP.tierIndex == 14 and tierLines() == 0, "down to Jaguar: quiet")
MOCK.advance(120); gain(790)           -- 540 s, 4500 xp = 30.0k/h: Leopard again
MOCK.advance(60);  gain(500)           -- 600 s, 5000 xp = 30.0k/h: still Leopard, and the pace is up
check(tierLines() == 0 and CatXP.session.announcedTier == 13 and CatXP.pendingGroupSay == nil,
  "three cats came and went inside one pace and you ended where you were: not a word, and nothing queued")
MOCK.advance(30);  gain(1000)          -- 630 s, 6000 xp = 34.3k/h
check(tierLines() == 1 and printsContain("Promoted to") and printsContain(CatXP.TIERS[16].name),
  "the next real change is told, once, now that the pace allows it")

-- 4. a rate that slides while you are away is told when you play again, not before -------------------------
MOCK.prints = {}
MOCK.advance(900)                      -- a quarter of an hour without XP: 6000 xp in 1530 s = 14.1k/h
check(CatXP.tierIndex == 4 and tierLines() == 0 and CatXP.session.announcedTier == 16,
  "twelve cats down the ladder while travelling: the window follows, chat says nothing")
gain(50)
check(tierLines() == 1 and printsContain("Demoted to") and printsContain(CatXP.TIERS[4].name),
  "the whole slide is one line, told when XP comes in again")
MOCK.advance(120)
gain(10)
check(tierLines() == 1, "and then it is quiet again")

-- 5. /catxp pace and the menu ------------------------------------------------------------------------------
MOCK.prints = {}
SlashCmdList.CATXP("pace")
check(printsContain("every 5 minutes"), "/catxp pace shows the pace")
SlashCmdList.CATXP("pace 10")
check(CatXPDB.settings.chatPace == 10 and CatXP:PaceSecs() == 600 and printsContain("every 10 minutes"), "/catxp pace 10 sets ten minutes")
check(CatXP:SettleSecs() == 300, "a session still counts as settled after five minutes, however long the pace")
SlashCmdList.CATXP("pace 0")
SlashCmdList.CATXP("pace 99")
SlashCmdList.CATXP("pace soon")
check(CatXPDB.settings.chatPace == 10, "values outside 1 to 60 change nothing")
SlashCmdList.CATXP("pace 1")
check(CatXPDB.settings.chatPace == 1 and CatXP:PaceSecs() == 60 and CatXP:SettleSecs() == 60 and printsContain("every minute"), "/catxp pace 1 is the old one-a-minute")
CatXPMainFrame:Click("RightButton")
local paces = MOCK.menuChildren("Chat pace")
check(MOCK.menuHas("Chat pace") and #paces == 7 and paces[1] == "One line every minute" and paces[7] == "One line every 30 minutes",
  "the menu has a chat pace submenu with seven choices")
check(MOCK.menuChecked("One line every minute") == true and MOCK.menuChecked("One line every 5 minutes") == false, "it shows the current pace")
MOCK.menuClick("One line every 5 minutes")
check(CatXPDB.settings.chatPace == 5 and MOCK.menuChecked("One line every 5 minutes") == true and MOCK.menuChecked("One line every minute") == false,
  "and picking one sets it")
MOCK.prints = {}
SlashCmdList.CATXP("help")
check(printsContain("/catxp pace") and printsContain("/catxp gold"), "help lists both new commands")

-- 6. in a party: one line, to the party, and a change of leader takes the same turn ------------------------
local FAST = "S,3,9000,600,22,30,0,MAGE,1,52000,2400,21,0,0,Westfall"      -- Jesse at 54.0k/h
local SLOW = "S,3,9000,1800,22,30,0,MAGE,1,52000,2400,21,0,0,Westfall"     -- Jesse at 18.0k/h
local MIA  = "S,3,20000,1200,30,30,0,ROGUE,1,0,0,0,0,0,Stranglethorn"       -- Mia at 60.0k/h
CatXP:Reset(true)
MOCK.inGroup = true
MOCK.sent, MOCK.prints = {}, {}
CatXP.lastAutoLine, CatXP.lastGroupSay = nil, nil
gain(500)
MOCK.advance(300)
gain(2000)                             -- 2500 xp in 300 s = 30.0k/h: Leopard
local toldAt = MOCK.now
check(#MOCK.sent == 1 and MOCK.sent[1].chan == "PARTY" and has(MOCK.sent[1].msg, "Tester reached Leopard") and has(MOCK.sent[1].msg, "Cat fact:"),
  "in a party the new cat goes to party chat, got " .. tostring(MOCK.sent[1] and MOCK.sent[1].msg))
check(tierLines() == 0, "and is not printed a second time in your own chat")

-- Jesse, in the party, is faster. Their own copy tells the party, so this one keeps quiet.
MOCK.receiveAddon(FAST, "PARTY", "Jesse-Realm")
ns.Board:CheckLead()
check(ns.Board.leader == "Jesse-Realm" and #MOCK.sent == 1 and not printsContain("takes the lead"),
  "a party member taking the lead is theirs to announce: no second line from you")

-- Ten seconds later Jesse has slowed down and the lead is yours, but the party has just heard from CatXP.
MOCK.advance(10)
MOCK.receiveAddon(SLOW, "PARTY", "Jesse-Realm")
ns.Board:CheckLead()
check(ns.Board:Rows()[1].isMe and ns.Board.leader == "Jesse-Realm" and #MOCK.sent == 1 and CatXP.pendingGroupSay == nil,
  "taking the lead waits for its turn: nothing sent, nothing queued")

-- Each step is a minute and 500 xp, which keeps you a Leopard, so the only news is the lead.
local leadAt
local function hold(minutes, others)
  for _ = 1, minutes do
    for _ = 1, 3 do
      MOCK.advance(20)
      for _, o in ipairs(others) do MOCK.receiveAddon(o[1], o[2], o[3]) end
      if not leadAt and #MOCK.sent >= 2 then leadAt = MOCK.now end
    end
    gain(500)
  end
end
hold(5, { { SLOW, "PARTY", "Jesse-Realm" } })
check(#MOCK.sent == 2 and has(MOCK.sent[2].msg, "Tester takes the lead from Jesse") and has(MOCK.sent[2].msg, "Cat fact:") and #MOCK.sent[2].msg <= 250,
  "one pace after the last line the party hears that you lead, got " .. tostring(MOCK.sent[2] and MOCK.sent[2].msg))
check(leadAt ~= nil and leadAt - toldAt >= 300 and leadAt - toldAt <= 330, "five minutes after the line before it, was " .. tostring(leadAt and (leadAt - toldAt)))
check(not printsContain("You take the lead") and tierLines() == 0 and ns.Board.leader == "Tester-Realm", "said once: your own chat does not repeat it")

-- Mia is in the guild, not in the party, and overtakes. Nobody else will tell you, so CatXP does: to you alone.
MOCK.prints = {}
MOCK.receiveAddon(MIA, "GUILD", "Mia-Realm")
ns.Board:CheckLead()
check(ns.Board:Rows()[1].name == "Mia" and ns.Board.leader == "Tester-Realm" and not printsContain("takes the lead"), "losing the lead waits for its turn too")
hold(5, { { SLOW, "PARTY", "Jesse-Realm" }, { MIA, "GUILD", "Mia-Realm" } })
check(printsContain("Mia takes the lead from you") and ns.Board.leader == "Mia-Realm", "a cat outside your group taking your lead is told in your own chat")
check(#MOCK.sent == 2, "and the party is left alone")

-- Two other cats trading places is not your news, even when the turn is free.
MOCK.prints = {}
CatXP.lastAutoLine, CatXP.lastGroupSay = nil, nil
MOCK.receiveAddon("S,3,40000,1800,22,30,0,MAGE,1,52000,2400,21,0,0,Westfall", "PARTY", "Jesse-Realm")   -- Jesse at 80.0k/h
ns.Board:CheckLead()
check(ns.Board.leader == "Jesse-Realm" and #MOCK.sent == 2 and not printsContain("takes the lead"), "two other cats trading places says nothing")
check(CatXP.lastAutoLine == nil, "and does not use up your turn")
MOCK.inGroup = false

-- 7. gold: off means off --------------------------------------------------------------------------------
-- A fresh account at level 60, where there is no XP left to earn.
MOCK.resetUI()
CatXPDB, CatXPCharDB = nil, nil
_G.CatXP = nil
MOCK.level, MOCK.xp, MOCK.xpMax = 60, 0, 0
MOCK.money = 123456
MOCK.sent, MOCK.addonSent = {}, {}
ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
MOCK.fire("PLAYER_ENTERING_WORLD", true, false)
check(CatXPDB.settings.goldTrack == false, "a new account starts with gold tracking off")
check(CatXPEvents.events.PLAYER_MONEY == nil and CatXPEvents.events.CHAT_MSG_LOOT == nil and CatXPEvents.events.MERCHANT_SHOW == nil,
  "off: the money, loot and vendor events are not even listened to")
check(not CatXPMainFrame.gold.label:IsShown() and not CatXPMainFrame.gold.rate:IsShown() and CatXPMainFrame:GetHeight() == 167,
  "off: no gold row, the window is its usual size")
MOCK.gainMoney(500)
check(not CatXP:IsRunning() and CatXP.session.gold == nil and gold() == nil, "off: coin is ignored")
MOCK.prints = {}
SlashCmdList.CATXP("status")
check(not printsContain("Gold:"), "off: /catxp status does not mention gold")

-- 8. turning it on ------------------------------------------------------------------------------------------
MOCK.prints = {}
SlashCmdList.CATXP("gold")
check(CatXPDB.settings.goldTrack == true and printsContain("Gold tracking on"), "/catxp gold turns it on")
check(CatXPEvents.events.PLAYER_MONEY and CatXPEvents.events.CHAT_MSG_LOOT and CatXPEvents.events.QUEST_TURNED_IN
  and CatXPEvents.events.GET_ITEM_INFO_RECEIVED and CatXPEvents.events.MERCHANT_SHOW and CatXPEvents.events.AUCTION_HOUSE_CLOSED,
  "on: now the events are listened to")
local g = gold()
check(g and g.total == 0 and g.rate == 0 and not g.ready and #g.windows == 5, "the purse you already had is not income")
check(CatXPMainFrame.gold.label:IsShown() and CatXPMainFrame:GetHeight() == 181 and CatXPMainFrame.gold.label.y == -137 and CatXPMainFrame.btnStart.y == -159,
  "the main window grows by one row, under the rate windows")

-- 9. looted coin; and coin starts the clock, which is what makes this usable at level 60 --------------------
MOCK.prints = {}
MOCK.gainMoney(250)
check(CatXP:IsRunning() and printsContain("Gold spotted"), "the first coin starts the session when auto-start is on")
g = gold()
check(g.loot == 250 and g.total == 250 and g.quest == 0 and g.items == 0, "looted coin is counted")
check(CatXP:GetStats().atMax and has(CatXPMainFrame.gold.total:GetText(), "2s"), "it works at the level cap and shows on the window")
MOCK.gainMoney(-100)                   -- a repair bill, say
MOCK.gainMoney(40)
g = gold()
check(g.loot == 290 and g.total == 290, "spending is ignored: this is income, not the change in your purse")

-- 10. quest coin, whichever way round the game reports it ------------------------------------------------
MOCK.advance(5)
MOCK.fire("QUEST_TURNED_IN", 101, 0, 1000)
MOCK.gainMoney(1000)
g = gold()
check(g.quest == 1000 and g.loot == 290, "coin right after a turn-in is quest coin")
MOCK.advance(5)
MOCK.gainMoney(700)
check(gold().loot == 990, "coin with no turn-in in sight is loot for now")
MOCK.fire("QUEST_TURNED_IN", 102, 0, 700)
g = gold()
check(g.quest == 1700 and g.loot == 290 and g.total == 1990, "when the turn-in event follows a moment later, that coin is moved to quest coin")
MOCK.advance(5)
MOCK.gainMoney(60)
g = gold()
check(g.loot == 350 and g.quest == 1700 and g.total == 2050, "later coin is loot again")

-- 11. the vendor price of what you pick up ---------------------------------------------------------------
MOCK.items[2589] = { name = "Linen Cloth", price = 13 }
MOCK.items[4306] = { name = "Silk Cloth", price = 150 }
MOCK.items[9001] = { name = "Recruit's Blade", price = 2500 }
MOCK.items[9002] = { name = "Sealed Orders", price = 0 }
MOCK.loot(2589, 3)
check(gold().items == 39, "a stack counts at vendor price times its size, got " .. tostring(gold().items))
MOCK.loot(4306)
MOCK.loot(9001, 1, "item")             -- a quest reward arrives as "You receive item"
check(gold().items == 39 + 150 + 2500, "single items and quest reward items count too, got " .. tostring(gold().items))
MOCK.loot(4306, 2, "Jesse")            -- somebody else's loot
MOCK.loot(4306, 1, "create")           -- something you crafted
MOCK.loot(9002)                        -- nothing a vendor would pay for
MOCK.fire("CHAT_MSG_LOOT", "You receive loot: a strange feeling.")
MOCK.fire("CHAT_MSG_LOOT", nil)
check(gold().items == 2689, "other players' loot, crafted items, unsellable items and odd lines are left out, got " .. tostring(gold().items))
check(gold().total == 2050 + 2689, "the total is coin plus quest coin plus item value")

-- 12. vendors, the mailbox, the auction house and trades are not income --------------------------------------
local before = gold().total
for _, shop in ipairs({ "MERCHANT", "MAIL", "TRADE", "AUCTION_HOUSE" }) do
  MOCK.fire(shop .. "_SHOW")
  MOCK.gainMoney(5000)                 -- sold, collected or traded
  MOCK.loot(4306, 5, "item")           -- bought, or taken out of the mail
  MOCK.gainMoney(-300)
  MOCK.fire(shop .. "_CLOSED")
  MOCK.gainMoney(77)                   -- the last of it lands as the window closes
  MOCK.advance(3)
end
check(gold().total == before, "nothing that happens at a vendor, mailbox, auction house or trade is counted, got " .. tostring(gold().total - before))
MOCK.gainMoney(10)
check(gold().total == before + 10 and gold().loot == 360, "the purse is re-read all along, so the next coin counts exactly")

-- 13. an item the client has not loaded yet ----------------------------------------------------------------
MOCK.items[7777] = { name = "Mystery Gem", price = 400, cached = false }
before = gold().items
MOCK.loot(7777, 2)
check(gold().items == before and #CatXP.goldPending == 1, "its price is not known yet, so it waits")
MOCK.items[7777].cached = true
MOCK.fire("GET_ITEM_INFO_RECEIVED", 7777, true)
check(gold().items == before + 800 and #CatXP.goldPending == 0, "it is counted as soon as the client has it")
MOCK.items[8888] = { name = "Ghost Item", price = 999, cached = false }
MOCK.loot(8888)
MOCK.advance(35)
check(#CatXP.goldPending == 0 and gold().items == before + 800, "an item that never loads is dropped after half a minute")

-- 14. the rate, on gold's own clock ------------------------------------------------------------------------
local todayBefore = gold().windows[5].gold
CatXP:Reset(true)
check(gold().total == 0 and gold().secs == 0, "a reset starts the gold count afresh")
MOCK.gainMoney(400)
MOCK.advance(600)
MOCK.gainMoney(600)
g = gold()
check(g.total == 1000 and near(g.secs, 600) and near(g.rate, 6000) and g.ready, "1000 copper in ten minutes is 60 silver an hour, got " .. tostring(g.rate))
check(g.windows[3].key == "session" and g.windows[3].gold == 1000 and near(g.windows[3].rate, 6000), "the session window says the same")
check(g.windows[1].key == "recent" and g.windows[1].gold == 1000 and near(g.windows[1].rate, 6000), "so does the last 15 minutes, this early on")
check(g.windows[5].key == "today" and g.windows[5].gold == todayBefore + 1000 and g.windows[5].secs > 600, "today keeps adding up across resets")
check(g.windows[4].key == "level" and g.windows[4].gold == todayBefore + 1000, "and so does the level you are on")
SlashCmdList.CATXP("gold")             -- off for five minutes
check(gold() == nil and not CatXPMainFrame.gold.label:IsShown() and CatXPMainFrame:GetHeight() == 167 and CatXPEvents.events.PLAYER_MONEY == nil,
  "/catxp gold again turns it off: the row goes and the events are dropped")
MOCK.gainMoney(99999)
MOCK.advance(300)
SlashCmdList.CATXP("gold on")
g = gold()
check(g.total == 1000 and near(g.secs, 600) and near(CatXP.session.secs, 900), "coin and time while it was off are not counted, and what was counted is kept")
MOCK.gainMoney(500)
g = gold()
check(g.total == 1500 and near(g.rate, 1500 / 600 * 3600), "the rate uses only the time gold was being counted, got " .. tostring(g.rate))
SlashCmdList.CATXP("gold on")
check(CatXPDB.settings.goldTrack == true, "/catxp gold on leaves it on")

-- 15. where it shows ------------------------------------------------------------------------------------------
check(ns.fmtMoney(124050, true) == "12g 40s" and ns.fmtMoney(4012, true) == "40s 12c" and ns.fmtMoney(7, true) == "7c"
  and ns.fmtMoney(0, true) == "0c" and ns.fmtMoney(12345678, true) == "1,234g 56s" and ns.fmtMoney(10000, true) == "1g 00s",
  "coins are written the way the game writes them, got " .. ns.fmtMoney(124050, true) .. " / " .. ns.fmtMoney(4012, true) .. " / " .. ns.fmtMoney(12345678, true))
check(has(ns.fmtMoney(124050), "|cffffd100") and not has(ns.fmtMoney(124050, true), "|"), "coloured on screen, plain on request")
local row = CatXPMainFrame.gold
check(has(row.total:GetText(), "15s") and has(row.rate:GetText(), "/h") and row.time:GetText() == ns.fmtTime(600),
  "main window row: counted time, coin earned, coin per hour, got " .. tostring(row.time:GetText()) .. " / " .. tostring(row.total:GetText()))
SlashCmdList.CATXP("windows")
check(CatXPMainFrame:GetHeight() == 108 and row.label:IsShown() and row.label.y == -72 and CatXPMainFrame.btnStart.y == -86 and CatXPMainFrame.sep:IsShown()
  and not CatXPMainFrame.windows[1].label:IsShown(), "with the rate windows hidden the gold row moves up under the status lines")
SlashCmdList.CATXP("windows")
check(CatXPMainFrame:GetHeight() == 181 and row.label.y == -137, "and back down when they return")
CatXPMainFrame:Enter()
local tip = table.concat(GameTooltip.lines, "\n")
check(has(tip, "Gold / hour") and has(tip, "Gold earned") and has(tip, "Coin / quests / items") and has(tip, "Gold today"), "the tooltip has the gold lines")
if not CatXPDetailsFrame:IsShown() then ns.ToggleDetails() end
local D = CatXPDetailsFrame
check(D:GetHeight() == 570 and D.goldRows.sources:IsShown() and has(D.goldRows.rate:GetText(), "/h") and has(D.goldRows.rate:GetText(), "15s"),
  "the details panel grows and shows the gold block, got " .. tostring(D.goldRows.rate:GetText()))
MOCK.prints = {}
SlashCmdList.CATXP("status")
check(printsContain("Gold:") and printsContain("quests") and printsContain("items"), "/catxp status reports gold and its three sources")
CatXPMainFrame:Click("RightButton")
check(MOCK.menuChecked("Track gold per hour") == true, "the menu has a gold checkbox, ticked")
MOCK.menuClick("Track gold per hour")
check(CatXPDB.settings.goldTrack == false and D:GetHeight() == 494 and not D.goldRows.sources:IsShown() and MOCK.menuChecked("Track gold per hour") == false,
  "unticking it turns gold off and the details panel shrinks back")
CatXPMainFrame:Enter()
check(not has(table.concat(GameTooltip.lines, "\n"), "Gold"), "off: the tooltip has no gold lines")
MOCK.menuClick("Track gold per hour")
check(CatXPDB.settings.goldTrack == true and gold().total == 1500 and D:GetHeight() == 570, "ticking it again brings it back with the session's count intact")

-- 16. a pause is a pause; gold stays on your own screen --------------------------------------------------------
before = gold().total
CatXP:Pause("silent")
MOCK.gainMoney(300)
MOCK.loot(4306)
MOCK.items[6666] = { name = "Late Gem", price = 5000, cached = false }
MOCK.loot(6666)                        -- its price would only turn up after you start again
check(#CatXP.goldPending == 0, "an item picked up during a pause is not kept waiting for its price")
check(not CatXP:IsRunning() and gold().total == before, "coin and loot while you have paused the session are not counted and do not restart it")
MOCK.fire("QUEST_TURNED_IN", 103, 0, 300)
check(gold().quest == 0 and gold().total == before, "and a turn-in then has nothing to move")
CatXP:Start("silent")
MOCK.gainMoney(5)
check(gold().total == before + 5, "counting carries on when you start again")
MOCK.addonSent = {}
ns.Board:Broadcast(true)
local state
for _, m in ipairs(MOCK.addonSent) do if m.msg:sub(1, 2) == "S," then state = m.msg end end
check(state ~= nil and select(2, state:gsub(",", "")) == 15, "the leaderboard message is the same sixteen fields: gold is not shared, got " .. tostring(state))
check(#MOCK.sent == 0, "and no gold line ever goes to chat")

-- 17. history and reloads --------------------------------------------------------------------------------------
local total = gold().total
CatXP:Reset(true)
local hist = CatXPCharDB.history
check(#hist >= 1 and hist[#hist].gold == total and near(hist[#hist].goldSecs, 600), "the archived session remembers its gold and its gold time")
MOCK.gainMoney(250)
local savedDB, savedChar = MOCK.deepcopy(CatXPDB), MOCK.deepcopy(CatXPCharDB)
MOCK.resetUI()
CatXPDB, CatXPCharDB = savedDB, savedChar
_G.CatXP = nil
ns = loadAddon()
MOCK.fire("ADDON_LOADED", "CatXP")
MOCK.money = MOCK.money + 5000         -- the purse changed while the addon was not looking
MOCK.fire("PLAYER_ENTERING_WORLD", false, true)
check(CatXPDB.settings.goldTrack == true and CatXPDB.settings.chatPace == 5 and CatXPEvents.events.PLAYER_MONEY and CatXPMainFrame.gold.label:IsShown()
  and CatXPMainFrame:GetHeight() == 181, "the settings, the events and the row survive a reload")
check(gold().total == 250, "so does the session's gold, and the purse is read afresh so nothing is invented, got " .. tostring(gold().total))
MOCK.gainMoney(20)
check(gold().total == 270, "and counting carries on")

-- 18. values the game will not let an addon read are skipped, never an error ----------------------------------
MOCK.secretTest = function(v) return type(v) == "string" and v:find("Hitem", 1, true) ~= nil end
MOCK.loot(4306)
MOCK.secretTest = function(v) return type(v) == "number" and v == MOCK.money end
MOCK.gainMoney(40)
check(gold().total == 270, "secret loot text and a secret purse are passed over")
MOCK.secretTest = nil
MOCK.gainMoney(1)
check(gold().total == 311, "and once the purse can be read again, what came in meanwhile is counted")
-- an old client without the item API at all
local savedItem, savedGet = C_Item, GetItemInfo
C_Item, GetItemInfo = nil, nil
MOCK.loot(4306)
C_Item, GetItemInfo = savedItem, savedGet
check(gold().total == 311 and #(CatXP.goldPending or {}) == 0, "no item API: items are simply worth nothing")
check(not printsContain("error") and not printsContain("Error"), "nothing in chat complains")

io.write(string.format("test_catxp_v32: %d checks passed, %d failed\n", passes, #failures))
if #failures > 0 then for _, p in ipairs(MOCK.prints) do io.write("  > ", p, "\n") end end
io.flush()
return #failures
