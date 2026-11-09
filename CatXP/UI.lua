--[[-------------------------------------------------------------------------
  CatXP UI: the small window with its portrait, rate windows, gold row and
  control buttons, the tooltip, the right-click menu, and the details panel
  (session summary, XP bar chart, per-level table, gold block).
---------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...
local CatXP = ns.CatXP

local MAIN_W, MAIN_H = 310, 94
local WINDOW_ROWS, ROW_H = 5, 13          -- the rate windows under the status lines
local WINDOWS_TOP = -70                   -- y of the separator above the first row
local WINDOWS_H = WINDOW_ROWS * ROW_H + 8 -- how much taller the window is with them shown
local BUTTONS_Y = -72                     -- the footer buttons, rate windows hidden
local GOLD_H = 14                         -- the gold row (/catxp gold) adds this much
local DETAILS_W, DETAILS_H = 340, 494
local DETAILS_GOLD_H = 76                 -- the gold block at the foot of the details panel
local PACE_CHOICES = { 1, 2, 3, 5, 10, 15, 30 }   -- minutes, the "Chat pace" submenu
local CHART_W, CHART_H = 316, 64
local CHART_BARS, CHART_MINUTES = 12, 5   -- 12 bars of 5 minutes = the last active hour
local MAX_LEVEL_ROWS = 10
local GREY = "9d9d9d"

local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

local main, details

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

local function savePosition()
  local S = CatXP.settings
  local point, _, relPoint, x, y = main:GetPoint(1)
  if point then S.point, S.relPoint, S.x, S.y = point, relPoint, x, y end
end

local function applyPosition()
  local S = CatXP.settings
  main:ClearAllPoints()
  main:SetPoint(S.point or "CENTER", UIParent, S.relPoint or "CENTER", S.x or 0, S.y or 0)
end

local function statusText(st)
  if st.running then return ns.color("1eff00", "tracking") end
  if st.manualPause then return ns.color("ff6060", "paused") end
  return ns.color(GREY, "idle")
end

-- Details sit under the window, or above it when the window is in the lower half of the screen.
local function placeDetails()
  details:ClearAllPoints()
  local bottom = main:GetBottom()
  local screenMid = (UIParent:GetHeight() or 768) * (UIParent:GetEffectiveScale() or 1) / 2
  if bottom and (bottom * (main:GetEffectiveScale() or 1)) < screenMid then
    details:SetPoint("BOTTOM", main, "TOP", 0, 6)
  else
    details:SetPoint("TOP", main, "BOTTOM", 0, -6)
  end
end

---------------------------------------------------------------------------
-- right-click menu (modern Menu API; older clients fall back to start/pause)
---------------------------------------------------------------------------
local function toggleSetting(key)
  CatXP.settings[key] = not CatXP.settings[key]
  if key == "locked" or key == "windowsShown" then ns.ApplySettings() end
  ns.Refresh()
end

local function openMenu(owner)
  if not (MenuUtil and MenuUtil.CreateContextMenu) then
    CatXP:Toggle()
    return
  end
  local S = CatXP.settings
  MenuUtil.CreateContextMenu(owner, function(_, root)
    root:CreateTitle("CatXP =^.^=")
    root:CreateButton(CatXP:IsRunning() and "Pause tracking" or "Start tracking", function() CatXP:Toggle() end)
    root:CreateButton("Reset session", function() CatXP:Reset() end)
    root:CreateButton((details and details:IsShown()) and "Hide details" or "Show details", function() ns.ToggleDetails() end)
    root:CreateButton((ns.GraphsShown and ns.GraphsShown()) and "Hide graphs" or "Show graphs", function() ns.ToggleGraphs() end)
    root:CreateButton((ns.BoardShown and ns.BoardShown()) and "Hide leaderboard" or "Show leaderboard", function() ns.ToggleBoard() end)
    root:CreateButton("A cat fact, please", function() CatXP:SlashCommand("fact") end)
    root:CreateDivider()
    root:CreateCheckbox("Auto-start on XP gain", function() return S.autoStart == true end, function() toggleSetting("autoStart") end)
    root:CreateCheckbox("Announce tier promotions", function() return S.announceTiers == true end, function() toggleSetting("announceTiers") end)
    root:CreateCheckbox("Announce to party chat", function() return S.partyAnnounce == true end, function() toggleSetting("partyAnnounce") end)
    -- how often chat hears from CatXP on its own: a submenu of radio buttons
    local pace = root:CreateButton("Chat pace")
    if pace and pace.CreateRadio then
      for _, minutes in ipairs(PACE_CHOICES) do
        pace:CreateRadio("One line every " .. ns.paceText(minutes),
          function() return CatXP:PaceSecs() == minutes * 60 end,
          function() S.chatPace = minutes end, minutes)
      end
    end
    root:CreateCheckbox("Show rate windows", function() return S.windowsShown ~= false end, function() toggleSetting("windowsShown") end)
    root:CreateCheckbox("Track gold per hour", function() return S.goldTrack == true end, function() CatXP:SetGoldTracking(not CatXP:GoldOn()) end)
    root:CreateCheckbox("Lock window", function() return S.locked == true end, function() toggleSetting("locked") end)
    root:CreateDivider()
    root:CreateButton("Clear history...", function() StaticPopup_Show("CATXP_CLEAR_HISTORY") end)
    root:CreateButton("Hide window (/catxp show)", function() ns.SetShown(false) end)
  end)
end

StaticPopupDialogs["CATXP_CLEAR_HISTORY"] = {
  text = "CatXP: clear the per-level and session history for this character?",
  button1 = YES,
  button2 = NO,
  OnAccept = function() CatXP:ClearHistory() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

---------------------------------------------------------------------------
-- tooltip
---------------------------------------------------------------------------
function ns.FillTooltip(tt)
  local st = CatXP:GetStats()
  local tier = st.tier
  local L = { 0.8, 0.8, 0.8 }
  local R = { 1, 1, 1 }
  tt:AddDoubleLine("CatXP =^.^=", "v" .. tostring(CatXP.VERSION), 1, 0.8, 0.4, 0.6, 0.6, 0.6)
  tt:AddLine(ns.tierIcon(tier, 28) .. " " .. ns.color(tier.color, tier.name) .. "  " .. ns.color(GREY, tier.quip), 1, 1, 1)
  tt:AddLine(" ")
  local started = (st.startedAt and st.startedAt > 0) and date("%H:%M", st.startedAt) or "--"
  tt:AddDoubleLine("Session", string.format("%s (since %s)", ns.fmtTime(st.secs), started), L[1], L[2], L[3], R[1], R[2], R[3])
  tt:AddDoubleLine("XP gained", ns.fmtNum(st.xp), L[1], L[2], L[3], R[1], R[2], R[3])
  tt:AddDoubleLine("XP / hour", st.warming and "warming up" or ns.fmtNum(st.rate), L[1], L[2], L[3], R[1], R[2], R[3])
  tt:AddDoubleLine("Last 15 min", ns.fmtNum(st.recent) .. " / h", L[1], L[2], L[3], R[1], R[2], R[3])
  local hour = st.windows and st.windows[2]
  if hour and hour.secs > 0 then
    tt:AddDoubleLine("Last hour", ns.fmtNum(hour.rate) .. " / h", L[1], L[2], L[3], R[1], R[2], R[3])
  end
  tt:AddDoubleLine("Time to level", st.atMax and "max level" or (st.ttl and ns.fmtTime(st.ttl) or "--"), L[1], L[2], L[3], R[1], R[2], R[3])
  if st.kills > 0 then
    tt:AddDoubleLine("Kills", string.format("%d (avg %s xp)", st.kills, ns.fmtNum(st.avgKill or 0)), L[1], L[2], L[3], R[1], R[2], R[3])
  else
    tt:AddDoubleLine("Kills", "0", L[1], L[2], L[3], R[1], R[2], R[3])
  end
  if st.ktl then tt:AddDoubleLine("Kills to level", ns.fmtNum(st.ktl), L[1], L[2], L[3], R[1], R[2], R[3]) end
  tt:AddDoubleLine("Quest / other XP", ns.fmtNum(st.otherXP), L[1], L[2], L[3], R[1], R[2], R[3])
  if st.zone then tt:AddDoubleLine("Zone", st.zone, L[1], L[2], L[3], R[1], R[2], R[3]) end
  tt:AddLine(" ")
  tt:AddDoubleLine(string.format("Level %d", st.level),
    string.format("%.1f%%  (%s / %s)", st.pct, ns.fmtNum(st.xpCur), ns.fmtNum(st.xpMax)), L[1], L[2], L[3], R[1], R[2], R[3])
  if st.rested and st.rested > 0 then
    tt:AddDoubleLine("Rested XP", ns.fmtNum(st.rested), L[1], L[2], L[3], R[1], R[2], R[3])
  end
  tt:AddDoubleLine("This level", string.format("%s, %s xp/h", ns.fmtTime(st.levelSecs), ns.fmtShort(st.levelRate)), L[1], L[2], L[3], R[1], R[2], R[3])
  local today = st.windows and st.windows[5]
  if today and today.secs > 0 then
    tt:AddDoubleLine("Today", string.format("%s, %s xp, %s xp/h", ns.fmtTime(today.secs), ns.fmtShort(today.xp), ns.fmtShort(today.rate)), L[1], L[2], L[3], R[1], R[2], R[3])
  end
  local avg = CatXP:LevelAverages()
  if avg then
    tt:AddDoubleLine("Levels done", string.format("%d, avg %s at %s xp/h", avg.count, ns.fmtTime(avg.avgSecs), ns.fmtShort(avg.rate)), L[1], L[2], L[3], R[1], R[2], R[3])
  end
  local gold = st.gold
  if gold then   -- only with /catxp gold
    tt:AddLine(" ")
    tt:AddDoubleLine("Gold / hour", gold.ready and ns.fmtMoney(gold.rate) or "warming up", L[1], L[2], L[3], R[1], R[2], R[3])
    tt:AddDoubleLine("Gold earned", string.format("%s in %s", ns.fmtMoney(gold.total), ns.fmtTime(gold.secs)), L[1], L[2], L[3], R[1], R[2], R[3])
    tt:AddDoubleLine("Coin / quests / items", string.format("%s / %s / %s", ns.fmtMoney(gold.loot), ns.fmtMoney(gold.quest), ns.fmtMoney(gold.items)), L[1], L[2], L[3], R[1], R[2], R[3])
    local recent, lastHour, day = gold.windows[1], gold.windows[2], gold.windows[5]
    if recent.ready then
      tt:AddDoubleLine("Gold, last 15 min", ns.fmtMoney(recent.rate) .. " / h", L[1], L[2], L[3], R[1], R[2], R[3])
    end
    if lastHour.ready then
      tt:AddDoubleLine("Gold, last hour", ns.fmtMoney(lastHour.rate) .. " / h", L[1], L[2], L[3], R[1], R[2], R[3])
    end
    if day.secs > 0 then
      tt:AddDoubleLine("Gold today", string.format("%s in %s", ns.fmtMoney(day.gold), ns.fmtTime(day.secs)), L[1], L[2], L[3], R[1], R[2], R[3])
    end
  end
  tt:AddLine(" ")
  if st.nextTier then
    tt:AddLine(string.format("Next cat: %s %s at %s xp/h", ns.tierIcon(st.nextTier, 16), ns.color(st.nextTier.color, st.nextTier.name), ns.fmtK(st.nextTier.min)), 0.8, 0.8, 0.8)
  else
    tt:AddLine("Top of the food chain.", 0.8, 0.8, 0.8)
  end
  tt:AddLine("Left-click: details   Shift-click: graphs   Ctrl-click: leaderboard   Right-click: menu", 0.5, 0.5, 0.5)
end

---------------------------------------------------------------------------
-- main window
---------------------------------------------------------------------------
local function footerButton(text, x, onClick)
  local b = CreateFrame("Button", nil, main)
  b:SetSize(52, 16)
  b.x = x
  b:SetPoint("TOPLEFT", main, "TOPLEFT", x, BUTTONS_Y)
  main.footer = main.footer or {}
  main.footer[#main.footer + 1] = b
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
  b.label:SetText(text)
  b:SetScript("OnClick", onClick)
  b:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 1, 1) end)
  b:SetScript("OnLeave", function(self) self.label:SetTextColor(1, 0.82, 0) end)
  return b
end

local function buildMain()
  main = CreateFrame("Button", "CatXPMainFrame", UIParent, "BackdropTemplate")
  main:SetSize(MAIN_W, MAIN_H)
  main:SetFrameStrata("MEDIUM")
  main:SetClampedToScreen(true)
  main:SetMovable(true)
  main:EnableMouse(true)
  main:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  main:RegisterForDrag("LeftButton")
  main:SetBackdrop(BACKDROP)
  main:SetBackdropColor(0, 0, 0, 0.78)
  main:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)

  main.icon = main:CreateTexture(nil, "ARTWORK")
  main.icon:SetSize(44, 44)
  main.icon:SetPoint("TOPLEFT", main, "TOPLEFT", 8, -10)

  main.title = label(main, "GameFontNormalSmall", "TOPLEFT", main, "TOPLEFT", 60, -8)
  main.title:SetText("CatXP =^.^=")
  main.status = label(main, "GameFontHighlightSmall", "TOPRIGHT", main, "TOPRIGHT", -8, -9, 90, "RIGHT")
  main.tierLine = label(main, "GameFontHighlight", "TOPLEFT", main, "TOPLEFT", 60, -24, MAIN_W - 68)
  main.line2 = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 60, -40, MAIN_W - 68)
  main.line3 = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 60, -54, MAIN_W - 68)

  -- the rate windows: the same XP/hour over five spans, one row each (/catxp windows hides them)
  main.sep = main:CreateTexture(nil, "ARTWORK")
  main.sep:SetColorTexture(0.45, 0.45, 0.45, 0.6)
  main.sep:SetSize(MAIN_W - 16, 1)
  main.sep:SetPoint("TOPLEFT", main, "TOPLEFT", 8, WINDOWS_TOP + 3)
  main.windows = {}
  for i = 1, WINDOW_ROWS do
    local y = WINDOWS_TOP - (i - 1) * ROW_H - 2
    local row = {}
    row.label = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 10, y, 44)
    row.label:SetTextColor(0.7, 0.7, 0.7)
    row.time  = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 56, y, 44)
    row.xp    = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 102, y, 52)
    row.rate  = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 156, y, 50)
    row.icon  = main:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(12, 12)
    row.icon:SetPoint("TOPLEFT", main, "TOPLEFT", 208, y + 1)
    row.cat   = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 223, y, MAIN_W - 229)
    main.windows[i] = row
  end

  -- the gold row (/catxp gold): counted time, coin earned and coin per hour for the session.
  -- layoutMain puts it under the rate windows, or under the status lines when those are hidden.
  main.gold = {}
  main.gold.label = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 10, WINDOWS_TOP - 2, 44)
  main.gold.label:SetText(ns.color("ffd100", "Gold"))
  main.gold.time  = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 56, WINDOWS_TOP - 2, 44)
  main.gold.total = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 102, WINDOWS_TOP - 2, 78)
  main.gold.rate  = label(main, "GameFontHighlightSmall", "TOPLEFT", main, "TOPLEFT", 182, WINDOWS_TOP - 2, MAIN_W - 190)
  main.gold.x = { label = 10, time = 56, total = 102, rate = 182 }

  main.btnStart   = footerButton("Start", 25, function() CatXP:Toggle() end)
  main.btnReset   = footerButton("Reset", 77, function() CatXP:Reset() end)
  main.btnDetails = footerButton("Details", 129, function() ns.ToggleDetails() end)
  main.btnGraphs  = footerButton("Graphs", 181, function() ns.ToggleGraphs() end)
  main.btnBoard   = footerButton("Board", 233, function() ns.ToggleBoard() end)

  main:SetScript("OnDragStart", function(f)
    if not CatXP.settings.locked then f:StartMoving() end
  end)
  main:SetScript("OnDragStop", function(f)
    f:StopMovingOrSizing()
    savePosition()
  end)
  main:SetScript("OnClick", function(f, button)
    if button == "RightButton" then
      openMenu(f)
    elseif IsShiftKeyDown and IsShiftKeyDown() then
      ns.ToggleGraphs()
    elseif IsControlKeyDown and IsControlKeyDown() then
      ns.ToggleBoard()
    else
      ns.ToggleDetails()
    end
  end)
  main:SetScript("OnEnter", function(f)
    GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
    ns.FillTooltip(GameTooltip)
    GameTooltip:Show()
  end)
  main:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Grow or shrink the window for the rate windows and the gold row, and move the buttons
-- under them.
local function layoutMain()
  if not main or not main.windows then return end
  local show = CatXP.settings.windowsShown ~= false
  local gold = CatXP:GoldOn()
  local extra = (show and WINDOWS_H or 0) + (gold and GOLD_H or 0)
  main:SetHeight(MAIN_H + extra)
  for _, b in ipairs(main.footer or {}) do
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", main, "TOPLEFT", b.x, BUTTONS_Y - extra)
  end
  local function setShown(region, flag) if flag then region:Show() else region:Hide() end end
  setShown(main.sep, show or gold)
  for _, row in ipairs(main.windows) do
    for _, part in pairs(row) do setShown(part, show) end
  end
  local goldY = WINDOWS_TOP - 2 - (show and WINDOW_ROWS * ROW_H or 0)
  for key, x in pairs(main.gold.x) do
    local part = main.gold[key]
    part:ClearAllPoints()
    part:SetPoint("TOPLEFT", main, "TOPLEFT", x, goldY)
    setShown(part, gold)
  end
end

local function fillGold(st)
  local g = st.gold
  if not g or not main.gold then return end
  local row = main.gold
  row.total:SetText(ns.fmtMoney(g.total))
  if g.secs < 1 then
    row.time:SetText(ns.color(GREY, "--"))
    row.rate:SetText(ns.color(GREY, "--"))
  else
    row.time:SetText(ns.fmtTime(g.secs))
    row.rate:SetText(g.ready and (ns.fmtMoney(g.rate) .. "/h") or ns.color(GREY, "warming"))
  end
end

local function fillWindows(st)
  if not main.windows or CatXP.settings.windowsShown == false then return end
  for i, w in ipairs(st.windows or CatXP:Windows()) do
    local row = main.windows[i]
    if not row then break end
    row.label:SetText(w.short)
    if w.secs < 1 then
      row.time:SetText(ns.color(GREY, "--"))
      row.xp:SetText("")
      row.rate:SetText(ns.color(GREY, "--"))
      row.icon:Hide()
      row.cat:SetText("")
    else
      row.time:SetText(ns.fmtTime(w.secs))
      row.xp:SetText(ns.fmtShort(w.xp) .. " xp")
      if not w.ready then
        row.rate:SetText(ns.color(GREY, "warming"))
        row.icon:Hide()
        row.cat:SetText("")
      else
        row.rate:SetText(ns.color(w.tier.color, ns.fmtShort(w.rate) .. "/h"))
        row.icon:SetTexture(w.tier.image)
        row.icon:Show()
        row.cat:SetText(ns.color(w.tier.color, w.tier.name))
      end
    end
  end
end

function ns.Refresh()
  if not main then return end
  local st = CatXP:GetStats()
  local tier = st.tier
  local r, g, b = ns.hexToRGB(tier.color)
  main:SetBackdropBorderColor(r, g, b, 1)
  main.icon:SetTexture(tier.image)
  main.status:SetText(statusText(st))

  if st.secs < 1 and not st.running then
    main.tierLine:SetText(ns.color(tier.color, tier.name) .. "  " .. ns.color(GREY, "no session yet"))
  elseif st.warming then
    local left = math.max(0, math.ceil(CatXP.WARMUP_SECS - st.secs))
    main.tierLine:SetText(ns.color("ffffff", "Warming up...") .. ns.color(GREY, string.format("  %ds", left)))
  else
    main.tierLine:SetText(ns.color(tier.color, tier.name) .. "  " .. ns.color("ffffff", ns.fmtShort(st.rate) .. " xp/h"))
  end

  local ttl
  if st.atMax then ttl = "max level"
  elseif st.ttl then ttl = ns.fmtTime(st.ttl) .. " to lvl"
  else ttl = "-- to lvl" end
  main.line2:SetText(string.format("%s  |  %s xp  |  %s", ns.fmtTime(st.secs), ns.fmtNum(st.xp), ttl))

  local kills
  if st.atMax then kills = "time for a nap"
  elseif st.ktl then kills = ns.fmtNum(st.ktl) .. " kills to lvl"
  elseif st.kills > 0 then kills = st.kills .. " kills"
  else kills = "no kills yet" end
  main.line3:SetText(string.format("Lv %d  %.1f%%  |  %s", st.level, st.pct, kills))

  fillWindows(st)
  fillGold(st)
  main.btnStart.label:SetText(st.running and "Pause" or "Start")

  if details and details:IsShown() then ns.RefreshDetails(st) end
  if ns.RefreshGraphs then ns.RefreshGraphs() end
  if ns.RefreshBoard then ns.RefreshBoard() end
end

---------------------------------------------------------------------------
-- details panel
---------------------------------------------------------------------------
local function buildDetails()
  details = CreateFrame("Frame", "CatXPDetailsFrame", UIParent, "BackdropTemplate")
  details:SetSize(DETAILS_W, DETAILS_H)
  details:SetFrameStrata("HIGH")
  details:SetClampedToScreen(true)
  details:EnableMouse(true)
  details:SetBackdrop(BACKDROP)
  details:SetBackdropColor(0, 0, 0, 0.88)
  details:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
  details:Hide()
  details:SetScript("OnShow", function() CatXP.settings.detailsShown = true end)
  details:SetScript("OnHide", function() CatXP.settings.detailsShown = false end)
  table.insert(UISpecialFrames, "CatXPDetailsFrame")   -- Escape closes it

  details.title = label(details, "GameFontNormal", "TOPLEFT", details, "TOPLEFT", 10, -10)
  details.title:SetText("CatXP details  =^..^=")
  local close = CreateFrame("Button", nil, details, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", details, "TOPRIGHT", 2, 2)
  details.portrait = details:CreateTexture(nil, "ARTWORK")
  details.portrait:SetSize(40, 40)
  details.portrait:SetPoint("TOPRIGHT", details, "TOPRIGHT", -30, -6)

  -- session summary
  local y = -34
  details.sectionSession = label(details, "GameFontNormalSmall", "TOPLEFT", details, "TOPLEFT", 10, y)
  details.sectionSession:SetText("Session")
  y = y - 16
  details.rows = {}
  local function addRow(key, text)
    local l = label(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", 14, y, 108)
    l:SetText(text)
    l:SetTextColor(0.7, 0.7, 0.7)
    details.rows[key] = label(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", 124, y, DETAILS_W - 134)
    y = y - 14
  end
  addRow("started", "Started")
  addRow("active", "Active time")
  addRow("xp", "XP gained")
  addRow("rate", "XP / hour")
  addRow("recent", "Last 15 min")
  addRow("ttl", "Time to level")
  addRow("kills", "Kills")
  addRow("other", "Quest / other XP")

  -- chart
  y = y - 6
  details.chartTitle = label(details, "GameFontNormalSmall", "TOPLEFT", details, "TOPLEFT", 10, y)
  details.chartTitle:SetText("XP per 5 minutes (last active hour)")
  details.chartMax = label(details, "GameFontHighlightSmall", "TOPRIGHT", details, "TOPRIGHT", -12, y, 130, "RIGHT")
  y = y - 16
  local chart = CreateFrame("Frame", nil, details, "BackdropTemplate")
  chart:SetSize(CHART_W, CHART_H)
  chart:SetPoint("TOPLEFT", details, "TOPLEFT", 12, y)
  chart:SetBackdrop(BACKDROP)
  chart:SetBackdropColor(0.08, 0.08, 0.08, 0.9)
  chart:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
  chart.bars = {}
  local slot = (CHART_W - 8) / CHART_BARS
  for i = 1, CHART_BARS do
    local bar = chart:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 4 + (i - 1) * slot + 1, 2)
    bar:SetSize(slot - 3, 1)
    bar:SetColorTexture(0.5, 0.5, 0.5, 1)
    bar:Hide()
    chart.bars[i] = bar
  end
  details.chart = chart
  y = y - CHART_H - 2
  details.axisL = label(details, "GameFontDisableSmall", "TOPLEFT", details, "TOPLEFT", 12, y)
  details.axisL:SetText("60 min ago")
  details.axisR = label(details, "GameFontDisableSmall", "TOPRIGHT", details, "TOPRIGHT", -12, y, 100, "RIGHT")
  details.axisR:SetText("now")
  y = y - 20

  -- per-level table
  details.sectionLevels = label(details, "GameFontNormalSmall", "TOPLEFT", details, "TOPLEFT", 10, y)
  details.sectionLevels:SetText("Per level")
  y = y - 16
  local cols = {
    { x = 14,  w = 36, t = "Lvl" },
    { x = 52,  w = 76, t = "Time" },
    { x = 130, w = 66, t = "XP" },
    { x = 198, w = 72, t = "XP / h" },
    { x = 272, w = 56, t = "Kills" },
  }
  for _, col in ipairs(cols) do
    local h = label(details, "GameFontNormalSmall", "TOPLEFT", details, "TOPLEFT", col.x, y, col.w)
    h:SetText(col.t)
  end
  y = y - 14
  details.levelRows = {}
  for r = 1, MAX_LEVEL_ROWS do
    local row = {}
    for c, col in ipairs(cols) do
      row[c] = label(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", col.x, y, col.w)
    end
    details.levelRows[r] = row
    y = y - 13
  end
  y = y - 2
  details.avgLine = label(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", 14, y, DETAILS_W - 28)

  -- gold (/catxp gold): four lines under the level table; the panel grows to make room
  y = y - 20
  details.goldParts = {}
  details.goldRows = {}
  local goldTitle = label(details, "GameFontNormalSmall", "TOPLEFT", details, "TOPLEFT", 10, y)
  goldTitle:SetText("Gold  " .. ns.color(GREY, "looted coin, quest coin, vendor price of pickups"))
  table.insert(details.goldParts, goldTitle)
  y = y - 16
  local function addGoldRow(key, text)
    local l = label(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", 14, y, 108)
    l:SetText(text)
    l:SetTextColor(0.7, 0.7, 0.7)
    local v = label(details, "GameFontHighlightSmall", "TOPLEFT", details, "TOPLEFT", 124, y, DETAILS_W - 134)
    details.goldRows[key] = v
    table.insert(details.goldParts, l)
    table.insert(details.goldParts, v)
    y = y - 14
  end
  addGoldRow("rate", "Gold / hour")
  addGoldRow("sources", "Coin / quests / items")
  addGoldRow("recent", "Last 15 min / hour")
  addGoldRow("spans", "This level / today")

  -- buttons
  local function button(text, x, w, onClick)
    local b = CreateFrame("Button", nil, details, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetPoint("BOTTOMLEFT", details, "BOTTOMLEFT", x, 10)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
  end
  details.btnToggle = button("Start", 10, 62, function() CatXP:Toggle() end)
  details.btnReset  = button("Reset", 76, 58, function() CatXP:Reset() end)
  details.btnGraphs = button("Graphs", 138, 62, function() ns.ToggleGraphs() end)
  details.btnLock   = button("Lock", 204, 56, function() toggleSetting("locked") end)
  details.btnClear  = button("Clear", 264, 66, function() StaticPopup_Show("CATXP_CLEAR_HISTORY") end)
end

-- The details panel is taller while gold is tracked; the buttons hang from its bottom edge.
local function layoutDetails()
  if not details or not details.goldParts then return end
  local gold = CatXP:GoldOn()
  details:SetHeight(DETAILS_H + (gold and DETAILS_GOLD_H or 0))
  for _, part in ipairs(details.goldParts) do
    if gold then part:Show() else part:Hide() end
  end
end

local function goldRateText(w)
  if not w or w.secs < 1 then return ns.color(GREY, "--") end
  if not w.ready then return ns.color(GREY, "warming") end
  return ns.fmtMoney(w.rate) .. "/h"
end

function ns.UpdateChart()
  if not details then return end
  local chart = details.chart
  local s = CatXP.session
  local idx = math.floor(s.secs / 60) + 1
  local vals, maxv = {}, 0
  for b = 1, CHART_BARS do
    local hi = idx - (CHART_BARS - b) * CHART_MINUTES
    local lo = hi - CHART_MINUTES + 1
    if hi >= 1 then
      local sum = 0
      for i = math.max(1, lo), hi do sum = sum + (s.buckets[i] or 0) end
      vals[b] = sum
      if sum > maxv then maxv = sum end
    end
  end
  for b = 1, CHART_BARS do
    local bar = chart.bars[b]
    local v = vals[b]
    if v then
      local h = 1
      if maxv > 0 then h = math.max(1, v / maxv * (CHART_H - 6)) end
      bar:SetHeight(h)
      local tier = CatXP:TierFor(v / (CHART_MINUTES * 60) * 3600)
      local r, g, bl = ns.hexToRGB(tier.color)
      bar:SetColorTexture(r, g, bl, 0.9)
      bar:Show()
    else
      bar:Hide()
    end
  end
  if maxv > 0 then
    details.chartMax:SetText("peak " .. ns.fmtShort(maxv) .. " / 5 min")
  else
    details.chartMax:SetText(ns.color(GREY, "no data yet"))
  end
end

function ns.RefreshDetails(st)
  if not details then return end
  st = st or CatXP:GetStats()
  details.portrait:SetTexture(st.tier.image)
  local R = details.rows
  if st.startedAt and st.startedAt > 0 then
    R.started:SetText(string.format("%s  (level %d)", date("%H:%M", st.startedAt), st.startLevel or 0))
  else
    R.started:SetText("--")
  end
  R.active:SetText(ns.fmtTime(st.secs))
  R.xp:SetText(ns.fmtNum(st.xp))
  if st.warming then
    R.rate:SetText(ns.color(GREY, "warming up"))
  else
    R.rate:SetText(ns.fmtNum(st.rate) .. "  " .. ns.color(st.tier.color, st.tier.name))
  end
  R.recent:SetText(ns.fmtNum(st.recent) .. " / h")
  R.ttl:SetText(st.atMax and "max level" or (st.ttl and ns.fmtTime(st.ttl) or "--"))
  if st.kills > 0 then
    R.kills:SetText(string.format("%d  (avg %s xp%s)", st.kills, ns.fmtNum(st.avgKill or 0),
      st.ktl and (", " .. ns.fmtNum(st.ktl) .. " to level") or ""))
  else
    R.kills:SetText("0")
  end
  R.other:SetText(ns.fmtNum(st.otherXP))

  ns.UpdateChart()

  local levels = CatXP:SortedLevels()
  for r = 1, MAX_LEVEL_ROWS do
    local row = details.levelRows[r]
    local lvl = levels[r]
    local rec = lvl and CatXP.db.levels[lvl]
    if rec then
      local rate = rec.secs > 0 and (rec.xp / rec.secs * 3600) or 0
      local tier = CatXP:TierFor(rate)
      row[1]:SetText(lvl == st.level and ns.color("1eff00", lvl) or tostring(lvl))
      row[2]:SetText(ns.fmtTime(rec.secs))
      row[3]:SetText(ns.fmtShort(rec.xp))
      row[4]:SetText(ns.color(tier.color, ns.fmtShort(rate)))
      row[5]:SetText(tostring(rec.kills or 0))
      for c = 1, 5 do row[c]:Show() end
    else
      for c = 1, 5 do row[c]:Hide() end
    end
  end

  local avg = CatXP:LevelAverages()
  if avg then
    local tier = CatXP:TierFor(avg.rate)
    details.avgLine:SetText(string.format("Average of %d finished level%s: %s, %s xp/h (%s), %d kills",
      avg.count, avg.count == 1 and "" or "s", ns.fmtTime(avg.avgSecs), ns.fmtShort(avg.rate),
      ns.color(tier.color, tier.name), math.floor(avg.avgKills + 0.5)))
  else
    details.avgLine:SetText(ns.color(GREY, "No finished levels tracked yet. Averages appear after a level-up."))
  end

  local g = st.gold
  if g and details.goldRows then
    local G = details.goldRows
    if g.secs < 1 then
      G.rate:SetText(ns.color(GREY, "nothing counted yet"))
    else
      G.rate:SetText(string.format("%s  (%s in %s)", g.ready and (ns.fmtMoney(g.rate) .. "/h") or ns.color(GREY, "warming up"),
        ns.fmtMoney(g.total), ns.fmtTime(g.secs)))
    end
    G.sources:SetText(string.format("%s  /  %s  /  %s", ns.fmtMoney(g.loot), ns.fmtMoney(g.quest), ns.fmtMoney(g.items)))
    G.recent:SetText(goldRateText(g.windows[1]) .. "  /  " .. goldRateText(g.windows[2]))
    G.spans:SetText(goldRateText(g.windows[4]) .. "  /  " .. goldRateText(g.windows[5]))
  end

  details.btnToggle:SetText(st.running and "Pause" or "Start")
  details.btnLock:SetText(CatXP.settings.locked and "Unlock" or "Lock")
end

function ns.ToggleDetails()
  if not details then return end
  if details:IsShown() then
    details:Hide()
  else
    if not CatXP.settings.shown then ns.SetShown(true) end
    placeDetails()
    details:Show()
    ns.RefreshDetails()
  end
end

---------------------------------------------------------------------------
-- settings application, visibility, build
---------------------------------------------------------------------------
function ns.ApplySettings()
  if not main then return end
  local S = CatXP.settings
  main:SetScale(S.scale or 1)
  main:SetAlpha(S.alpha or 1)
  details:SetScale(S.scale or 1)
  applyPosition()
  layoutMain()
  layoutDetails()
  if S.shown then
    main:Show()
  else
    main:Hide()
    details:Hide()
  end
  if details.btnLock then details.btnLock:SetText(S.locked and "Unlock" or "Lock") end
  if ns.ApplyGraphSettings then ns.ApplyGraphSettings() end
  if ns.ApplyBoardSettings then ns.ApplyBoardSettings() end
end

function ns.SetShown(flag)
  CatXP.settings.shown = flag and true or false
  ns.ApplySettings()
  if not flag then CatXP:Print("Window hidden. /catxp show brings it back.") end
end

function ns.BuildUI()
  if main then return end
  buildMain()
  buildDetails()
  if ns.BuildGraphs then ns.BuildGraphs() end
  if ns.BuildBoard then ns.BuildBoard() end
  ns.ApplySettings()
  if CatXP.settings.detailsShown and CatXP.settings.shown then
    placeDetails()
    details:Show()
  end
  ns.Refresh()
end
