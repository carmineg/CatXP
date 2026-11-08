--[[-------------------------------------------------------------------------
  CatXP graphs window: five tabs.
    Session   rolling XP/hour over the session, with level-up ticks
    Levels    XP/hour per level, average line, level-60 estimate
    Zones     XP/hour per zone this session
    Sessions  XP/hour of past sessions (archived on reset)
    Cats      the tier ladder with every portrait, current cat highlighted
---------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...
local CatXP = ns.CatXP

local W, H = 480, 352
local CHART_W, CHART_H = 456, 190
local SUMMARY_LINES = 6
local REFRESH_EVERY = 5     -- seconds between automatic redraws while open
local GREY = "9d9d9d"

local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

local TABS = {
  { key = "session", text = "Session" },
  { key = "levels",  text = "Levels" },
  { key = "zones",   text = "Zones" },
  { key = "history", text = "Sessions" },
  { key = "cats",    text = "Cats" },
}

local graphs, chart, ladder
local tabButtons = {}
local currentTab = "session"
local lastDraw = -1000
ns.graphDraws = 0

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local function tierColor(rate)
  local tier = CatXP:TierFor(rate)
  local r, g, b = ns.hexToRGB(tier.color)
  return { r, g, b }, tier
end

local function shortName(name, max)
  if #name <= max then return name end
  return name:sub(1, max - 1) .. "."
end

local function tiny(fs)
  if not fs.GetFont then return end
  local path, _, flags = fs:GetFont()
  if path then fs:SetFont(path, 9, flags or "") end
end

local function stamp(t)
  if not t or t <= 0 then return "--" end
  return date("%b %d %H:%M", t)
end

---------------------------------------------------------------------------
-- tab builders: each draws the chart (or ladder) and fills up to six summary lines
---------------------------------------------------------------------------
local function buildSession(lines)
  local st = CatXP:GetStats()
  local points, k = CatXP:RateSeries(5, 110)
  local marks = {}
  for _, mk in ipairs(CatXP.session.marks or {}) do
    marks[#marks + 1] = { index = math.ceil(mk.m / k), text = tostring(mk.level) }
  end
  local color = tierColor(st.rate)
  chart:DrawSeries(points, {
    color = color,
    refLine = st.rate, refText = "avg " .. ns.fmtShort(st.rate),
    xLabels = { "0m", ns.fmtTime(st.secs / 2), ns.fmtTime(st.secs) },
    marks = marks,
    empty = "Track for a couple of minutes and the line appears here.",
  })
  lines[1] = string.format("Rolling 5-minute XP/hour over %s of active time. Green ticks mark level-ups.", ns.fmtTime(st.secs))
  lines[2] = string.format("Session: %s xp, %s xp/h (%s), last 15 min %s xp/h",
    ns.fmtNum(st.xp), ns.fmtShort(st.rate), CatXP:TierName(st.tier), ns.fmtShort(st.recent))
  local best, bestIdx = 0, nil
  for i, v in ipairs(points) do if v > best then best, bestIdx = v, i end end
  if bestIdx then
    lines[3] = string.format("Best 5 minutes: %s xp/h, around %s in", ns.fmtShort(best), ns.fmtTime(bestIdx * k * 60))
  end
  lines[4] = string.format("Kills: %d (avg %s xp)   Quest/other XP: %s", st.kills, ns.fmtNum(st.avgKill or 0), ns.fmtNum(st.otherXP))
  if st.levelUps > 0 then
    lines[5] = string.format("Level-ups this session: %d (level %d to %d)", st.levelUps, st.startLevel or 0, st.level)
  end
  if st.zone then lines[6] = "Current zone: " .. st.zone end
end

local function buildLevels(lines)
  local st = CatXP:GetStats()
  local levels = CatXP:SortedLevels()
  local items = {}
  for i = #levels, 1, -1 do
    local lvl = levels[i]
    local rec = CatXP.db.levels[lvl]
    local rate = rec.secs > 0 and (rec.xp / rec.secs * 3600) or 0
    local color, tier = tierColor(rate)
    items[#items + 1] = {
      value = rate, label = tostring(lvl), color = color, highlight = (lvl == st.level),
      tipTitle = string.format("Level %d%s", lvl, lvl == st.level and " (current)" or ""),
      tipText = string.format("%s, %s xp, %s xp/h (%s), %d kills", ns.fmtTime(rec.secs), ns.fmtNum(rec.xp), ns.fmtShort(rate), tier.name, rec.kills or 0),
    }
  end
  local avg = CatXP:LevelAverages()
  chart:DrawBars(items, {
    refLine = avg and avg.rate or nil,
    refText = avg and ("avg " .. ns.fmtShort(avg.rate)) or nil,
    empty = "No levels tracked yet.",
  })
  lines[1] = "XP/hour per level, coloured by cat. Hover a bar for details. The current level is the bright one."
  if avg then
    lines[2] = string.format("Average of %d finished level%s: %s per level, %s xp/h",
      avg.count, avg.count == 1 and "" or "s", ns.fmtTime(avg.avgSecs), ns.fmtShort(avg.rate))
  end
  local fast, slow
  for lvl, rec in pairs(CatXP.db.levels) do
    if rec.done and rec.secs >= 60 then
      local rate = rec.xp / rec.secs * 3600
      if not fast or rate > fast.rate then fast = { lvl = lvl, rate = rate, secs = rec.secs } end
      if not slow or rate < slow.rate then slow = { lvl = lvl, rate = rate, secs = rec.secs } end
    end
  end
  if fast then
    lines[3] = string.format("Fastest: level %d at %s xp/h (%s).  Slowest: level %d at %s xp/h (%s)",
      fast.lvl, ns.fmtShort(fast.rate), ns.fmtTime(fast.secs), slow.lvl, ns.fmtShort(slow.rate), ns.fmtTime(slow.secs))
  end
  local total = 0
  for _, rec in pairs(CatXP.db.levels) do total = total + rec.secs end
  lines[4] = string.format("Tracked time across levels: %s", ns.fmtTime(total))
  local proj = CatXP:Projection()
  if proj then
    lines[5] = string.format("Level 60 in about %s at %s xp/h (%s xp to go; estimate%s)",
      ns.fmtTime(proj.secs), ns.fmtShort(proj.rate), ns.fmtShort(proj.xp),
      proj.fromLevels and " from your finished levels" or " from this session")
  elseif st.atMax then
    lines[5] = "Max level. The only thing left to grind is reputation."
  end
end

local function buildZones(lines)
  local zones = CatXP:SortedZones()
  local items = {}
  for _, z in ipairs(zones) do
    if #items >= 10 then break end
    if z.secs >= 120 then
      local color, tier = tierColor(z.rate)
      items[#items + 1] = {
        value = z.rate, label = shortName(z.name, 9), color = color,
        tipTitle = z.name,
        tipText = string.format("%s, %s xp, %s xp/h (%s), %d kills", ns.fmtTime(z.secs), ns.fmtNum(z.xp), ns.fmtShort(z.rate), tier.name, z.kills),
      }
    end
  end
  chart:DrawBars(items, { empty = "Zones appear after two minutes of tracking in them.", maxBarWidth = 44, labelWidth = 54 })
  lines[1] = "XP/hour by zone this session (zones with at least 2 minutes). Hover a bar for details."
  for i = 1, math.min(5, #zones) do
    local z = zones[i]
    lines[i + 1] = string.format("%s: %s, %s xp, %s xp/h, %d kills",
      z.name, ns.fmtTime(z.secs), ns.fmtNum(z.xp), z.secs >= 120 and ns.fmtShort(z.rate) or "--", z.kills)
  end
end

local function buildHistory(lines)
  local hist = CatXP.db.history or {}
  local items = {}
  for i = math.max(1, #hist - 19), #hist do
    local h = hist[i]
    local rate = h.secs > 0 and (h.xp / h.secs * 3600) or 0
    local color, tier = tierColor(rate)
    items[#items + 1] = {
      value = rate, label = date("%m/%d", h.startedAt or 0), color = color,
      tipTitle = stamp(h.startedAt),
      tipText = string.format("%s, %s xp, %s xp/h (%s), %d kills, level %d to %d",
        ns.fmtTime(h.secs), ns.fmtNum(h.xp), ns.fmtShort(rate), tier.name, h.kills or 0, h.startLevel or 0, h.endLevel or 0),
    }
  end
  local st = CatXP:GetStats()
  if st.secs >= 60 then
    local color = tierColor(st.rate)
    items[#items + 1] = {
      value = st.rate, label = "now", color = color, highlight = true,
      tipTitle = "Current session",
      tipText = string.format("%s, %s xp, %s xp/h", ns.fmtTime(st.secs), ns.fmtNum(st.xp), ns.fmtShort(st.rate)),
    }
  end
  chart:DrawBars(items, { empty = "Finished sessions show up here after you reset.", maxBarWidth = 40, labelWidth = 34 })
  lines[1] = "XP/hour per session, oldest to newest. A session is kept when you reset it after at least a minute."
  if #hist > 0 then
    local tot, xp, best = 0, 0, nil
    for _, h in ipairs(hist) do
      tot = tot + h.secs
      xp = xp + h.xp
      local r = h.secs > 0 and (h.xp / h.secs * 3600) or 0
      if not best or r > best.rate then best = { rate = r, h = h } end
    end
    lines[2] = string.format("%d session%s: %s active, %s xp, %s xp/h overall",
      #hist, #hist == 1 and "" or "s", ns.fmtTime(tot), ns.fmtNum(xp), ns.fmtShort(tot > 0 and xp / tot * 3600 or 0))
    lines[3] = string.format("Best: %s at %s xp/h", stamp(best.h.startedAt), ns.fmtShort(best.rate))
    for i = 0, 2 do
      local h = hist[#hist - i]
      if not h then break end
      lines[4 + i] = string.format("%s: %s, %s xp, %s xp/h",
        stamp(h.startedAt), ns.fmtTime(h.secs), ns.fmtNum(h.xp), ns.fmtShort(h.secs > 0 and h.xp / h.secs * 3600 or 0))
    end
  end
end

local function buildCats(lines)
  local st = CatXP:GetStats()
  for i, cell in ipairs(ladder.cells) do
    if i == st.tierIndex then cell.glow:Show() else cell.glow:Hide() end
  end
  lines[1] = "The ladder: XP/hour needed for each cat. Hover a cat for its words of wisdom."
  if st.secs > 0 or st.running then
    lines[2] = string.format("This session: %s xp/h = %s", ns.fmtShort(st.rate), CatXP:TierName(st.tier))
    if st.nextTier then
      lines[3] = string.format("Next: %s at %s xp/h (%s more per hour)",
        CatXP:TierName(st.nextTier), ns.fmtK(st.nextTier.min), ns.fmtShort(math.max(0, st.nextTier.min - st.rate)))
    else
      lines[3] = "Top of the ladder. Nothing above you but the rainbow."
    end
  else
    lines[2] = "No session yet. Go gain some XP."
  end
  local avg = CatXP:LevelAverages()
  if avg then
    local tier = CatXP:TierFor(avg.rate)
    lines[4] = string.format("Your finished levels average %s xp/h = %s", ns.fmtShort(avg.rate), CatXP:TierName(tier))
  end
  lines[5] = "Colours follow item rarity: grey, white, green, blue, purple, orange, gold, pink."
end

local BUILDERS = { session = buildSession, levels = buildLevels, zones = buildZones, history = buildHistory, cats = buildCats }

---------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------
local function applyGraphPosition()
  local S = CatXP.settings
  graphs:ClearAllPoints()
  graphs:SetPoint(S.gPoint or "CENTER", UIParent, S.gRelPoint or "CENTER", S.gX or 0, S.gY or 0)
end

local function buildLadder()
  ladder = CreateFrame("Frame", nil, graphs, "BackdropTemplate")
  ladder:SetSize(CHART_W, CHART_H)
  ladder:SetPoint("TOPLEFT", graphs, "TOPLEFT", 12, -56)
  ladder:SetBackdrop(BACKDROP)
  ladder:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
  ladder:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
  ladder:Hide()
  ladder.cells = {}
  local cols, cw, ch = 6, 76, 62
  for i, tier in ipairs(CatXP.TIERS) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local cell = CreateFrame("Frame", nil, ladder)
    cell:SetSize(cw, ch)
    cell:SetPoint("TOPLEFT", ladder, "TOPLEFT", col * cw, -2 - row * ch)
    cell:EnableMouse(true)
    cell.glow = cell:CreateTexture(nil, "BACKGROUND")
    cell.glow:SetAllPoints(cell)
    local r, g, b = ns.hexToRGB(tier.color)
    cell.glow:SetColorTexture(r, g, b, 0.22)
    cell.glow:Hide()
    cell.pic = cell:CreateTexture(nil, "ARTWORK")
    cell.pic:SetSize(36, 36)
    cell.pic:SetPoint("TOP", cell, "TOP", 0, -2)
    cell.pic:SetTexture(tier.image)
    cell.name = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.name:SetPoint("TOP", cell.pic, "BOTTOM", 0, -1)
    cell.name:SetWidth(cw - 2)
    cell.name:SetJustifyH("CENTER")
    if cell.name.SetWordWrap then cell.name:SetWordWrap(false) end
    tiny(cell.name)
    cell.name:SetText(ns.color(tier.color, tier.name))
    cell.min = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.min:SetPoint("TOP", cell.name, "BOTTOM", 0, -1)
    cell.min:SetWidth(cw - 2)
    cell.min:SetJustifyH("CENTER")
    tiny(cell.min)
    local nxt = CatXP.TIERS[i + 1]
    local range
    if i == 1 and nxt then range = "under " .. ns.fmtK(nxt.min)
    elseif nxt then range = string.format("%s to %s", ns.fmtK(tier.min), ns.fmtK(nxt.min))
    else range = ns.fmtK(tier.min) .. "+" end
    cell.min:SetText(ns.color(GREY, i == 1 and range or (ns.fmtK(tier.min) .. "+ xp/h")))
    cell:SetScript("OnEnter", function(c)
      GameTooltip:SetOwner(c, "ANCHOR_TOP")
      GameTooltip:SetText(ns.color(tier.color, tier.name))
      GameTooltip:AddLine(range .. " xp/h", 1, 1, 1)
      GameTooltip:AddLine(tier.quip, 0.7, 0.7, 0.7, true)
      GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
    ladder.cells[i] = cell
  end
end

function ns.BuildGraphs()
  if graphs then return end
  local S = CatXP.settings
  graphs = CreateFrame("Frame", "CatXPGraphFrame", UIParent, "BackdropTemplate")
  graphs:SetSize(W, H)
  graphs:SetFrameStrata("HIGH")
  graphs:SetClampedToScreen(true)
  graphs:SetMovable(true)
  graphs:EnableMouse(true)
  graphs:RegisterForDrag("LeftButton")
  graphs:SetBackdrop(BACKDROP)
  graphs:SetBackdropColor(0, 0, 0, 0.9)
  graphs:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
  graphs:Hide()
  graphs:SetScript("OnDragStart", function(f) f:StartMoving() end)
  graphs:SetScript("OnDragStop", function(f)
    f:StopMovingOrSizing()
    local point, _, relPoint, x, y = f:GetPoint(1)
    if point then S.gPoint, S.gRelPoint, S.gX, S.gY = point, relPoint, x, y end
  end)
  graphs:SetScript("OnShow", function() ns.RefreshGraphs(true) end)
  table.insert(UISpecialFrames, "CatXPGraphFrame")   -- Escape closes it

  graphs.title = graphs:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  graphs.title:SetPoint("TOPLEFT", graphs, "TOPLEFT", 12, -10)
  graphs.title:SetText("CatXP graphs  =^..^=")
  local close = CreateFrame("Button", nil, graphs, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", graphs, "TOPRIGHT", 2, 2)

  for i, tab in ipairs(TABS) do
    local b = CreateFrame("Button", nil, graphs, "UIPanelButtonTemplate")
    b:SetSize(88, 20)
    b:SetPoint("TOPLEFT", graphs, "TOPLEFT", 12 + (i - 1) * 92, -30)
    b:SetText(tab.text)
    b:SetScript("OnClick", function() ns.ShowGraphTab(tab.key) end)
    tabButtons[tab.key] = b
  end

  chart = ns.Chart.New(graphs, CHART_W, CHART_H)
  chart.frame:SetPoint("TOPLEFT", graphs, "TOPLEFT", 12, -56)
  ns.graphChart = chart
  buildLadder()
  ns.graphLadder = ladder

  graphs.lines = {}
  for i = 1, SUMMARY_LINES do
    local fs = graphs:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", graphs, "TOPLEFT", 14, -56 - CHART_H - 8 - (i - 1) * 14)
    fs:SetWidth(W - 28)
    fs:SetJustifyH("LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    graphs.lines[i] = fs
  end

  currentTab = S.graphTab or "session"
  if not BUILDERS[currentTab] then currentTab = "session" end
  for key, b in pairs(tabButtons) do
    if key == currentTab then b:Disable() else b:Enable() end
  end
  ns.ApplyGraphSettings()
end

function ns.ApplyGraphSettings()
  if not graphs then return end
  graphs:SetScale(CatXP.settings.scale or 1)
  applyGraphPosition()
end

function ns.ShowGraphTab(key)
  if not graphs or not BUILDERS[key] then return end
  currentTab = key
  CatXP.settings.graphTab = key
  for k, b in pairs(tabButtons) do
    if k == key then b:Disable() else b:Enable() end
  end
  ns.RefreshGraphs(true)
end

function ns.RefreshGraphs(force)
  if not graphs or not graphs:IsShown() then return end
  local now = GetTime()
  if not force and now - lastDraw < REFRESH_EVERY then return end
  lastDraw = now
  ns.graphDraws = ns.graphDraws + 1
  local lines = {}
  if currentTab == "cats" then
    chart.frame:Hide()
    ladder:Show()
  else
    ladder:Hide()
    chart.frame:Show()
  end
  local ok, err = pcall(BUILDERS[currentTab] or buildSession, lines)
  if not ok then
    lines = { ns.color("ff6060", "Graph error: " .. tostring(err)) }
    chart:Message("Something went wrong drawing this tab.")
  end
  for i = 1, SUMMARY_LINES do graphs.lines[i]:SetText(lines[i] or "") end
end

function ns.GraphsShown()
  return graphs ~= nil and graphs:IsShown()
end

function ns.ToggleGraphs()
  if not graphs then return end
  if graphs:IsShown() then graphs:Hide() else graphs:Show() end
end
