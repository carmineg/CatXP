--[[-------------------------------------------------------------------------
  CatXP leaderboard data. Who else is running CatXP nearby (party, raid or
  guild) and their live numbers, all-time records for you, your alts and the
  cats you have met, and races. Board.lua
  draws all of it.

  Cats talk to each other over addon messages with the prefix "CatXP":
    S,3,xp,secs,level,kills,levelUps,class,running,bestRate,bestLevelSecs,bestLevel,raceId,raceXP,zone,token
    Q,3,token                     who is there? everyone answers with an S
    R,3,start,raceId,minutes,startedAt,token   /  R,3,end,raceId,token
  The token is a random tag made once per login. Your own messages come back to you on the
  group channel, and the game can show your name differently from what UnitName returns
  (Forever: "Meow Thecat" in chat, "Meow" from UnitName), so the token, not the name, is how a
  cat recognises its own echo. Older copies simply ignore the extra field.
---------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...
local CatXP = ns.CatXP

local PREFIX = "CatXP"
local PROTOCOL = 3
local BROADCAST_EVERY = 20        -- seconds between state messages while tracking
local RACE_BROADCAST_EVERY = 10   -- faster while a race is on
local STALE_AFTER = 90            -- seconds of silence before a cat leaves the live board
local FORGET_AFTER = 360          -- seconds of silence before a cat is forgotten entirely
local MIN_RECORD_SECS = 1800      -- a session rate needs 30 minutes to count as a record
local LEAD_GAP = 60               -- seconds between lead-change messages
local QUERY_GAP = 10              -- seconds between who-is-there queries
local SAMPLE_KEEP = 120           -- rate samples kept per cat for the five-minute trend
local SAMPLE_AGE = 400            -- and no older than this many seconds

local Board = { roster = {}, samples = {}, lastSend = 0, lastQuery = 0, lastLeadAt = 0 }
ns.Board = Board

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function safeString(v)
  if type(v) ~= "string" or ns.isSecret(v) or v == "" then return nil end
  return v
end

local function split(text)
  local out = {}
  for piece in string.gmatch(text .. ",", "([^,]*),") do out[#out + 1] = piece end
  return out
end

-- a random tag of letters and digits, so a message can be recognised as our own
local function newToken()
  local chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  local t = {}
  for i = 1, 6 do
    local k = math.random(#chars)
    t[i] = chars:sub(k, k)
  end
  t[#t + 1] = tostring(math.random(10, 99))   -- always ends in digits, so no zone name can look like one
  return table.concat(t)
end

function Board.ClassColor(class)
  local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
  if c then
    local hex = c.colorStr and c.colorStr:sub(3) or string.format("%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
    return c.r, c.g, c.b, hex
  end
  return 1, 1, 1, "ffffff"
end

function Board:Identity()
  if self.me then return self.me end
  local name = safeString(UnitName and UnitName("player")) or "You"
  local realm = safeString(GetNormalizedRealmName and GetNormalizedRealmName())
    or safeString(GetRealmName and GetRealmName()) or ""
  realm = realm:gsub("%s+", "")
  local class
  if UnitClass then class = select(2, UnitClass("player")) end
  class = safeString(class) or "WARRIOR"
  local me = { name = name, realm = realm, class = class, key = realm ~= "" and (name .. "-" .. realm) or name }
  if name ~= "You" and realm ~= "" then self.me = me end   -- cache once the client knows who we are
  return me
end

function Board:IsMe(sender)
  local me = self:Identity()
  if sender == me.key then return true end
  local name, realm = sender:match("^([^%-]+)%-?(.*)$")
  return name == me.name and (realm == "" or me.realm == "" or realm == me.realm)
end

-- the name the game shows for us, once our own echo has taught it to us; else what UnitName says
function Board:MyName()
  return self.fullName or self:Identity().name
end

---------------------------------------------------------------------------
-- setup and talking
---------------------------------------------------------------------------
function Board:Init()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX) end
  CatXPDB.board = CatXPDB.board or {}
  self.db = CatXPDB.board
  self.db.records = self.db.records or {}
  self.token = self.token or newToken()
  if not self.heartbeat and C_Timer and C_Timer.NewTicker then
    self.heartbeat = C_Timer.NewTicker(5, function() Board:Heartbeat() end)
  end
end

function Board:OnEnteringWorld()
  self.me = nil
  self:PurgeSelfRecords()
  self:Query()
end

function Board:Channels()
  local S = CatXP.settings
  local list = {}
  if S.shareGroup then
    local ch = ns.GroupChannel()
    if ch then list[#list + 1] = ch end
  end
  if S.shareGuild and IsInGuild and IsInGuild() then list[#list + 1] = "GUILD" end
  return list
end

function Board:Send(msg)
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false end
  local sent = false
  for _, ch in ipairs(self:Channels()) do
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, ch)
    sent = true
  end
  return sent
end

function Board:StateMessage()
  local s = CatXP.session
  local me = self:Identity()
  local rec = self:MyRecord()
  local raceId, raceXP = 0, 0
  if self.race and self.race.active then raceId, raceXP = self.race.id, self:MyRaceXP() end
  local zone = tostring(CatXP.zone or ""):gsub("[,|]", " ")
  return table.concat({
    "S", PROTOCOL, math.floor(s.xp or 0), math.floor(s.secs or 0), CatXP.lastLevel or 0,
    s.kills or 0, s.levelUps or 0, me.class, CatXP:IsRunning() and 1 or 0,
    math.floor(rec.bestRate or 0), math.floor(rec.bestLevelSecs or 0), rec.bestLevel or 0,
    raceId, math.floor(raceXP), zone, self.token or "",
  }, ",")
end

function Board:Broadcast(force)
  local now = GetTime()
  local every = (self.race and self.race.active) and RACE_BROADCAST_EVERY or BROADCAST_EVERY
  if not force and now - self.lastSend < every then return end
  if not force and not CatXP:IsRunning() and (CatXP.session.secs or 0) <= 0 then return end
  if self:Send(self:StateMessage()) then self.lastSend = now end
end

function Board:Query()
  local now = GetTime()
  if now - self.lastQuery < QUERY_GAP then return end
  self.lastQuery = now
  self:Send("Q," .. PROTOCOL .. "," .. (self.token or ""))
end

---------------------------------------------------------------------------
-- listening
---------------------------------------------------------------------------
function Board:OnAddonMessage(prefix, text, channel, sender)
  if prefix ~= PREFIX then return end
  text, sender = safeString(text), safeString(sender)
  if not text or not sender then return end
  local f = split(text)
  local proto = tonumber(f[2])
  if not proto or proto < PROTOCOL then return end
  if self.token and f[#f] == self.token then   -- our own message, back from the channel
    self:OnOwnEcho(sender)
    return
  end
  if self:IsMe(sender) then return end
  if f[1] == "S" then
    self:OnState(f, channel, sender)
  elseif f[1] == "Q" then
    if GetTime() - self.lastSend > 3 then self:Broadcast(true) end
  elseif f[1] == "R" then
    self:OnRace(f, sender)
  end
end

-- Our own message came back. It tells us the name the game uses for us in chat, which can be
-- longer than UnitName gives. Anything an older copy filed under that name was really us.
function Board:OnOwnEcho(sender)
  local name = sender:match("^([^%-]+)") or sender
  local me = self:Identity()
  if name ~= me.name then self.fullName = name end
  if sender ~= me.key then
    self.roster[sender] = nil
    self.samples[sender] = nil
    local r = self.db.records[sender]
    if r and not r.isMe then self.db.records[sender] = nil end
  end
end

-- Records an older copy kept about us as if we were someone else: same first name, same class,
-- same realm. A real stranger who matches all three only loses a record that comes back with
-- their next update.
function Board:PurgeSelfRecords()
  local me = self:Identity()
  if me.name == "You" or not self.db then return end
  for key, r in pairs(self.db.records) do
    if key ~= me.key and not r.isMe and type(r.name) == "string" then
      local first = r.name:match("^(%S+)")
      local sameRealm = (r.realm or "") == "" or me.realm == "" or r.realm == me.realm
      if first == me.name and (r.class == nil or r.class == me.class) and sameRealm then
        self.db.records[key] = nil
      end
    end
  end
end

function Board:OnState(f, channel, sender)
  local name, realm = sender:match("^([^%-]+)%-?(.*)$")
  local e = self.roster[sender] or { key = sender, name = name or sender, realm = realm or "", channels = {} }
  e.xp = tonumber(f[3]) or 0
  e.secs = tonumber(f[4]) or 0
  e.level = tonumber(f[5]) or 0
  e.kills = tonumber(f[6]) or 0
  e.levelUps = tonumber(f[7]) or 0
  e.class = (f[8] ~= "" and f[8]) or e.class
  e.running = f[9] == "1"
  e.bestRate = tonumber(f[10]) or 0
  e.bestLevelSecs = tonumber(f[11]) or 0
  e.bestLevel = tonumber(f[12]) or 0
  e.raceId = tonumber(f[13]) or 0
  e.raceXP = tonumber(f[14]) or 0
  e.zone = (f[15] and f[15] ~= "") and f[15] or nil
  e.rate = e.secs > 0 and (e.xp / e.secs * 3600) or 0
  e.lastSeen = GetTime()
  e.channels[channel or "?"] = GetTime()
  self.roster[sender] = e
  self:Sample(sender, e.secs >= CatXP.WARMUP_SECS and e.rate or 0)
  self:NoteFriendRecord(e)
  self:CheckLead()
  if ns.RefreshBoard then ns.RefreshBoard() end
end

---------------------------------------------------------------------------
-- trend samples (rate five minutes ago)
---------------------------------------------------------------------------
function Board:Sample(key, rate)
  local list = self.samples[key] or {}
  local now = GetTime()
  list[#list + 1] = { t = now, rate = rate }
  while #list > SAMPLE_KEEP or (list[1] and now - list[1].t > SAMPLE_AGE) do table.remove(list, 1) end
  self.samples[key] = list
end

function Board:Trend(key, rate)
  local list = self.samples[key]
  if not list then return nil end
  local now = GetTime()
  for i = #list, 1, -1 do
    if now - list[i].t >= 300 then return rate - list[i].rate end
  end
  return nil
end

---------------------------------------------------------------------------
-- live rows
---------------------------------------------------------------------------
function Board:Rows()
  local now = GetTime()
  local st = CatXP:GetStats()
  local me = self:Identity()
  local rows = {}
  rows[#rows + 1] = {
    key = me.key, name = self:MyName(), class = me.class, level = st.level, isMe = true, source = "you",
    rate = st.warming and 0 or st.rate, warming = st.warming and st.secs > 0, xp = st.xp, secs = st.secs,
    kills = st.kills, levelUps = st.levelUps, running = st.running, zone = st.zone,
    bestRate = self:MyRecord().bestRate or 0, trend = self:Trend(me.key, st.rate),
  }
  for key, e in pairs(self.roster) do
    if now - (e.lastSeen or 0) <= STALE_AFTER then
      local group, guild = false, false
      for ch, t in pairs(e.channels) do
        if now - t <= STALE_AFTER then
          if ch == "GUILD" then guild = true else group = true end
        end
      end
      local warming = e.secs < CatXP.WARMUP_SECS
      rows[#rows + 1] = {
        key = key, name = e.name, class = e.class, level = e.level, isMe = false,
        source = (group and guild) and "party+guild" or (group and "party" or "guild"),
        rate = warming and 0 or e.rate, warming = warming, xp = e.xp, secs = e.secs,
        kills = e.kills, levelUps = e.levelUps, running = e.running, zone = e.zone,
        bestRate = e.bestRate or 0, trend = self:Trend(key, e.rate), lastSeen = e.lastSeen,
      }
    end
  end
  table.sort(rows, function(a, b)
    if a.rate ~= b.rate then return a.rate > b.rate end
    if a.xp ~= b.xp then return a.xp > b.xp end
    return a.name < b.name
  end)
  for i, r in ipairs(rows) do
    r.rank = i
    r.tier = CatXP:TierFor(r.rate)
  end
  return rows
end

function Board:OnlineCount()
  local now, n = GetTime(), 0
  for _, e in pairs(self.roster) do
    if now - (e.lastSeen or 0) <= STALE_AFTER then n = n + 1 end
  end
  return n
end

---------------------------------------------------------------------------
-- lead changes
---------------------------------------------------------------------------
function Board:CheckLead()
  local S = CatXP.settings
  if not S.leadAnnounce then return end
  local rows = self:Rows()
  local top = rows[1]
  if not top or #rows < 2 or top.rate <= 0 then
    self.leader = (top and top.rate > 0) and top.key or nil   -- alone, or nobody has a rate yet
    return
  end
  local previous = self.leader
  if not previous or previous == top.key then
    self.leader = top.key
    return
  end
  local now = GetTime()
  -- too soon after the last message: keep the old leader and look again on the next heartbeat,
  -- so a lead that flips straight back is never announced
  if now - (self.lastLeadAt or 0) < LEAD_GAP then return end
  self.lastLeadAt = now
  self.leader = top.key
  local prevRow
  for _, r in ipairs(rows) do if r.key == previous then prevRow = r end end
  local from = prevRow and (" from " .. prevRow.name) or ""
  local factLine = ns.FactLine and ns.FactLine(top.tier) or ""
  if top.isMe then
    CatXP:Print(ns.color("ffcc66", "You take the lead") .. from .. " at " .. ns.fmtShort(top.rate) .. " xp/h. Keep the paws moving." .. factLine)
    if S.partyAnnounce then   -- shares the one-a-minute gate with the tier lines
      CatXP:GroupSay(string.format("CatXP: %s takes the lead%s at %s xp/h.%s", top.name, from, ns.fmtShort(top.rate), factLine))
    end
  elseif previous == self:Identity().key then
    CatXP:Print(string.format("%s takes the lead from you at %s xp/h. Unacceptable.%s", top.name, ns.fmtShort(top.rate), factLine))
  end
end

---------------------------------------------------------------------------
-- records
---------------------------------------------------------------------------
function Board:Record(key, create)
  local r = self.db.records[key]
  if not r and create then
    r = { sessions = 0 }
    self.db.records[key] = r
  end
  return r
end

function Board:MyRecord()
  local me = self:Identity()
  local r = self:Record(me.key, true)
  r.name, r.realm, r.class, r.isMe = self:MyName(), me.realm, me.class, true
  return r
end

-- called by Core when a session is archived
function Board:NoteSession(h)
  local r = self:MyRecord()
  r.sessions = (r.sessions or 0) + 1
  r.lastSeen = time()
  if (h.secs or 0) >= MIN_RECORD_SECS then
    local rate = h.xp / h.secs * 3600
    if rate > (r.bestRate or 0) then r.bestRate, r.bestRateSecs, r.bestRateAt = rate, h.secs, h.endedAt end
  end
  if (h.xp or 0) > (r.bestXP or 0) then r.bestXP, r.bestXPAt = h.xp, h.endedAt end
  if (h.secs or 0) > (r.longest or 0) then r.longest = h.secs end
end

-- called by Core when a level is finished; only levels tracked from their first XP count
function Board:NoteLevel(level, rec)
  if not rec.full or (rec.secs or 0) <= 0 then return end
  local r = self:MyRecord()
  if not r.bestLevelSecs or rec.secs < r.bestLevelSecs then
    r.bestLevelSecs, r.bestLevel, r.bestLevelAt = rec.secs, level, time()
  end
end

function Board:NoteFriendRecord(e)
  local r = self:Record(e.key, true)
  r.name, r.realm, r.class = e.name, e.realm, e.class or r.class
  r.lastSeen = time()
  if (e.bestRate or 0) > (r.bestRate or 0) then r.bestRate = e.bestRate end
  if (e.bestLevelSecs or 0) > 0 and (not r.bestLevelSecs or e.bestLevelSecs < r.bestLevelSecs) then
    r.bestLevelSecs, r.bestLevel = e.bestLevelSecs, e.bestLevel
  end
  if (e.xp or 0) > (r.bestXP or 0) then r.bestXP = e.xp end
  if (e.secs or 0) > (r.longest or 0) then r.longest = e.secs end
end

function Board:RecordRows()
  local rows = {}
  local me = self:Identity()
  for key, r in pairs(self.db.records) do
    rows[#rows + 1] = {
      key = key, name = r.name or key, class = r.class, isMe = (key == me.key), mine = r.isMe,
      bestRate = r.bestRate or 0, bestRateSecs = r.bestRateSecs, bestRateAt = r.bestRateAt,
      bestXP = r.bestXP or 0, bestLevel = r.bestLevel, bestLevelSecs = r.bestLevelSecs,
      longest = r.longest or 0, sessions = r.sessions or 0, lastSeen = r.lastSeen,
    }
  end
  table.sort(rows, function(a, b)
    if a.bestRate ~= b.bestRate then return a.bestRate > b.bestRate end
    if a.bestXP ~= b.bestXP then return a.bestXP > b.bestXP end
    return a.name < b.name
  end)
  for i, r in ipairs(rows) do r.rank = i end
  return rows
end

function Board:ClearRecords()
  self.db.records = {}
  self.db.lastRace = nil
  CatXP:Print("Leaderboard records cleared. Every cat starts over.")
  if ns.RefreshBoard then ns.RefreshBoard(true) end
end

---------------------------------------------------------------------------
-- races: most XP in a fixed number of minutes
---------------------------------------------------------------------------
local function serverNow()
  return (GetServerTime and GetServerTime()) or time()
end

function Board:MyRaceXP()
  local race = self.race
  if not race then return 0 end
  local xp = CatXP.session.xp or 0
  if xp < race.baseXP then race.baseXP = 0 end   -- the session was reset mid-race: count from there
  return xp - race.baseXP
end

function Board:StartRace(minutes, remote)
  minutes = math.floor(tonumber(minutes) or 30)
  if minutes < 1 then minutes = 1 elseif minutes > 240 then minutes = 240 end
  if self.race and self.race.active then
    if remote then return end
    CatXP:Print("A race is already running. /catxp race stop ends it.")
    return
  end
  if not CatXP:IsRunning() then CatXP:Start("silent") end
  local startedAt = (remote and remote.startedAt) or serverNow()
  self.race = {
    id = (remote and remote.id) or startedAt, minutes = minutes, startedAt = startedAt, endsAt = startedAt + minutes * 60,
    starter = (remote and remote.starter) or self:MyName(), mine = not remote, active = true,
    baseXP = CatXP.session.xp or 0,
  }
  local factLine = ns.FactLine and ns.FactLine(nil) or ""
  if remote then
    CatXP:Print(string.format("%s started a %d-minute CatXP race. Most XP wins. Go!%s", self.race.starter, minutes, factLine))
  else
    self:Send(table.concat({ "R", PROTOCOL, "start", self.race.id, minutes, startedAt, self.token or "" }, ","))
    CatXP:Print(string.format("Race started: %d minutes, most XP wins. Go!%s", minutes, factLine))
    CatXP:GroupSay(string.format("CatXP race: %d minutes, most XP wins. Go!%s", minutes, factLine), true)
  end
  self:Broadcast(true)
  if ns.RefreshBoard then ns.RefreshBoard(true) end
end

function Board:RaceLeft()
  local race = self.race
  if not race or not race.active then return 0 end
  return math.max(0, race.endsAt - serverNow())
end

function Board:RaceRows()
  local race = self.race
  if not race then return {} end
  local me = self:Identity()
  local rows = { { key = me.key, name = self:MyName(), class = me.class, xp = self:MyRaceXP(), isMe = true } }
  for key, e in pairs(self.roster) do
    if e.raceId == race.id then
      rows[#rows + 1] = { key = key, name = e.name, class = e.class, xp = e.raceXP or 0 }
    end
  end
  table.sort(rows, function(a, b)
    if a.xp ~= b.xp then return a.xp > b.xp end
    return a.name < b.name
  end)
  for i, r in ipairs(rows) do r.rank = i end
  return rows
end

function Board:FinishRace(cancelled, byName)
  local race = self.race
  if not race or not race.active then return end
  race.active = false
  local rows = self:RaceRows()
  race.results = rows
  if cancelled then
    race.cancelled = true   -- shown on the Race tab until the next race; never saved as a result
    CatXP:Print(byName and (byName .. " called off the race.") or "Race called off.")
    if not byName then self:Send(table.concat({ "R", PROTOCOL, "end", race.id, self.token or "" }, ",")) end
  else
    self.db.lastRace = { minutes = race.minutes, startedAt = race.startedAt, endedAt = time(), starter = race.starter, results = {} }
    for i, r in ipairs(rows) do
      self.db.lastRace.results[i] = { name = r.name, class = r.class, xp = math.floor(r.xp), isMe = r.isMe }
    end
    local parts = {}
    for i, r in ipairs(rows) do
      if i > 5 then break end
      parts[#parts + 1] = string.format("%d. %s %s xp", i, r.name, ns.fmtShort(r.xp))
    end
    local line = "Race over! " .. table.concat(parts, "  ")
    local factLine = ns.FactLine and ns.FactLine(nil) or ""
    CatXP:Print(line .. ((rows[1] and rows[1].isMe) and "  Top cat!" or "") .. factLine)
    if race.mine then
      local msg = "CatXP " .. line
      if #msg + #factLine <= 250 then msg = msg .. factLine end   -- the results come first, the fact if it fits
      CatXP:GroupSay(msg, true)
    end
  end
  if ns.RefreshBoard then ns.RefreshBoard(true) end
end

function Board:CancelRace()
  if self.race and self.race.active then
    self:FinishRace(true)
  else
    CatXP:Print("No race running.")
  end
end

function Board:OnRace(f, sender)
  local action = f[3]
  local name = sender:match("^([^%-]+)") or sender
  if action == "start" then
    local id, minutes, startedAt = tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
    if not id or not minutes then return end
    self:StartRace(minutes, { id = id, startedAt = startedAt or id, starter = name })
  elseif action == "end" then
    local id = tonumber(f[4])
    if self.race and self.race.active and self.race.id == id then self:FinishRace(true, name) end
  end
end

---------------------------------------------------------------------------
-- heartbeat: runs every five seconds whether or not the session clock is on
---------------------------------------------------------------------------
function Board:Heartbeat()
  if not CatXP.session or not self.db then return end
  local now = GetTime()
  if CatXP:IsRunning() or (CatXP.session.secs or 0) > 0 then
    local secs = CatXP.session.secs or 0
    self:Sample(self:Identity().key, secs >= CatXP.WARMUP_SECS and CatXP:SessionRate() or 0)
  end
  for key, e in pairs(self.roster) do
    if now - (e.lastSeen or 0) > FORGET_AFTER and not (self.race and self.race.active and e.raceId == self.race.id) then
      self.roster[key] = nil
      self.samples[key] = nil
    end
  end
  self:Broadcast()
  if self.race and self.race.active and self:RaceLeft() <= 0 then self:FinishRace(false) end
  self:CheckLead()
  if CatXP.FlushGroupSay then CatXP:FlushGroupSay() end   -- a party line held back by the one-a-minute gate
  if ns.RefreshBoard then ns.RefreshBoard() end
end
