--[[-------------------------------------------------------------------------
  CatXP leaderboard window: three tabs.
    Live      everyone running CatXP in your group or guild, ranked by XP/hour,
              with a podium for the top three
    Records   all-time bests for you, your alts and the cats you have met
    Race      most XP in 10, 30 or 60 minutes, with live standings
---------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...
local CatXP = ns.CatXP
local Board = ns.Board

local W, H = 460, 464
local ROWS = 10
local ROW_H = 22
local RECORD_ROWS = 12
local RECORD_ROW_H = 20
local REFRESH_EVERY = 2
local GREY = "9d9d9d"
local CROWN = "Interface\\GroupFrame\\UI-Group-LeaderIcon"

local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

local TABS = {
  { key = "live",    text = "Live" },
  { key = "records", text = "Records" },
  { key = "race",    text = "Race" },
}

local frame, pages, tabButtons
local currentTab = "live"
local lastDraw = -1000
ns.boardDraws = 0

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function label(parent, font, point, relTo, relPoint, x, y, width, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetPoint(point, relTo or parent, relPoint or point, x or 0, y or 0)
  if width then
    fs:SetWidth(width)
    if fs.SetWordWrap then fs:SetWordWrap(false) end
  end
  fs:SetJustifyH(justify or "LEFT")
  return fs
end

local function colorName(row)
  local _, _, _, hex = Board.ClassColor(row.class)
  return ns.color(hex, row.name)
end

local function rgb(row)
  local r, g, b = Board.ClassColor(row.class)
  return { r, g, b }
end

local function shortName(name, max)
  if #name <= max then return name end
  return name:sub(1, max - 1) .. "."
end

local function trendText(trend)
  if trend == nil then return ns.color(GREY, "--") end
  if trend >= 500 then return ns.color("1eff00", "+" .. ns.fmtShort(trend)) end
  if trend <= -500 then return ns.color("ff6060", "-" .. ns.fmtShort(-trend)) end
  return ns.color(GREY, "=")
end

local function sourceText(row)
  if row.isMe then return "you" end
  return row.source or "?"
end

local function rowTooltip(rf)
  local r = rf.data
  if not r then return end
  GameTooltip:SetOwner(rf, "ANCHOR_RIGHT")
  GameTooltip:SetText(colorName(r))
  GameTooltip:AddLine(string.format("Level %d  %s", r.level or 0, r.tier and ns.color(r.tier.color, r.tier.name) or ""), 1, 1, 1)
  GameTooltip:AddDoubleLine("XP / hour", r.warming and "warming up" or ns.fmtNum(r.rate), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("Session", string.format("%s xp in %s", ns.fmtNum(r.xp), ns.fmtTime(r.secs)), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("Kills", tostring(r.kills or 0), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("Level-ups", tostring(r.levelUps or 0), 0.8, 0.8, 0.8, 1, 1, 1)
  if r.zone then GameTooltip:AddDoubleLine("Zone", r.zone, 0.8, 0.8, 0.8, 1, 1, 1) end
  if (r.bestRate or 0) > 0 then GameTooltip:AddDoubleLine("Best XP / hour", ns.fmtNum(r.bestRate), 0.8, 0.8, 0.8, 1, 1, 1) end
  GameTooltip:AddDoubleLine("Seen via", sourceText(r), 0.8, 0.8, 0.8, 1, 1, 1)
  if r.lastSeen then GameTooltip:AddDoubleLine("Last update", ns.fmtTime(GetTime() - r.lastSeen) .. " ago", 0.8, 0.8, 0.8, 1, 1, 1) end
  GameTooltip:AddLine(r.running and "Tracking" or "Paused", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function recordTooltip(rf)
  local r = rf.data
  if not r then return end
  GameTooltip:SetOwner(rf, "ANCHOR_RIGHT")
  GameTooltip:SetText(colorName(r))
  if r.bestRate > 0 then
    GameTooltip:AddDoubleLine("Best XP / hour", string.format("%s over %s", ns.fmtNum(r.bestRate), r.bestRateSecs and ns.fmtTime(r.bestRateSecs) or "?"), 0.8, 0.8, 0.8, 1, 1, 1)
    if r.bestRateAt then GameTooltip:AddDoubleLine("Set on", date("%b %d %Y", r.bestRateAt), 0.8, 0.8, 0.8, 1, 1, 1) end
  end
  GameTooltip:AddDoubleLine("Best session", ns.fmtNum(r.bestXP) .. " xp", 0.8, 0.8, 0.8, 1, 1, 1)
  if r.bestLevel then GameTooltip:AddDoubleLine("Fastest level", string.format("%d in %s", r.bestLevel, ns.fmtTime(r.bestLevelSecs)), 0.8, 0.8, 0.8, 1, 1, 1) end
  GameTooltip:AddDoubleLine("Longest session", ns.fmtTime(r.longest), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("Sessions", tostring(r.sessions), 0.8, 0.8, 0.8, 1, 1, 1)
  if r.lastSeen then GameTooltip:AddDoubleLine("Last seen", date("%b %d %H:%M", r.lastSeen), 0.8, 0.8, 0.8, 1, 1, 1) end
  GameTooltip:AddLine(r.mine and "One of your characters" or "Met through CatXP", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function newPage()
  local page = CreateFrame("Frame", nil, frame)
  page:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -54)
  page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  page:Hide()
  return page
end

local function pageButton(page, text, x, w, onClick)
  local b = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", x, 10)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

---------------------------------------------------------------------------
-- Live tab
---------------------------------------------------------------------------
local COLS = {
  { key = "rank",  x = 14,  w = 22,  t = "#" },
  { key = "name",  x = 60,  w = 112, t = "Cat" },
  { key = "level", x = 174, w = 28,  t = "Lvl" },
  { key = "tier",  x = 204, w = 86,  t = "Tier" },
  { key = "rate",  x = 292, w = 58,  t = "XP / h", justify = "RIGHT" },
  { key = "xp",    x = 352, w = 62,  t = "Session", justify = "RIGHT" },
  { key = "trend", x = 416, w = 36,  t = "5 min", justify = "RIGHT" },
}

local function buildLive()
  local page = newPage()
  page.podium = {}
  local slots = { { x = W / 2, size = 48 }, { x = W / 2 - 120, size = 38 }, { x = W / 2 + 120, size = 38 } }
  for rank = 1, 3 do
    local slot = CreateFrame("Frame", nil, page)
    slot:SetSize(110, 86)
    slot:SetPoint("TOP", page, "TOPLEFT", slots[rank].x, -2)
    slot:EnableMouse(true)
    slot.pic = slot:CreateTexture(nil, "ARTWORK")
    slot.pic:SetSize(slots[rank].size, slots[rank].size)
    slot.pic:SetPoint("TOP", slot, "TOP", 0, rank == 1 and 0 or -5)
    slot.badge = label(slot, "GameFontNormalSmall", "TOPRIGHT", slot.pic, "TOPLEFT", -1, 0)
    slot.badge:SetText(ns.color(rank == 1 and "ffd700" or (rank == 2 and "c0c0c0" or "cd7f32"), tostring(rank)))
    if rank == 1 then
      slot.crown = slot:CreateTexture(nil, "OVERLAY")
      slot.crown:SetSize(18, 18)
      slot.crown:SetPoint("BOTTOM", slot.pic, "TOP", 0, -4)
      slot.crown:SetTexture(CROWN)
    end
    slot.name = label(slot, "GameFontHighlightSmall", "TOP", slot.pic, "BOTTOM", 0, -2, 110, "CENTER")
    slot.rate = label(slot, "GameFontHighlightSmall", "TOP", slot.name, "BOTTOM", 0, -1, 110, "CENTER")
    slot:SetScript("OnEnter", rowTooltip)
    slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
    slot:Hide()
    page.podium[rank] = slot
  end
  ns.boardPodium = page.podium

  local headerY = -96
  for _, col in ipairs(COLS) do
    local h = label(page, "GameFontNormalSmall", "TOPLEFT", page, "TOPLEFT", col.x, headerY, col.w, col.justify)
    h:SetText(col.t)
  end
  local line = page:CreateTexture(nil, "ARTWORK")
  line:SetPoint("TOPLEFT", page, "TOPLEFT", 12, headerY - 14)
  line:SetSize(W - 24, 1)
  line:SetColorTexture(0.4, 0.4, 0.4, 1)

  page.rows = {}
  for i = 1, ROWS do
    local rf = CreateFrame("Frame", nil, page)
    rf:SetSize(W - 24, ROW_H)
    rf:SetPoint("TOPLEFT", page, "TOPLEFT", 12, headerY - 16 - (i - 1) * ROW_H)
    rf:EnableMouse(true)
    rf.bg = rf:CreateTexture(nil, "BACKGROUND")
    rf.bg:SetAllPoints(rf)
    rf.bg:SetColorTexture(1, 1, 1, 0)
    rf.pic = rf:CreateTexture(nil, "ARTWORK")
    rf.pic:SetSize(18, 18)
    rf.pic:SetPoint("LEFT", rf, "LEFT", 26, 0)
    for _, col in ipairs(COLS) do
      rf[col.key] = label(rf, "GameFontHighlightSmall", "LEFT", rf, "LEFT", col.x - 12, 0, col.w, col.justify)
    end
    rf:SetScript("OnEnter", rowTooltip)
    rf:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rf:Hide()
    page.rows[i] = rf
  end
  ns.boardRows = page.rows

  page.status = label(page, "GameFontHighlightSmall", "TOPLEFT", page, "TOPLEFT", 14, headerY - 18 - ROWS * ROW_H, W - 28)
  page.hint = label(page, "GameFontDisableSmall", "TOPLEFT", page, "TOPLEFT", 14, headerY - 32 - ROWS * ROW_H, W - 28)
  page.hint:SetText("Hover a row for details. Updates every 20 seconds, every 10 during a race.")

  local function toggle(key)
    return function()
      CatXP.settings[key] = not CatXP.settings[key]
      if key == "shareGroup" or key == "shareGuild" then Board:Broadcast(true) end
      ns.RefreshBoard(true)
    end
  end
  page.btnParty = pageButton(page, "Party", 12, 140, toggle("shareGroup"))
  page.btnGuild = pageButton(page, "Guild", 160, 140, toggle("shareGuild"))
  page.btnLead  = pageButton(page, "Lead msgs", 308, 140, toggle("leadAnnounce"))
  return page
end

local function fillLive(page)
  local S = CatXP.settings
  local rows = Board:Rows()
  for rank = 1, 3 do
    local slot, r = page.podium[rank], rows[rank]
    if r then
      slot.pic:SetTexture(r.tier.image)
      slot.name:SetText(colorName(r) .. (r.isMe and ns.color(GREY, " (you)") or ""))
      slot.rate:SetText(r.warming and ns.color(GREY, "warming up") or (ns.fmtShort(r.rate) .. " xp/h"))
      slot.data = r
      slot:Show()
    else
      slot.data = nil
      slot:Hide()
    end
  end
  for i = 1, ROWS do
    local rf, r = page.rows[i], rows[i]
    if r then
      rf.data = r
      if r.isMe then rf.bg:SetColorTexture(1, 0.82, 0, 0.12)
      else rf.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0) end
      rf.pic:SetTexture(r.tier.image)
      rf.rank:SetText(tostring(r.rank))
      rf.name:SetText(colorName(r) .. (r.isMe and ns.color(GREY, " (you)") or ""))
      rf.level:SetText(tostring(r.level or 0))
      rf.tier:SetText(ns.color(r.tier.color, r.tier.name))
      rf.rate:SetText(r.warming and ns.color(GREY, "warming") or ns.fmtShort(r.rate))
      rf.xp:SetText(ns.fmtShort(r.xp))
      rf.trend:SetText(trendText(r.trend))
      rf:Show()
    else
      rf.data = nil
      rf:Hide()
    end
  end
  local n = Board:OnlineCount()
  if n == 0 then
    page.status:SetText(ns.color(GREY, "Nobody else is running CatXP nearby. Group with a friend who has it."))
  else
    page.status:SetText(string.format("%d other cat%s online.  Sharing: party %s, guild %s.", n, n == 1 and "" or "s",
      S.shareGroup and "on" or "off", S.shareGuild and "on" or "off"))
  end
  page.btnParty:SetText("Party: " .. (S.shareGroup and "on" or "off"))
  page.btnGuild:SetText("Guild: " .. (S.shareGuild and "on" or "off"))
  page.btnLead:SetText("Lead msgs: " .. (S.leadAnnounce and "on" or "off"))
end

---------------------------------------------------------------------------
-- Records tab
---------------------------------------------------------------------------
local RCOLS = {
  { key = "rank",     x = 14,  w = 22,  t = "#" },
  { key = "name",     x = 38,  w = 108, t = "Cat" },
  { key = "rate",     x = 148, w = 70,  t = "Best XP / h", justify = "RIGHT" },
  { key = "xp",       x = 222, w = 72,  t = "Best session", justify = "RIGHT" },
  { key = "level",    x = 298, w = 96,  t = "Fastest level" },
  { key = "sessions", x = 396, w = 54,  t = "Sessions", justify = "RIGHT" },
}

local function buildRecords()
  local page = newPage()
  local headerY = -6
  for _, col in ipairs(RCOLS) do
    local h = label(page, "GameFontNormalSmall", "TOPLEFT", page, "TOPLEFT", col.x, headerY, col.w, col.justify)
    h:SetText(col.t)
  end
  local line = page:CreateTexture(nil, "ARTWORK")
  line:SetPoint("TOPLEFT", page, "TOPLEFT", 12, headerY - 14)
  line:SetSize(W - 24, 1)
  line:SetColorTexture(0.4, 0.4, 0.4, 1)
  page.rows = {}
  for i = 1, RECORD_ROWS do
    local rf = CreateFrame("Frame", nil, page)
    rf:SetSize(W - 24, RECORD_ROW_H)
    rf:SetPoint("TOPLEFT", page, "TOPLEFT", 12, headerY - 16 - (i - 1) * RECORD_ROW_H)
    rf:EnableMouse(true)
    rf.bg = rf:CreateTexture(nil, "BACKGROUND")
    rf.bg:SetAllPoints(rf)
    rf.bg:SetColorTexture(1, 1, 1, 0)
    for _, col in ipairs(RCOLS) do
      rf[col.key] = label(rf, "GameFontHighlightSmall", "LEFT", rf, "LEFT", col.x - 12, 0, col.w, col.justify)
    end
    rf:SetScript("OnEnter", recordTooltip)
    rf:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rf:Hide()
    page.rows[i] = rf
  end
  ns.boardRecordRows = page.rows
  page.note = label(page, "GameFontHighlightSmall", "TOPLEFT", page, "TOPLEFT", 14, headerY - 22 - RECORD_ROWS * RECORD_ROW_H, W - 28)
  page.note:SetText(ns.color(GREY, "A session rate needs 30 minutes to count. Your alts are on here too."))
  page.note2 = label(page, "GameFontDisableSmall", "TOPLEFT", page, "TOPLEFT", 14, headerY - 36 - RECORD_ROWS * RECORD_ROW_H, W - 28)
  page.note2:SetText("Friends' bests arrive with their CatXP updates. Fastest level counts only levels tracked from the first XP.")
  page.btnClear = pageButton(page, "Clear records", 12, 120, function() StaticPopup_Show("CATXP_CLEAR_RECORDS") end)
  return page
end

local function fillRecords(page)
  local rows = Board:RecordRows()
  for i = 1, RECORD_ROWS do
    local rf, r = page.rows[i], rows[i]
    if r then
      rf.data = r
      if r.isMe then rf.bg:SetColorTexture(1, 0.82, 0, 0.12) else rf.bg:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.04 or 0) end
      rf.rank:SetText(tostring(r.rank))
      rf.name:SetText(colorName(r) .. (r.isMe and ns.color(GREY, " (you)") or ""))
      if r.bestRate > 0 then
        local tier = CatXP:TierFor(r.bestRate)
        rf.rate:SetText(ns.color(tier.color, ns.fmtShort(r.bestRate)))
      else
        rf.rate:SetText(ns.color(GREY, "--"))
      end
      rf.xp:SetText(r.bestXP > 0 and ns.fmtShort(r.bestXP) or ns.color(GREY, "--"))
      rf.level:SetText(r.bestLevel and string.format("%d in %s", r.bestLevel, ns.fmtTime(r.bestLevelSecs)) or ns.color(GREY, "--"))
      rf.sessions:SetText(tostring(r.sessions))
      rf:Show()
    else
      rf.data = nil
      rf:Hide()
    end
  end
end

StaticPopupDialogs["CATXP_CLEAR_RECORDS"] = {
  text = "CatXP: clear the leaderboard records for every cat on this account?",
  button1 = YES,
  button2 = NO,
  OnAccept = function() Board:ClearRecords() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Race tab
---------------------------------------------------------------------------
local function buildRace()
  local page = newPage()
  page.status = label(page, "GameFontNormalLarge", "TOP", page, "TOP", 0, -8, W - 24, "CENTER")
  page.sub = label(page, "GameFontHighlightSmall", "TOP", page, "TOP", 0, -34, W - 24, "CENTER")
  page.chart = ns.Chart.New(page, W - 24, 150)
  page.chart.frame:SetPoint("TOPLEFT", page, "TOPLEFT", 12, -52)
  page.lines = {}
  for i = 1, 6 do
    page.lines[i] = label(page, "GameFontHighlightSmall", "TOPLEFT", page, "TOPLEFT", 14, -210 - (i - 1) * 14, W - 28)
  end
  page.hint = label(page, "GameFontDisableSmall", "TOPLEFT", page, "TOPLEFT", 14, -298, W - 28)
  page.hint:SetText("Everyone in the group with CatXP joins automatically. Most XP wins.")
  page.btn10 = pageButton(page, "10 min", 12, 86, function() Board:StartRace(10) end)
  page.btn30 = pageButton(page, "30 min", 102, 86, function() Board:StartRace(30) end)
  page.btn60 = pageButton(page, "60 min", 192, 86, function() Board:StartRace(60) end)
  page.btnStop = pageButton(page, "Stop race", 336, 104, function() Board:CancelRace() end)
  ns.boardRace = page
  return page
end

local function fillRace(page)
  local race = Board.race
  local active = race and race.active
  local rows, title, sub
  if active then
    local left = Board:RaceLeft()
    rows = Board:RaceRows()
    title = string.format("%d:%02d left", math.floor(left / 60), math.floor(left % 60))
    sub = string.format("Started by %s.  %d minutes, most XP wins.", race.starter, race.minutes)
  elseif race and race.cancelled then
    rows = race.results or {}
    title = "Race called off"
    sub = string.format("The standings when it stopped. Started by %s for %d minutes.", race.starter, race.minutes)
  elseif Board.db.lastRace then
    local last = Board.db.lastRace
    rows = last.results
    title = "Last race"
    sub = string.format("%d minutes on %s, started by %s.", last.minutes, date("%b %d %H:%M", last.startedAt or 0), last.starter or "?")
  else
    rows = {}
    title = "No race yet"
    sub = "Pick a length below. Everyone in the group with CatXP races. Most XP wins."
  end
  page.status:SetText(title)
  page.sub:SetText(sub)
  local items = {}
  for i, r in ipairs(rows) do
    if i > 8 then break end
    items[#items + 1] = {
      value = r.xp, label = shortName(r.name, 10), color = rgb(r), highlight = r.isMe,
      tipTitle = colorName(r), tipText = ns.fmtNum(r.xp) .. " xp",
    }
  end
  page.chart:DrawBars(items, { empty = "Start a race to fill this chart.", maxBarWidth = 48, labelWidth = 60, fmt = ns.fmtShort })
  for i = 1, 6 do
    local r = rows[i]
    if r then
      page.lines[i]:SetText(string.format("%d.  %s  %s xp%s", i, colorName(r), ns.fmtShort(r.xp), r.isMe and ns.color(GREY, "  (you)") or ""))
    else
      page.lines[i]:SetText("")
    end
  end
  local canStart = not active
  if canStart then page.btn10:Enable() else page.btn10:Disable() end
  if canStart then page.btn30:Enable() else page.btn30:Disable() end
  if canStart then page.btn60:Enable() else page.btn60:Disable() end
  if active and race.mine then page.btnStop:Enable() else page.btnStop:Disable() end
end

local FILL = { live = fillLive, records = fillRecords, race = fillRace }

---------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------
local function applyPosition()
  local S = CatXP.settings
  frame:ClearAllPoints()
  frame:SetPoint(S.bPoint or "CENTER", UIParent, S.bRelPoint or "CENTER", S.bX or 0, S.bY or 0)
end

function ns.BuildBoard()
  if frame then return end
  local S = CatXP.settings
  frame = CreateFrame("Frame", "CatXPBoardFrame", UIParent, "BackdropTemplate")
  frame:SetSize(W, H)
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0, 0, 0, 0.9)
  frame:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
  frame:Hide()
  frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
  frame:SetScript("OnDragStop", function(f)
    f:StopMovingOrSizing()
    local point, _, relPoint, x, y = f:GetPoint(1)
    if point then S.bPoint, S.bRelPoint, S.bX, S.bY = point, relPoint, x, y end
  end)
  frame:SetScript("OnShow", function()
    Board:Query()
    ns.RefreshBoard(true)
  end)
  table.insert(UISpecialFrames, "CatXPBoardFrame")   -- Escape closes it

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -10)
  frame.title:SetText("CatXP leaderboard  =^..^=")
  local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)

  tabButtons = {}
  for i, tab in ipairs(TABS) do
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(100, 20)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + (i - 1) * 104, -30)
    b:SetText(tab.text)
    b:SetScript("OnClick", function() ns.ShowBoardTab(tab.key) end)
    tabButtons[tab.key] = b
  end

  pages = { live = buildLive(), records = buildRecords(), race = buildRace() }
  currentTab = S.boardTab or "live"
  if not pages[currentTab] then currentTab = "live" end
  for key, b in pairs(tabButtons) do
    if key == currentTab then b:Disable() else b:Enable() end
  end
  pages[currentTab]:Show()
  ns.ApplyBoardSettings()
end

function ns.ApplyBoardSettings()
  if not frame then return end
  frame:SetScale(CatXP.settings.scale or 1)
  applyPosition()
end

function ns.ShowBoardTab(key)
  if not frame or not pages[key] then return end
  for k, page in pairs(pages) do
    if k == key then page:Show() else page:Hide() end
  end
  for k, b in pairs(tabButtons) do
    if k == key then b:Disable() else b:Enable() end
  end
  currentTab = key
  CatXP.settings.boardTab = key
  ns.RefreshBoard(true)
end

function ns.RefreshBoard(force)
  if not frame or not frame:IsShown() then return end
  local now = GetTime()
  if not force and now - lastDraw < REFRESH_EVERY then return end
  lastDraw = now
  ns.boardDraws = ns.boardDraws + 1
  local ok, err = pcall(FILL[currentTab] or fillLive, pages[currentTab])
  if not ok then
    CatXP:Print(ns.color("ff6060", "Leaderboard error: " .. tostring(err)))
  end
end

function ns.BoardShown()
  return frame ~= nil and frame:IsShown()
end

function ns.ToggleBoard()
  if not frame then return end
  if frame:IsShown() then frame:Hide() else frame:Show() end
end
