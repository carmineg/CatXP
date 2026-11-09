--[[-------------------------------------------------------------------------
  CatXP  -  a tiny, cat-themed XP per hour tracker.

  Target client: World of Warcraft: Forever (interface 16001).
  Also loads on Classic Era (11509); every API used here exists on both.

  Files
    Core.lua    tiers, tracking math, chat pace, gold, events, saved variables, slash commands
    Charts.lua  small drawing module: bars, lines, markers, hover tooltips
    UI.lua      on-screen frame, tooltip, right-click menu, details panel
    Graphs.lua  the Graphs window: session line, levels, zones, past sessions

  Saved variables
    CatXPDB      (account-wide)  window positions, scale, options
    CatXPCharDB  (per character) current session, per-level history, past sessions

  To rename the cats or move the thresholds, edit CatXP.TIERS below.
---------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local CatXP = CreateFrame("Frame", "CatXPEvents")
ns.CatXP = CatXP
_G.CatXP = CatXP

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
CatXP.VERSION = (GetMeta and GetMeta(ADDON_NAME, "Version")) or "dev"

local WARMUP_SECS  = 60   -- rate and tier read "warming up" for the first minute of a session
local RECENT_MINS  = 15   -- the "recent" rate looks at the last 15 active minutes
local RECENT_KILLS = 10   -- kills-to-level uses the average XP of the last N kills
local DEFAULT_PACE = 5    -- minutes between automatic chat lines (a new cat, a new leader); /catxp pace
local SETTLE_SECS  = 300  -- a session younger than this (or than the pace, if shorter) is not announced yet
local DEMOTION_MARGIN = 300   -- xp/h below a cat's floor before a slip counts as a demotion
local MAX_TICK     = 120  -- a single clock tick never adds more than this many seconds
local MAX_HISTORY  = 40   -- finished sessions kept per character
local MIN_SESSION  = 60   -- sessions shorter than this are not archived on reset
local GROUP_GAP    = 60   -- two lines to party, raid or instance chat never come closer than this, races aside
local HOUR_MINS    = 60   -- the "last hour" rate window
local QUEST_WINDOW = 2    -- seconds around a quest turn-in in which a rise in your money is its reward
local SHOP_GRACE   = 2    -- seconds after a vendor, mailbox, auction or trade window closes that still belong to it
local ITEM_WAIT    = 30   -- seconds a picked-up item may wait for the client to load its vendor price
CatXP.WARMUP_SECS = WARMUP_SECS

---------------------------------------------------------------------------
-- Tiers: XP per hour -> cat. Keep the list sorted by `min`.
-- Colours follow WoW item rarity (grey, white, green, blue, purple, orange, gold, pink).
---------------------------------------------------------------------------
-- `image` is the portrait shipped in Media/ (drawn by tools/make_cats.py); `icon` is a Blizzard fallback.
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
local ICON = "Interface\\Icons\\"
-- One cat for everything under 10k, fifteen cats across the 10k-35k band where levelling rates
-- usually sit (2k steps up to 20k, then 1.5k steps to 35k), and one cat for everything above
-- 35k. Colours follow item rarity. `quip` is said on the way up, `sad` on the way down.
CatXP.TIERS = {
  { min = 0,     name = "Napping Kitten", color = "9d9d9d", image = MEDIA .. "cat_napping.tga",  icon = ICON .. "Ability_Druid_CatForm",
    quip = "zzz... five more minutes.",                        sad = "Curled up in a sunbeam. The XP can wait." },
  { min = 10000, name = "Sleepy Kitten",  color = "9d9d9d", image = MEDIA .. "cat_sleepy.tga",   icon = ICON .. "Ability_Druid_CatForm",
    quip = "Stretching. Yawning. Considering it.",             sad = "One eye open. Barely." },
  { min = 12000, name = "Playful Kitten", color = "ffffff", image = MEDIA .. "cat_playful.tga",  icon = ICON .. "Ability_Druid_CatForm",
    quip = "Batting at the XP bar.",                           sad = "Got distracted by a butterfly." },
  { min = 14000, name = "House Cat",      color = "1eff00", image = MEDIA .. "cat_housecat.tga", icon = ICON .. "Ability_Hunter_Pet_Cat",
    quip = "Comfortable pace. Knocks mobs off tables.",        sad = "Back on the couch. Someone refill the bowl." },
  { min = 16000, name = "Alley Cat",      color = "1eff00", image = MEDIA .. "cat_alley.tga",    icon = ICON .. "Ability_Hunter_Pet_Cat",
    quip = "Street smart. Only takes quests it can finish.",   sad = "Lost the alley to a raccoon." },
  { min = 18000, name = "Wildcat",        color = "0070dd", image = MEDIA .. "cat_wildcat.tga",  icon = ICON .. "Ability_Hunter_Pet_Cat",
    quip = "Feral and focused.",                               sad = "The wild got a little less wild." },
  { min = 20000, name = "Bobcat",         color = "0070dd", image = MEDIA .. "cat_bobcat.tga",   icon = ICON .. "Ability_Druid_Dash",
    quip = "Short tail, long kill streak.",                    sad = "Tail between the legs." },
  { min = 21500, name = "Lynx",           color = "a335ee", image = MEDIA .. "cat_lynx.tga",     icon = ICON .. "Ability_Druid_Dash",
    quip = "Tufted ears, tufted efficiency.",                  sad = "Ear tufts drooping." },
  { min = 23000, name = "Ocelot",         color = "a335ee", image = MEDIA .. "cat_ocelot.tga",   icon = ICON .. "Ability_Druid_Dash",
    quip = "Spotted and speedy.",                              sad = "Spots fading." },
  { min = 24500, name = "Serval",         color = "a335ee", image = MEDIA .. "cat_serval.tga",   icon = ICON .. "Ability_Druid_Dash",
    quip = "Jumps ten feet for a mob tag.",                    sad = "Missed the jump." },
  { min = 26000, name = "Caracal",        color = "ff8000", image = MEDIA .. "cat_caracal.tga",  icon = ICON .. "Ability_Mount_BlackPanther",
    quip = "Floppy ears, zero wasted pulls.",                  sad = "Ears down. Pulls wasted." },
  { min = 27500, name = "Puma",           color = "ff8000", image = MEDIA .. "cat_puma.tga",     icon = ICON .. "Ability_Mount_BlackPanther",
    quip = "Silent. Deadly. Grinding.",                        sad = "Silent. Sulking. Still grinding." },
  { min = 29000, name = "Leopard",        color = "ff8000", image = MEDIA .. "cat_leopard.tga",  icon = ICON .. "Ability_Mount_BlackPanther",
    quip = "Those spots are XP stains.",                       sad = "Lost a spot or two." },
  { min = 30500, name = "Jaguar",         color = "e6cc80", image = MEDIA .. "cat_jaguar.tga",   icon = ICON .. "Ability_Mount_JungleTiger",
    quip = "Apex pull rotation.",                              sad = "The apex is behind you now." },
  { min = 32000, name = "Tiger",          color = "e6cc80", image = MEDIA .. "cat_tiger.tga",    icon = ICON .. "Ability_Mount_JungleTiger",
    quip = "Burning bright.",                                  sad = "Burning a little dimmer." },
  { min = 33500, name = "Cheetah",        color = "e6cc80", image = MEDIA .. "cat_cheetah.tga",  icon = ICON .. "Ability_Mount_WhiteTiger",
    quip = "Fastest cat alive. Is this AoE farming?",          sad = "Still fast. Just not that fast." },
  { min = 35000, name = "Nyan Cat",       color = "ff69b4", image = MEDIA .. "cat_nyan.tga",     icon = ICON .. "Ability_Mount_PinkTiger",
    quip = "Leaving a rainbow trail. The GMs have questions.", sad = "The rainbow flickered." },
}

local LEVEL_QUIPS = { "Purr-fect!", "Meow-velous!", "Claw-some!", "Fur real!", "Paws-itively great!", "Feline fine!", "That is a lot of catnip." }

-- XP needed to finish each level (2004 table, used only for the "level 60 in ..." estimate
-- where the addon has not yet seen the level's real bar).
CatXP.XP_TABLE = {
  [1] = 400, [2] = 900, [3] = 1400, [4] = 2100, [5] = 2800, [6] = 3600, [7] = 4500, [8] = 5400, [9] = 6500,
  [10] = 7600, [11] = 8800, [12] = 10100, [13] = 11400, [14] = 12900, [15] = 14400, [16] = 16000, [17] = 17700,
  [18] = 19400, [19] = 21300, [20] = 23200, [21] = 25200, [22] = 27300, [23] = 29400, [24] = 31700, [25] = 34000,
  [26] = 36400, [27] = 38900, [28] = 41400, [29] = 44300, [30] = 47400, [31] = 50800, [32] = 54500, [33] = 58600,
  [34] = 62800, [35] = 67100, [36] = 71600, [37] = 76100, [38] = 80800, [39] = 85700, [40] = 90700, [41] = 95800,
  [42] = 101000, [43] = 106300, [44] = 111800, [45] = 117500, [46] = 123200, [47] = 129100, [48] = 135100,
  [49] = 141200, [50] = 147500, [51] = 153900, [52] = 160400, [53] = 167100, [54] = 173900, [55] = 180800,
  [56] = 187900, [57] = 195000, [58] = 202300, [59] = 209800,
}

---------------------------------------------------------------------------
-- Small formatting helpers shared with the UI files
---------------------------------------------------------------------------
function ns.color(hex, text)
  return "|cff" .. hex .. tostring(text) .. "|r"
end

function ns.hexToRGB(hex)
  return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- 25120 -> "25,120"
function ns.fmtNum(n)
  n = math.floor((tonumber(n) or 0) + 0.5)
  local neg = n < 0
  local s = tostring(math.abs(n))
  local rev = s:reverse()
  rev = rev:gsub("(%d%d%d)", "%1,")
  s = rev:reverse()
  if s:sub(1, 1) == "," then s = s:sub(2) end
  return (neg and "-" or "") .. s
end

-- 18230 -> "18.2k", 1200000 -> "1.2m", 950 -> "950"
function ns.fmtShort(n)
  n = tonumber(n) or 0
  if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
  if n >= 1000 then return string.format("%.1fk", n / 1000) end
  return tostring(math.floor(n + 0.5))
end

-- Tier thresholds: 20000 -> "20k", 35000 -> "35k"; anything else falls back to fmtShort.
function ns.fmtK(n)
  n = tonumber(n) or 0
  if n >= 1000 and n % 1000 == 0 then return string.format("%dk", n / 1000) end
  return ns.fmtShort(n)
end

-- 5025 -> "1h 23m", 125 -> "2m 05s", 90000 -> "1d 1h"
function ns.fmtTime(secs)
  secs = math.floor((tonumber(secs) or 0) + 0.5)
  if secs < 0 then secs = 0 end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  local m = math.floor((secs % 3600) / 60)
  local s = secs % 60
  if d > 0 then return string.format("%dd %dh", d, h) end
  if h > 0 then return string.format("%dh %02dm", h, m) end
  if m > 0 then return string.format("%dm %02ds", m, s) end
  return string.format("%ds", s)
end

-- Copper as coins: 124050 -> "12g 40s", 4012 -> "40s 12c", 7 -> "7c". Coloured like the game's
-- coins unless `plain` is set.
function ns.fmtMoney(copper, plain)
  copper = math.floor((tonumber(copper) or 0) + 0.5)
  if copper < 0 then copper = 0 end
  local g = math.floor(copper / 10000)
  local s = math.floor((copper % 10000) / 100)
  local c = copper % 100
  local function coin(text, hex)
    return plain and text or ns.color(hex, text)
  end
  if g > 0 then
    return coin(ns.fmtNum(g) .. "g", "ffd100") .. " " .. coin(string.format("%02ds", s), "c7c7cf")
  elseif s > 0 then
    return coin(s .. "s", "c7c7cf") .. " " .. coin(string.format("%02dc", c), "eda55f")
  end
  return coin(c .. "c", "eda55f")
end

-- Turn a Blizzard format string ("%s dies, you gain %d experience.") into a Lua pattern.
function ns.formatToPattern(fmt)
  fmt = fmt:gsub("%%(%d+)%$", "%%")                               -- "%1$s" -> "%s"
  local p = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")     -- escape magic characters
  p = p:gsub("%%%%s", "(.-)")                                      -- "%s" -> lazy capture
  p = p:gsub("%%%%d", "(%%d+)")                                    -- "%d" -> digit capture
  return "^" .. p
end

local function isSecret(v)
  return issecretvalue ~= nil and issecretvalue(v) == true
end
ns.isSecret = isSecret

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------
local DEFAULT_SETTINGS = {
  locked = false, scale = 1.0, alpha = 0.85,
  point = "CENTER", relPoint = "CENTER", x = 0, y = 180,
  shown = true, detailsShown = false,
  graphTab = "session",
  autoStart = true,       -- start the clock on the first XP gain
  announceTiers = true,   -- chat message when you reach a faster cat
  partyAnnounce = true,   -- also tell your party or raid when you reach a faster cat
  boardTab = "live",
  windowsShown = true,    -- the five rate windows (15 min, hour, session, level, today) on the main window
  shareGroup = true,      -- leaderboard: share your numbers with your party or raid
  shareGuild = true,      -- leaderboard: share your numbers with your guild
  leadAnnounce = true,    -- leaderboard: say when the lead changes hands
  chatPace = DEFAULT_PACE, -- minutes between automatic chat lines, in your chat or the group's
  goldTrack = false,      -- opt-in: raw gold per hour (looted coin, quest coin, vendor price of pickups)
}

local function newSession()
  return {
    startedAt = 0,      -- wall clock (time()) when the session started, 0 = not started
    startLevel = 0,
    secs = 0,           -- active (unpaused) seconds
    xp = 0,
    kills = 0,
    killXP = 0,
    recentKills = {},   -- XP of the last RECENT_KILLS kills
    buckets = {},       -- XP per active minute: buckets[floor(secs / 60) + 1]
    levelUps = 0,
    zones = {},         -- [zone name] = { xp, secs, kills }
    marks = {},         -- level-ups: { m = active minute, level = new level }
    -- With gold tracking on, three more fields appear on first use: gold = { loot, quest, items }
    -- in copper, goldBuckets = copper per active minute, goldSecs = seconds gold was counted.
  }
end

function CatXP:InitDB()
  CatXPDB = CatXPDB or {}
  CatXPDB.settings = CatXPDB.settings or {}
  for k, v in pairs(DEFAULT_SETTINGS) do
    if CatXPDB.settings[k] == nil then CatXPDB.settings[k] = v end
  end
  self.settings = CatXPDB.settings

  CatXPCharDB = CatXPCharDB or {}
  local c = CatXPCharDB
  c.session = c.session or newSession()
  c.session.zones = c.session.zones or {}     -- sessions saved by version 1
  c.session.marks = c.session.marks or {}
  c.levels = c.levels or {}
  c.history = c.history or {}
  if c.running == nil then c.running = false end
  self.db = c
  self.session = c.session
end

---------------------------------------------------------------------------
-- Chat output
---------------------------------------------------------------------------
local PREFIX = "|cffffcc66CatXP|r =^.^= "

function CatXP:Print(msg)
  local frame = DEFAULT_CHAT_FRAME or ChatFrame1
  if frame and frame.AddMessage then
    frame:AddMessage(PREFIX .. tostring(msg))
  else
    print(PREFIX .. tostring(msg))
  end
end

---------------------------------------------------------------------------
-- Tiers
---------------------------------------------------------------------------
-- Returns tier, index for an XP/hour value.
function CatXP:TierFor(rate)
  rate = tonumber(rate) or 0
  local tiers = self.TIERS
  local idx = 1
  for i = 1, #tiers do
    if rate >= tiers[i].min then idx = i else break end
  end
  return tiers[idx], idx
end

-- Inline texture escape for a tier's portrait, usable in chat lines, tooltips and font strings.
function ns.tierIcon(tier, size)
  size = size or 16
  return "|T" .. tier.image .. ":" .. size .. ":" .. size .. "|t"
end

function CatXP:TierName(tier, withIcon)
  local name = ns.color(tier.color, tier.name)
  if withIcon and tier.image then return ns.tierIcon(tier, 16) .. " " .. name end
  return name
end

---------------------------------------------------------------------------
-- Snapshot of the player's XP state, used to turn PLAYER_XP_UPDATE into deltas
---------------------------------------------------------------------------
local function readXP()
  local level, xp, max = UnitLevel("player"), UnitXP("player"), UnitXPMax("player")
  if isSecret(level) or isSecret(xp) or isSecret(max) then return nil end
  if type(level) ~= "number" or type(xp) ~= "number" or type(max) ~= "number" then return nil end
  return level, xp, max
end

function CatXP:Snapshot()
  local level, xp, max = readXP()
  self.lastLevel = level or self.lastLevel or 0
  self.lastXP    = xp or self.lastXP or 0
  self.lastMax   = max or self.lastMax or 0
  self.pendingLevelUp = nil
end

function CatXP:LevelRecord(level, create)
  if not level or level <= 0 then return nil end
  local rec = self.db.levels[level]
  if not rec and create then
    rec = { secs = 0, xp = 0, kills = 0, startedAt = time(), done = false }
    if level == self.lastLevel and (self.lastMax or 0) > 0 then rec.xpMax = self.lastMax end
    self.db.levels[level] = rec
  end
  return rec
end

-- Compare the live XP state with the snapshot and book any difference.
-- Works whichever of PLAYER_LEVEL_UP / PLAYER_XP_UPDATE fires first.
function CatXP:Sync()
  local level, xp, max = readXP()
  if not level then return end
  if level > self.lastLevel then
    if self.pendingLevelUp then
      -- The wrap below already booked the level-up; only count what came after.
      self.pendingLevelUp = nil
      self:OnLevelChanged(self.lastLevel, level)
      local extra = xp - self.lastXP
      if extra > 0 then self:AddXP(extra, level) end
    else
      -- Levelled: the rest of the old bar belongs to the old level, the new bar to the new one.
      -- (Two levels in one gain would miss the middle level's bar; rare, ignored.)
      local overflow = math.max(0, self.lastMax - self.lastXP)
      if overflow > 0 then self:AddXP(overflow, self.lastLevel) end
      self:OnLevelChanged(self.lastLevel, level)
      if xp > 0 then self:AddXP(xp, level) end
    end
  elseif level == self.lastLevel then
    if xp >= self.lastXP then
      local gained = xp - self.lastXP
      if gained > 0 then self:AddXP(gained, level) end
    else
      -- XP wrapped but UnitLevel has not caught up yet: treat as a level-up.
      local gained = math.max(0, self.lastMax - self.lastXP) + xp
      if gained > 0 then self:AddXP(gained, level) end
      self.pendingLevelUp = true
    end
  end
  self.lastLevel, self.lastXP, self.lastMax = level, xp, max
  local rec = self.db.levels[level]
  if rec and max > 0 then rec.xpMax = max end
  self:Refresh()
end

function CatXP:OnLevelChanged(oldLevel, newLevel)
  local old = self.db.levels[oldLevel]
  if old and not old.done then
    old.done = true
    old.finishedAt = time()
    if old.secs > 0 then
      local rate = old.xp / old.secs * 3600
      local tier = self:TierFor(rate)
      local quip = LEVEL_QUIPS[math.random(#LEVEL_QUIPS)]
      self:Print(string.format("Level %d cleared in %s at %s xp/h (%s, %d kills). %s%s",
        oldLevel, ns.fmtTime(old.secs), ns.fmtShort(rate), self:TierName(tier, true), old.kills or 0, quip,
        ns.FactLine and ns.FactLine(tier) or ""))
    end
    if ns.Board then ns.Board:NoteLevel(oldLevel, old) end
  end
  if self:IsRunning() then
    local s = self.session
    self.lastLevel = newLevel      -- so the new record is created for the new level
    local fresh = self:LevelRecord(newLevel, true)
    if fresh then fresh.full = true end   -- tracked from its first XP, so it can count as a fastest level
    s.levelUps = (s.levelUps or 0) + 1
    s.marks = s.marks or {}
    table.insert(s.marks, { m = math.floor(s.secs / 60) + 1, level = newLevel })
  end
end

---------------------------------------------------------------------------
-- Zones
---------------------------------------------------------------------------
function CatXP:UpdateZone()
  local z = GetRealZoneText and GetRealZoneText() or nil
  if (not z or z == "") and GetZoneText then z = GetZoneText() end
  if isSecret(z) or type(z) ~= "string" or z == "" then return end
  self.zone = z
end

function CatXP:ZoneRecord(create)
  local z = self.zone
  if not z then return nil end
  local s = self.session
  s.zones = s.zones or {}
  local rec = s.zones[z]
  if not rec and create then
    rec = { xp = 0, secs = 0, kills = 0 }
    s.zones[z] = rec
  end
  return rec
end

-- Zones of this session, most XP first, with rates.
function CatXP:SortedZones()
  local out = {}
  for name, rec in pairs(self.session.zones or {}) do
    out[#out + 1] = {
      name = name, xp = rec.xp, secs = rec.secs, kills = rec.kills or 0,
      rate = rec.secs > 0 and (rec.xp / rec.secs * 3600) or 0,
    }
  end
  table.sort(out, function(a, b) return a.xp > b.xp end)
  return out
end

---------------------------------------------------------------------------
-- Today: XP, active time and kills since local midnight, across sessions and resets
---------------------------------------------------------------------------
function CatXP:TodayRecord()
  local day = date and date("%Y-%m-%d") or "today"
  if isSecret(day) or type(day) ~= "string" then day = "today" end
  local t = self.db.today
  if type(t) ~= "table" or t.day ~= day then
    t = { day = day, xp = 0, secs = 0, kills = 0 }
    self.db.today = t
  end
  return t
end

---------------------------------------------------------------------------
-- Booking XP, kills and time
---------------------------------------------------------------------------
function CatXP:IsRunning()
  return self.db.running == true
end

-- Start the clock for an automatic trigger, if the options allow it.
function CatXP:AutoStartAllowed()
  return self.settings.autoStart and not self.db.manualPause
end

function CatXP:AddXP(gained, level)
  if not self:IsRunning() then
    if self:AutoStartAllowed() then self:Start("auto") else return end
  end
  local s = self.session
  s.xp = s.xp + gained
  local today = self:TodayRecord()
  today.xp = today.xp + gained
  local rec = self:LevelRecord(level, true)
  if rec then rec.xp = rec.xp + gained end
  local idx = math.floor(s.secs / 60) + 1
  s.buckets[idx] = (s.buckets[idx] or 0) + gained
  local zone = self:ZoneRecord(true)
  if zone then zone.xp = zone.xp + gained end
  self:CheckTier(true)
end

function CatXP:AddKill(amount)
  if not self:IsRunning() then
    if self:AutoStartAllowed() then self:Start("auto") else return end
  end
  local s = self.session
  s.kills = s.kills + 1
  s.killXP = s.killXP + amount
  local today = self:TodayRecord()
  today.kills = (today.kills or 0) + 1
  table.insert(s.recentKills, amount)
  while #s.recentKills > RECENT_KILLS do table.remove(s.recentKills, 1) end
  local rec = self:LevelRecord(self.lastLevel, true)
  if rec then rec.kills = (rec.kills or 0) + 1 end
  local zone = self:ZoneRecord(true)
  if zone then zone.kills = (zone.kills or 0) + 1 end
end

-- Add elapsed clock time to the session, the current level and the current zone.
function CatXP:Accrue()
  local now = GetTime()
  local dt = now - (self.lastTick or now)
  self.lastTick = now
  if not self:IsRunning() then return end
  if dt < 0 then dt = 0 elseif dt > MAX_TICK then dt = MAX_TICK end
  self.session.secs = self.session.secs + dt
  local today = self:TodayRecord()
  today.secs = today.secs + dt
  local rec = self:LevelRecord(self.lastLevel, true)
  if rec then rec.secs = rec.secs + dt end
  local zone = self:ZoneRecord(true)
  if zone then zone.secs = zone.secs + dt end
  if self.settings.goldTrack then   -- gold has its own clock: only the time it was being counted
    local s = self.session
    s.goldSecs = (s.goldSecs or 0) + dt
    today.goldSecs = (today.goldSecs or 0) + dt
    if rec then rec.goldSecs = (rec.goldSecs or 0) + dt end
  end
end

function CatXP:Tick()
  self:Accrue()
  self:CheckTier()
  self:FlushGroupSay()
  self:RetryItemValues()
  self:Refresh()
end

function CatXP:StartTicker()
  if self.ticker then return end
  self.ticker = C_Timer.NewTicker(1, function() CatXP:Tick() end)
end

function CatXP:StopTicker()
  if self.ticker then
    self.ticker:Cancel()
    self.ticker = nil
  end
end

---------------------------------------------------------------------------
-- Gold (opt-in, /catxp gold): what the play earns per hour, in copper, from three sources.
--   loot   coin picked up from corpses and chests: any rise in your money that is not a quest
--          reward and does not happen at a vendor, the mailbox, the auction house or in a trade
--   quest  coin paid by a quest turn-in
--   items  what a vendor pays for each item you pick up, loot and quest rewards alike. It is
--          counted when the item lands in your bags, so selling it later is not counted twice
-- Money you spend is ignored: this is the raw income, not the change in your purse.
---------------------------------------------------------------------------
local GOLD_EVENTS = {
  "PLAYER_MONEY", "CHAT_MSG_LOOT", "QUEST_TURNED_IN", "GET_ITEM_INFO_RECEIVED",
  "MERCHANT_SHOW", "MERCHANT_CLOSED", "MAIL_SHOW", "MAIL_CLOSED",
  "TRADE_SHOW", "TRADE_CLOSED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED",   -- not in every client; registered under pcall
}

local function readMoney()
  local m = GetMoney and GetMoney() or nil
  if isSecret(m) or type(m) ~= "number" then return nil end
  return m
end

function CatXP:GoldOn()
  return self.settings.goldTrack == true
end

-- The gold events are only listened to while the option is on.
function CatXP:ApplyGoldEvents()
  local on = self:GoldOn()
  for _, e in ipairs(GOLD_EVENTS) do
    if on then pcall(self.RegisterEvent, self, e) else pcall(self.UnregisterEvent, self, e) end
  end
end

-- Remember the purse as it is now, so only what comes in from here on is counted.
function CatXP:GoldBaseline()
  self.lastMoney = readMoney()
  self.goldShops, self.goldShopClosedAt = nil, nil
  self.questTurnedAt, self.lastCoin = nil, nil
end

function CatXP:SetGoldTracking(on)
  self.settings.goldTrack = on and true or false
  self:ApplyGoldEvents()
  self:GoldBaseline()
  if ns.ApplySettings then ns.ApplySettings() end
  self:Refresh()
end

-- Book income. Like XP, it starts the clock if auto-start allows it (at level 60 it is the only
-- thing that can), and is ignored while you have paused the session yourself.
function CatXP:AddGold(copper, source)
  copper = math.floor((tonumber(copper) or 0) + 0.5)
  if copper <= 0 or not self:GoldOn() then return false end
  if not self:IsRunning() then
    if self:AutoStartAllowed() then self:Start("gold") else return false end
  end
  local s = self.session
  s.gold = s.gold or { loot = 0, quest = 0, items = 0 }
  s.gold[source] = (s.gold[source] or 0) + copper
  s.goldBuckets = s.goldBuckets or {}     -- copper per active minute, like the XP buckets
  local idx = math.floor(s.secs / 60) + 1
  s.goldBuckets[idx] = (s.goldBuckets[idx] or 0) + copper
  local today = self:TodayRecord()
  today.gold = (today.gold or 0) + copper
  local rec = self:LevelRecord(self.lastLevel, true)
  if rec then rec.gold = (rec.gold or 0) + copper end
  self:Refresh()
  return true
end

-- A vendor, mailbox, auction or trade window is open, or closed a moment ago: money and items
-- that arrive now were sold, bought, mailed or traded, not earned in the field.
function CatXP:GoldShopOpen()
  if self.goldShops and next(self.goldShops) then return true end
  return self.goldShopClosedAt ~= nil and GetTime() - self.goldShopClosedAt < SHOP_GRACE
end

function CatXP:SetGoldShop(which, open)
  self.goldShops = self.goldShops or {}
  if open then
    self.goldShops[which] = true
  elseif self.goldShops[which] then
    self.goldShops[which] = nil
    self.goldShopClosedAt = GetTime()
  end
end

-- PLAYER_MONEY: any rise in the purse outside those windows is income.
function CatXP:OnMoney()
  local money = readMoney()
  if not money then return end
  local last = self.lastMoney
  self.lastMoney = money
  if not last or not self:GoldOn() then return end
  local delta = money - last
  if delta <= 0 or self:GoldShopOpen() then return end
  local now = GetTime()
  if self.questTurnedAt and now - self.questTurnedAt <= QUEST_WINDOW then
    self:AddGold(delta, "quest")
  elseif self:AddGold(delta, "loot") then
    self.lastCoin = { amount = delta, at = now }
  end
end

-- QUEST_TURNED_IN: the reward coin arrives just after this event, or just before it. Either way
-- it is booked as quest coin, not loot.
function CatXP:OnQuestTurnedIn()
  if not self:GoldOn() then return end
  local now = GetTime()
  self.questTurnedAt = now
  local c = self.lastCoin
  self.lastCoin = nil
  if c and now - c.at <= QUEST_WINDOW then
    local g = self.session.gold
    if g and (g.loot or 0) >= c.amount then
      g.loot = g.loot - c.amount
      g.quest = (g.quest or 0) + c.amount
      self:Refresh()
    end
  end
end

-- CHAT_MSG_LOOT tells which items landed in your own bags. Such a line is recognised by how the
-- game's own format strings begin ("You receive loot: ", "You receive item: "), so other
-- players' loot and the things you craft are left out, in any language.
function CatXP:BuildLootPrefixes()
  self.lootPrefixes = {}
  for _, name in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE" }) do
    local fmt = _G[name]
    if type(fmt) == "string" then
      local prefix = fmt:match("^(.-)%%[%d%$]*s")
      if prefix and prefix ~= "" then self.lootPrefixes[prefix] = true end
    end
  end
  if not next(self.lootPrefixes) then
    self.lootPrefixes["You receive loot: "] = true
    self.lootPrefixes["You receive item: "] = true
  end
end

function CatXP:OnLootMessage(text)
  if not self:GoldOn() or type(text) ~= "string" or isSecret(text) then return end
  if self:GoldShopOpen() then return end   -- bought, mailed or traded, not picked up
  -- pcall: in chat-restricted zones the text may be unreadable; never let that break the addon.
  local ok, item, count = pcall(function()
    local mine = false
    for prefix in pairs(self.lootPrefixes or {}) do
      if text:sub(1, #prefix) == prefix then mine = true; break end
    end
    if not mine then return nil end
    local itemString = text:match("|H(item:[^|]+)|h")
    if not itemString then return nil end
    return itemString, tonumber(text:match("|h|rx(%d+)") or text:match("|hx(%d+)")) or 1
  end)
  if not ok or not item then return end
  self:AddItemValue(item, count or 1)
end

-- What a vendor pays for one of these; nil while the client has not loaded the item yet.
local function sellPriceOf(itemString)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not get then return 0 end
  local ok, name, _, _, _, _, _, _, _, _, _, price = pcall(get, itemString)
  if not ok then return 0 end
  if name == nil then return nil end
  if isSecret(price) or type(price) ~= "number" then return 0 end
  return price
end

function CatXP:AddItemValue(itemString, count)
  -- paused by hand: not counted now, and not later when its price turns up
  if not self:IsRunning() and not self:AutoStartAllowed() then return end
  local price = sellPriceOf(itemString)
  if price == nil then
    self.goldPending = self.goldPending or {}
    if #self.goldPending < 40 then
      table.insert(self.goldPending, { item = itemString, count = count, at = GetTime() })
    end
    return
  end
  if price > 0 then self:AddGold(price * count, "items") end
end

-- Items whose price was not loaded when they dropped: look again, give up after ITEM_WAIT.
function CatXP:RetryItemValues()
  local q = self.goldPending
  if not q or #q == 0 then return end
  local now = GetTime()
  for i = #q, 1, -1 do
    local e = q[i]
    local price = sellPriceOf(e.item)
    if price ~= nil then
      table.remove(q, i)
      if price > 0 then self:AddGold(price * e.count, "items") end
    elseif now - e.at > ITEM_WAIT then
      table.remove(q, i)
    end
  end
end

-- Copper and counted seconds in the last `minutes` active minutes of the session.
function CatXP:RecentGold(minutes)
  local s = self.session
  local b = s.goldBuckets
  if not b or s.secs < 1 then return 0, 0 end
  local idx = math.floor(s.secs / 60) + 1
  local sum = 0
  for i = math.max(1, idx - minutes + 1), idx do sum = sum + (b[i] or 0) end
  local window = math.min(s.secs, (s.secs % 60) + (minutes - 1) * 60)
  return sum, math.min(window, s.goldSecs or 0)
end

-- Everything the UI shows about gold, or nil while the option is off. `windows` mirrors the XP
-- rate windows: last 15 minutes, last hour, session, this level, today.
function CatXP:GoldStats()
  if not self:GoldOn() then return nil end
  local s = self.session
  local g = s.gold or {}
  local total = (g.loot or 0) + (g.quest or 0) + (g.items or 0)
  local secs = s.goldSecs or 0
  local function span(key, name, gold, t)
    gold, t = gold or 0, t or 0
    return { key = key, name = name, gold = gold, secs = t, rate = t > 0 and (gold / t * 3600) or 0, ready = t >= WARMUP_SECS }
  end
  local rec = self.db.levels[self.lastLevel or 0]
  local today = self:TodayRecord()
  local gold15, secs15 = self:RecentGold(RECENT_MINS)
  local gold60, secs60 = self:RecentGold(HOUR_MINS)
  return {
    total = total, loot = g.loot or 0, quest = g.quest or 0, items = g.items or 0,
    secs = secs, rate = secs > 0 and (total / secs * 3600) or 0, ready = secs >= WARMUP_SECS,
    windows = {
      span("recent", "Last 15 min", gold15, secs15),
      span("hour", "Last hour", gold60, secs60),
      span("session", "Session", total, secs),
      span("level", "This level", rec and rec.gold, rec and rec.goldSecs),
      span("today", "Today", today.gold, today.goldSecs),
    },
  }
end

---------------------------------------------------------------------------
-- Start / pause / reset
---------------------------------------------------------------------------
function CatXP:Start(reason)
  if self:IsRunning() then
    if not reason then self:Print("Already tracking. The cat is on the prowl.") end
    return
  end
  self.db.running = true
  self.db.manualPause = nil
  self.lastTick = GetTime()
  local s = self.session
  if s.startedAt == 0 then
    s.startedAt = time()
    s.startLevel = self.lastLevel
  end
  self:LevelRecord(self.lastLevel, true)
  self:StartTicker()
  self:Refresh()
  if reason == "auto" then
    self:Print("XP spotted! Tracking started.")
  elseif reason == "gold" then
    self:Print("Gold spotted! Tracking started.")
  elseif reason ~= "silent" then
    self:Print("Tracking started. Go get them, kitty.")
  end
end

function CatXP:Pause(reason)
  if not self:IsRunning() then
    if not reason then self:Print("Not tracking. The cat is already asleep.") end
    return
  end
  self:Accrue()
  self.db.running = false
  self.db.manualPause = true   -- the only kind of pause: nothing stops the clock on its own
  self:StopTicker()
  self:Refresh()
  if reason ~= "silent" then
    self:Print(string.format("Paused at %s xp/h. /catxp start to resume.", ns.fmtShort(self:SessionRate())))
  end
end

function CatXP:Toggle()
  if self:IsRunning() then self:Pause() else self:Start() end
end

-- Keep a summary of the session that is about to be reset.
function CatXP:ArchiveSession()
  local s = self.session
  if s.secs < MIN_SESSION then return false end
  self.db.history = self.db.history or {}
  local entry = {
    startedAt = s.startedAt, endedAt = time(), secs = s.secs, xp = s.xp, kills = s.kills,
    startLevel = s.startLevel, endLevel = self.lastLevel, levelUps = s.levelUps or 0,
  }
  if s.gold then
    entry.gold = (s.gold.loot or 0) + (s.gold.quest or 0) + (s.gold.items or 0)
    entry.goldSecs = s.goldSecs or 0
  end
  table.insert(self.db.history, entry)
  while #self.db.history > MAX_HISTORY do table.remove(self.db.history, 1) end
  if ns.Board then ns.Board:NoteSession(entry) end
  return true
end

-- New session; per-level history is kept. Keeps tracking if it was tracking.
function CatXP:Reset(silent)
  local wasRunning = self:IsRunning()
  if wasRunning then self:Accrue() end
  local archived = self:ArchiveSession()
  self.db.session = newSession()
  self.session = self.db.session
  self.db.manualPause = nil
  self.tierIndex = nil
  if wasRunning then
    self.session.startedAt = time()
    self.session.startLevel = self.lastLevel
    self.lastTick = GetTime()
  end
  self:Refresh()
  if not silent then
    self:Print(archived and "Session saved to history and reset. Fresh litter, fresh numbers."
      or "Session reset. Fresh litter, fresh numbers.")
  end
end

function CatXP:ClearLevels()
  self.db.levels = {}
  if self:IsRunning() then self:LevelRecord(self.lastLevel, true) end
  self:Refresh()
  self:Print("Per-level history cleared.")
end

function CatXP:ClearSessions()
  self.db.history = {}
  self:Refresh()
  self:Print("Session history cleared.")
end

function CatXP:ClearHistory()
  self:ClearLevels()
  self:ClearSessions()
end

---------------------------------------------------------------------------
-- Rates and estimates
---------------------------------------------------------------------------
function CatXP:SessionRate()
  local s = self.session
  if s.secs < 1 then return 0 end
  return s.xp / s.secs * 3600
end

-- XP and active seconds in the last `minutes` active minutes of the session.
function CatXP:RecentWindow(minutes)
  minutes = minutes or RECENT_MINS
  local s = self.session
  if s.secs < 1 then return 0, 0 end
  local idx = math.floor(s.secs / 60) + 1
  local sum = 0
  for i = math.max(1, idx - minutes + 1), idx do
    sum = sum + (s.buckets[i] or 0)
  end
  local window = math.min(s.secs, (s.secs % 60) + (minutes - 1) * 60)
  return sum, window
end

-- XP/hour over the last `minutes` active minutes.
function CatXP:RecentRate(minutes)
  local xp, secs = self:RecentWindow(minutes)
  if secs < 1 then return 0 end
  return xp / secs * 3600
end

-- The rate windows on the main window: the same XP/hour over five spans. Each entry has key,
-- name, short (the label on the window), xp, secs, rate, tier and ready (a minute of data).
function CatXP:Windows()
  local s = self.session
  local out = {}
  local function add(key, name, short, xp, secs)
    xp, secs = xp or 0, secs or 0
    local rate = secs > 0 and (xp / secs * 3600) or 0
    out[#out + 1] = { key = key, name = name, short = short, xp = xp, secs = secs, rate = rate,
      tier = self:TierFor(rate), ready = secs >= WARMUP_SECS }
  end
  add("recent", "Last 15 min", "15 min", self:RecentWindow(RECENT_MINS))
  add("hour", "Last hour", "Hour", self:RecentWindow(HOUR_MINS))
  add("session", "Session", "Session", s.xp, s.secs)
  local rec = self.db.levels[self.lastLevel or 0]
  add("level", "This level", "Level", rec and rec.xp, rec and rec.secs)
  local today = self:TodayRecord()
  add("today", "Today", "Today", today.xp, today.secs)
  return out
end

-- Rolling XP/hour for each completed active minute of the session (the graph line).
-- Returns points, minutesPerPoint. Long sessions are averaged down to at most maxPoints.
function CatXP:RateSeries(windowMinutes, maxPoints)
  windowMinutes = windowMinutes or 5
  maxPoints = maxPoints or 120
  local s = self.session
  local M = math.floor(s.secs / 60)        -- completed minutes
  local points = {}
  if M < 2 then return points, 1 end
  for m = 1, M do
    local lo = math.max(1, m - windowMinutes + 1)
    local sum = 0
    for i = lo, m do sum = sum + (s.buckets[i] or 0) end
    points[m] = sum / ((m - lo + 1) * 60) * 3600
  end
  local k = math.ceil(M / maxPoints)
  if k > 1 then
    local down = {}
    for i = 1, M, k do
      local sum, n = 0, 0
      for j = i, math.min(M, i + k - 1) do sum = sum + points[j]; n = n + 1 end
      down[#down + 1] = sum / n
    end
    points = down
  end
  return points, k
end

function CatXP:AvgKillXP()
  local s = self.session
  local n = #s.recentKills
  if n > 0 then
    local sum = 0
    for i = 1, n do sum = sum + s.recentKills[i] end
    return sum / n
  end
  if s.kills > 0 then return s.killXP / s.kills end
  return nil
end

-- Averages over finished levels (the "per level" view).
function CatXP:LevelAverages()
  local n, secs, xp, kills = 0, 0, 0, 0
  for _, rec in pairs(self.db.levels) do
    if rec.done and rec.secs > 0 then
      n = n + 1
      secs = secs + rec.secs
      xp = xp + rec.xp
      kills = kills + (rec.kills or 0)
    end
  end
  if n == 0 then return nil end
  return { count = n, avgSecs = secs / n, avgXP = xp / n, rate = xp / secs * 3600, avgKills = kills / n }
end

-- Level numbers that have history, highest first.
function CatXP:SortedLevels()
  local out = {}
  for lvl in pairs(self.db.levels) do out[#out + 1] = lvl end
  table.sort(out, function(a, b) return a > b end)
  return out
end

-- XP still needed to reach level 60: the rest of this bar plus every later bar
-- (real bars where the addon has seen them, the 2004 table otherwise). nil at cap.
function CatXP:XPToMaxLevel()
  local level, xp, max = self.lastLevel or 0, self.lastXP or 0, self.lastMax or 0
  if level < 1 or level >= 60 or max <= 0 then return nil end
  local total = max - xp
  for L = level + 1, 59 do
    local rec = self.db.levels[L]
    local need = (rec and rec.xpMax and rec.xpMax > 0) and rec.xpMax or self.XP_TABLE[L]
    if not need then return nil end
    total = total + need
  end
  return total
end

-- Time to 60 at the average finished-level rate (or the session rate before any level is done).
function CatXP:Projection()
  local xp = self:XPToMaxLevel()
  if not xp then return nil end
  local avg = self:LevelAverages()
  local rate = (avg and avg.rate) or self:SessionRate()
  if not rate or rate <= 0 then return nil end
  return { xp = xp, rate = rate, secs = xp / rate * 3600, fromLevels = avg ~= nil }
end

-- Everything the UI needs, in one table.
function CatXP:GetStats()
  local s = self.session
  local level, xp, max = self.lastLevel or 0, self.lastXP or 0, self.lastMax or 0
  local rate = self:SessionRate()
  local recent = self:RecentRate()
  local active = self:IsRunning() or s.secs > 0
  local tier, tierIndex = self:TierFor(active and rate or 0)
  local maxLevel = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  if isSecret(maxLevel) or type(maxLevel) ~= "number" then maxLevel = 60 end
  local atMax = max <= 0 or level >= maxLevel
  local pct = (max > 0) and (xp / max * 100) or 0
  local ttl = nil
  if not atMax and rate > 0 then ttl = (max - xp) / rate * 3600 end
  local avgKill = self:AvgKillXP()
  local ktl = nil
  if not atMax and avgKill and avgKill > 0 then ktl = math.ceil((max - xp) / avgKill) end
  local rec = self.db.levels[level]
  local levelRate = (rec and rec.secs > 0) and (rec.xp / rec.secs * 3600) or 0
  local rested = GetXPExhaustion and GetXPExhaustion() or nil
  if isSecret(rested) or type(rested) ~= "number" then rested = nil end
  return {
    running = self:IsRunning(), manualPause = self.db.manualPause,
    secs = s.secs, xp = s.xp, rate = rate, recent = recent,
    warming = s.secs < WARMUP_SECS,
    tier = tier, tierIndex = tierIndex, nextTier = self.TIERS[tierIndex + 1],
    level = level, xpCur = xp, xpMax = max, pct = pct, atMax = atMax,
    ttl = ttl, ktl = ktl,
    kills = s.kills, avgKill = avgKill, killXP = s.killXP, otherXP = math.max(0, s.xp - s.killXP),
    levelRate = levelRate, levelSecs = rec and rec.secs or 0, levelXP = rec and rec.xp or 0,
    levelKills = rec and rec.kills or 0,
    rested = rested, startedAt = s.startedAt, startLevel = s.startLevel, levelUps = s.levelUps or 0,
    zone = self.zone,
    windows = self:Windows(),
    gold = self:GoldStats(),
  }
end

function ns.paceText(minutes)
  minutes = math.floor((tonumber(minutes) or DEFAULT_PACE) + 0.5)
  return minutes == 1 and "minute" or (minutes .. " minutes")
end

-- Seconds between automatic chat lines: the pace set with /catxp pace, in minutes.
function CatXP:PaceSecs()
  local m = tonumber(self.settings.chatPace) or DEFAULT_PACE
  if m < 1 then m = 1 elseif m > 60 then m = 60 end
  return m * 60
end

-- A rate younger than this still jumps with every kill, so it is not news yet: the pace, but
-- never more than SETTLE_SECS.
function CatXP:SettleSecs()
  return math.min(self:PaceSecs(), SETTLE_SECS)
end

-- The automatic lines (a new cat, a new leader) share one slot: CatXP says at most one of them
-- per pace, in your chat or the group's, and keeps GROUP_GAP away from any other line it sent
-- to the group. News that comes too soon is not queued. The check simply runs again later and
-- tells whatever is true by then, so a change that undid itself is never mentioned.
function CatXP:AutoLineDue()
  local now = GetTime()
  if self.lastAutoLine and now - self.lastAutoLine < self:PaceSecs() then return false end
  if self.lastGroupSay and now - self.lastGroupSay < GROUP_GAP then return false end
  return true
end

function CatXP:NoteAutoLine()
  self.lastAutoLine = GetTime()
end

-- `fromXP` is set when XP has just come in. The clock calls this too, every second, but only
-- to keep the current cat up to date.
function CatXP:CheckTier(fromXP)
  local s = self.session
  if not self:IsRunning() or s.secs < WARMUP_SECS then return end
  local rate = self:SessionRate()
  local tier, idx = self:TierFor(rate)
  self.tierIndex = idx
  -- Chat hears about a cat when the session has moved to a different one than it last
  -- announced: up ("reached" the first time, "back to" after a slip) or down ("slipped", with
  -- the sad line). To keep that from turning into noise:
  --   * it is only looked at when XP comes in, so a rate sliding while you travel, trade or
  --     sit at a vendor says nothing. The slide is told once, in one line, when you play again;
  --   * a session that has not settled yet (SettleSecs) is not news, its rate still jumps with
  --     every kill;
  --   * a slip only counts once the rate is DEMOTION_MARGIN below the announced cat's floor;
  --   * and the line waits for its turn (AutoLineDue) without being queued, so only the latest
  --     cat is ever told and a cat you left and came back to is not mentioned at all.
  if not fromXP then return end
  local S = self.settings
  local announced = s.announcedTier or 1
  local direction
  if idx > announced then
    direction = "up"
  elseif idx < announced and rate < self.TIERS[announced].min - DEMOTION_MARGIN then
    direction = "down"
  end
  if not direction then return end
  local best = s.bestTier or 1
  if not (S.announceTiers or S.partyAnnounce) then
    s.announcedTier = idx
    if idx > best then s.bestTier = idx end
    return
  end
  if s.secs < self:SettleSecs() or not self:AutoLineDue() then return end
  self:NoteAutoLine()
  s.announcedTier = idx
  local record = idx > best
  if record then s.bestTier = idx end
  local factLine = ns.FactLine and ns.FactLine(tier) or ""
  -- In a group the line goes to the group, where you read it yourself. Your own chat frame gets
  -- it only when nobody else did (solo, or party announcements off): never both.
  local told = S.partyAnnounce and self:AnnounceToGroup(tier, rate, direction, record, factLine)
  if S.announceTiers and not told then
    if direction == "up" then
      self:Print(string.format("Promoted to %s at %s xp/h. %s%s", self:TierName(tier, true), ns.fmtShort(rate), tier.quip, factLine))
    else
      self:Print(string.format("Demoted to %s at %s xp/h. %s%s", self:TierName(tier, true), ns.fmtShort(rate), tier.sad or tier.quip, factLine))
    end
  end
end

-- The chat channel of the group the player is in: party, raid or instance. nil when solo.
function ns.GroupChannel()
  if not (IsInGroup and IsInGroup()) then return nil end
  if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
  if IsInRaid and IsInRaid() then return "RAID" end
  return "PARTY"
end

-- A plain-text line to party, raid or instance chat. No colour codes or texture escapes: other
-- clients would not render them and the server may refuse the line. Only while grouped, so solo
-- play never talks to anyone. The automatic lines (a new cat, a new leader) are paced before
-- they get here, see AutoLineDue. This gate is the last line of defence and keeps any two lines
-- GROUP_GAP apart: one that still comes too soon waits, and a newer one takes its place.
-- Race lines are `urgent`: the player asked for the race, so they always go at once. Returns
-- true when the line was sent.
function CatXP:GroupSay(msg, urgent)
  local channel = ns.GroupChannel()
  if not channel or not SendChatMessage then
    self.pendingGroupSay = nil
    return false
  end
  local now = GetTime()
  if not urgent and self.lastGroupSay and now - self.lastGroupSay < GROUP_GAP then
    self.pendingGroupSay = msg
    return false
  end
  if not urgent then self.pendingGroupSay = nil end
  self.lastGroupSay = now
  pcall(SendChatMessage, tostring(msg):sub(1, 250), channel)
  return true
end

-- Sends the line that is waiting once the minute is up. Called by the session clock every
-- second and by the leaderboard heartbeat.
function CatXP:FlushGroupSay()
  local msg = self.pendingGroupSay
  if not msg then return end
  if self.lastGroupSay and GetTime() - self.lastGroupSay < GROUP_GAP then return end
  self.pendingGroupSay = nil
  self:GroupSay(msg)
end

-- Plain-text tier change for the group, under the name the group sees us by. Returns true when
-- the group got the line.
function CatXP:AnnounceToGroup(tier, rate, direction, record, factLine)
  local name = (ns.Board and ns.Board.MyName and ns.Board:MyName()) or (UnitName and UnitName("player"))
  if type(name) ~= "string" or isSecret(name) or name == "" then name = "Someone" end
  local verb, line = "reached", tier.quip
  if direction == "down" then
    verb, line = "slipped to", tier.sad or tier.quip
  elseif not record then
    verb = "is back to"
  end
  return self:GroupSay(string.format("CatXP: %s %s %s at %s xp/h. %s%s", name, verb, tier.name, ns.fmtShort(rate), line or "", factLine or ""))
end

function CatXP:Refresh()
  if ns.Refresh then ns.Refresh() end
end

---------------------------------------------------------------------------
-- Kill detection from the XP gain chat line
---------------------------------------------------------------------------
function CatXP:BuildKillPattern()
  local fmt = _G.COMBATLOG_XPGAIN_FIRSTPERSON
  if type(fmt) ~= "string" or not fmt:find("%%s") or not fmt:find("%%d") then
    fmt = "%s dies, you gain %d experience."
  end
  self.killPattern = ns.formatToPattern(fmt)
end

function CatXP:OnXPGainMessage(text)
  if type(text) ~= "string" or isSecret(text) then return end
  -- pcall: in chat-restricted zones the text may be unreadable; never let that break the addon.
  local ok, name, amount = pcall(string.match, text, self.killPattern)
  if not ok or not amount then return end
  amount = tonumber(amount)
  if not amount or amount <= 0 then return end
  self:AddKill(amount)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local EVENTS = {
  "PLAYER_ENTERING_WORLD", "PLAYER_XP_UPDATE", "PLAYER_LEVEL_UP",
  "CHAT_MSG_COMBAT_XP_GAIN", "PLAYER_LOGOUT",
  "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED",
  "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE",
}

CatXP:RegisterEvent("ADDON_LOADED")
CatXP:SetScript("OnEvent", function(self, event, ...)
  local handler = self[event]
  if handler then handler(self, ...) end
end)

function CatXP:ADDON_LOADED(name)
  if name ~= ADDON_NAME then return end
  self:UnregisterEvent("ADDON_LOADED")
  self:InitDB()
  self:BuildKillPattern()
  self:BuildLootPrefixes()
  if ns.Board then ns.Board:Init() end
  for _, e in ipairs(EVENTS) do self:RegisterEvent(e) end
  self:ApplyGoldEvents()
  if ns.BuildUI then ns.BuildUI() end
end

function CatXP:PLAYER_ENTERING_WORLD(isLogin, isReload)
  self:UpdateZone()
  self:GoldBaseline()
  if isLogin or isReload or not self.lastLevel then
    self:Snapshot()
  else
    self:Sync()
  end
  if self:IsRunning() then
    self.lastTick = GetTime()
    self:LevelRecord(self.lastLevel, true)
    self:StartTicker()
  end
  self:Refresh()
  if ns.Board then ns.Board:OnEnteringWorld() end
  if isLogin then
    self:Print(string.format("v%s loaded. /catxp for commands, /catxp graphs for the charts, /catxp board for the leaderboard.", tostring(self.VERSION)))
  end
end

function CatXP:CHAT_MSG_ADDON(prefix, text, channel, sender)
  if ns.Board then ns.Board:OnAddonMessage(prefix, text, channel, sender) end
end

function CatXP:GROUP_ROSTER_UPDATE()
  if ns.Board then ns.Board:Query() end
end

function CatXP:PLAYER_XP_UPDATE(unit)
  if unit and unit ~= "player" then return end
  self:Sync()
end

function CatXP:PLAYER_LEVEL_UP(newLevel)
  self:Sync()
end

function CatXP:CHAT_MSG_COMBAT_XP_GAIN(text)
  self:OnXPGainMessage(text)
end

function CatXP:ZONE_CHANGED_NEW_AREA()
  self:UpdateZone()
end

function CatXP:ZONE_CHANGED()
  self:UpdateZone()
end

function CatXP:PLAYER_LOGOUT()
  self:Accrue()
end

-- gold tracking (these events are only registered while /catxp gold is on)
function CatXP:PLAYER_MONEY() self:OnMoney() end
function CatXP:CHAT_MSG_LOOT(text) self:OnLootMessage(text) end
function CatXP:QUEST_TURNED_IN() self:OnQuestTurnedIn() end
function CatXP:GET_ITEM_INFO_RECEIVED() self:RetryItemValues() end
function CatXP:MERCHANT_SHOW() self:SetGoldShop("merchant", true) end
function CatXP:MERCHANT_CLOSED() self:SetGoldShop("merchant", false) end
function CatXP:MAIL_SHOW() self:SetGoldShop("mail", true) end
function CatXP:MAIL_CLOSED() self:SetGoldShop("mail", false) end
function CatXP:TRADE_SHOW() self:SetGoldShop("trade", true) end
function CatXP:TRADE_CLOSED() self:SetGoldShop("trade", false) end
function CatXP:AUCTION_HOUSE_SHOW() self:SetGoldShop("auction", true) end
function CatXP:AUCTION_HOUSE_CLOSED() self:SetGoldShop("auction", false) end
function CatXP:GUILDBANKFRAME_OPENED() self:SetGoldShop("guildbank", true) end
function CatXP:GUILDBANKFRAME_CLOSED() self:SetGoldShop("guildbank", false) end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
function CatXP:PrintStatus()
  local st = self:GetStats()
  local state = st.running and "Tracking" or (st.manualPause and "Paused" or "Idle")
  if st.secs < 1 then
    self:Print(string.format("%s. No session yet. Gain some XP or /catxp start.", state))
    return
  end
  self:Print(string.format("%s | %s | %s xp in %s | %s xp/h | %s",
    state, self:TierName(st.tier), ns.fmtNum(st.xp), ns.fmtTime(st.secs), ns.fmtShort(st.rate),
    st.ttl and (ns.fmtTime(st.ttl) .. " to level") or "no level estimate yet"))
  local g = st.gold
  if g then
    self:Print(string.format("Gold: %s in %s | %s | coin %s, quests %s, items %s",
      ns.fmtMoney(g.total), ns.fmtTime(g.secs), g.ready and (ns.fmtMoney(g.rate) .. "/h") or "warming up",
      ns.fmtMoney(g.loot), ns.fmtMoney(g.quest), ns.fmtMoney(g.items)))
  end
end

function CatXP:PrintTiers()
  self:Print("XP/hour tiers:")
  for i, t in ipairs(self.TIERS) do
    local nxt = self.TIERS[i + 1]
    local range
    if i == 1 and nxt then range = "under " .. ns.fmtK(nxt.min)
    elseif nxt then range = string.format("%s - %s", ns.fmtK(t.min), ns.fmtK(nxt.min))
    else range = ns.fmtK(t.min) .. "+" end
    self:Print(string.format("  %s  %s", range, self:TierName(t)))
  end
end

function CatXP:PrintHelp()
  self:Print("Commands:")
  self:Print("  /catxp start | stop | toggle | reset  - control the session clock")
  self:Print("  /catxp details  - details panel (or left-click the window)")
  self:Print("  /catxp graphs  - graphs window (or shift-left-click the window)")
  self:Print("  /catxp show | hide | lock | unlock  - window")
  self:Print("  /catxp scale <0.5-2.5> | alpha <0.1-1>  - window size and opacity")
  self:Print("  /catxp autostart | announce | party | windows  - toggle options")
  self:Print("  /catxp pace <minutes>  - how often chat hears from CatXP;  /catxp gold  - gold per hour (opt-in)")
  self:Print("  /catxp fact  - a cat fact, right now")
  self:Print("  /catxp board  - the leaderboard;  /catxp race <minutes> | race stop  - races")
  self:Print("  /catxp shareparty | shareguild | leadmsgs  - leaderboard options;  clearrecords")
  self:Print("  /catxp tiers | status | resetlevels | resetsessions")
  self:Print("Right-click the window for a menu. Drag it to move (when unlocked).")
end

function CatXP:SlashCommand(msg)
  msg = tostring(msg or ""):lower()
  msg = msg:gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, arg = msg:match("^(%S*)%s*(.-)$")
  cmd = cmd or ""
  local S = self.settings

  local function toggleOption(key, text)
    S[key] = not S[key]
    self:Print(text .. (S[key] and " on." or " off."))
  end

  if cmd == "" or cmd == "status" then
    self:PrintStatus()
    if cmd == "" then self:Print("Type /catxp help for commands.") end
  elseif cmd == "help" or cmd == "?" then
    self:PrintHelp()
  elseif cmd == "start" or cmd == "resume" or cmd == "go" then
    self:Start()
  elseif cmd == "stop" or cmd == "pause" then
    self:Pause()
  elseif cmd == "toggle" then
    self:Toggle()
  elseif cmd == "reset" then
    self:Reset()
  elseif cmd == "resetlevels" or cmd == "clearlevels" then
    self:ClearLevels()
  elseif cmd == "resetsessions" or cmd == "clearsessions" then
    self:ClearSessions()
  elseif cmd == "clearhistory" then
    self:ClearHistory()
  elseif cmd == "show" then
    if ns.SetShown then ns.SetShown(true) end
  elseif cmd == "hide" then
    if ns.SetShown then ns.SetShown(false) end
  elseif cmd == "window" then
    if ns.SetShown then ns.SetShown(not S.shown) end
  elseif cmd == "details" then
    if ns.ToggleDetails then ns.ToggleDetails() end
  elseif cmd == "graphs" or cmd == "graph" or cmd == "charts" then
    if ns.ToggleGraphs then ns.ToggleGraphs() end
  elseif cmd == "lock" or cmd == "unlock" then
    S.locked = (cmd == "lock")
    if ns.ApplySettings then ns.ApplySettings() end
    self:Print(S.locked and "Window locked." or "Window unlocked. Drag it where you like.")
  elseif cmd == "scale" then
    local n = tonumber(arg)
    if n and n >= 0.5 and n <= 2.5 then
      S.scale = n
      if ns.ApplySettings then ns.ApplySettings() end
      self:Print(string.format("Scale set to %.2f.", n))
    else
      self:Print("Usage: /catxp scale <0.5-2.5>")
    end
  elseif cmd == "alpha" then
    local n = tonumber(arg)
    if n and n >= 0.1 and n <= 1 then
      S.alpha = n
      if ns.ApplySettings then ns.ApplySettings() end
      self:Print(string.format("Opacity set to %.2f.", n))
    else
      self:Print("Usage: /catxp alpha <0.1-1>")
    end
  elseif cmd == "autostart" then
    toggleOption("autoStart", "Auto-start on XP gain")
  elseif cmd == "announce" then
    toggleOption("announceTiers", "Tier promotion messages")
  elseif cmd == "party" then
    toggleOption("partyAnnounce", "Party chat announcements")
  elseif cmd == "windows" then
    toggleOption("windowsShown", "Rate windows on the main window")
    if ns.ApplySettings then ns.ApplySettings() end
  elseif cmd == "pace" or cmd == "quiet" then
    local n = tonumber(arg)
    if n and n >= 1 and n <= 60 then
      S.chatPace = math.floor(n + 0.5)
      self:Print(string.format("Chat pace set: at most one automatic line every %s.", ns.paceText(S.chatPace)))
    else
      self:Print(string.format("Chat pace: at most one automatic line every %s. /catxp pace <1-60> changes it (minutes).",
        ns.paceText(self:PaceSecs() / 60)))
    end
  elseif cmd == "gold" then
    local on = not self:GoldOn()
    if arg == "on" then on = true elseif arg == "off" then on = false end
    self:SetGoldTracking(on)
    self:Print(on and "Gold tracking on: looted coin, quest coin and the vendor price of everything you pick up, per hour."
      or "Gold tracking off.")
  elseif cmd == "fact" or cmd == "facts" then
    local fact = ns.CatFact and ns.CatFact(nil)
    if fact then
      local bank, said = ns.FactCounts()
      self:Print("Cat fact: " .. fact)
      self:Print(ns.color("9d9d9d", string.format("Fact %s of %s in this pass through the bank. /catxp fact for another.", ns.fmtNum(said), ns.fmtNum(bank))))
    end
  elseif cmd == "board" or cmd == "leaderboard" or cmd == "lb" then
    if ns.ToggleBoard then ns.ToggleBoard() end
  elseif cmd == "race" then
    if not ns.Board then return end
    if arg == "stop" or arg == "end" or arg == "cancel" then
      ns.Board:CancelRace()
    else
      ns.Board:StartRace(tonumber(arg) or 30)
    end
  elseif cmd == "shareparty" then
    toggleOption("shareGroup", "Sharing with your party")
    if ns.Board then ns.Board:Broadcast(true) end
  elseif cmd == "shareguild" then
    toggleOption("shareGuild", "Sharing with your guild")
    if ns.Board then ns.Board:Broadcast(true) end
  elseif cmd == "leadmsgs" then
    toggleOption("leadAnnounce", "Lead change messages")
  elseif cmd == "clearrecords" then
    if ns.Board then ns.Board:ClearRecords() end
  elseif cmd == "tiers" then
    self:PrintTiers()
  else
    self:Print("Unknown command '" .. cmd .. "'. Type /catxp help.")
  end
end

SLASH_CATXP1 = "/catxp"
SLASH_CATXP2 = "/cxp"
SlashCmdList["CATXP"] = function(msg) CatXP:SlashCommand(msg) end

---------------------------------------------------------------------------
-- Addon compartment (the addon drawer next to the minimap)
---------------------------------------------------------------------------
function CatXP_OnCompartmentClick(addonName, buttonName)
  if buttonName == "RightButton" then
    if ns.ToggleGraphs then ns.ToggleGraphs() end
  elseif ns.SetShown then
    ns.SetShown(not CatXP.settings.shown)
  end
end

function CatXP_OnCompartmentEnter(addonName, menuButtonFrame)
  if not GameTooltip or not ns.FillTooltip then return end
  GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
  ns.FillTooltip(GameTooltip)
  GameTooltip:Show()
end

function CatXP_OnCompartmentLeave()
  if GameTooltip then GameTooltip:Hide() end
end
