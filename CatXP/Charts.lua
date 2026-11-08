--[[-------------------------------------------------------------------------
  CatXP charts: a small drawing helper built from frames, textures and lines.
  ns.Chart.New(parent, w, h) returns a chart; call chart:DrawBars(items, opts)
  or chart:DrawSeries(points, opts). Everything is pooled and reused.
---------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local Chart = {}
Chart.__index = Chart
ns.Chart = Chart

local PAD_L, PAD_R, PAD_T, PAD_B = 44, 12, 14, 18
local GRID = { 0.28, 0.28, 0.28 }

local BACKDROP = {
  bgFile = "Interface\\Buttons\\WHITE8x8",
  edgeFile = "Interface\\Buttons\\WHITE8x8",
  edgeSize = 1,
  insets = { left = 1, right = 1, top = 1, bottom = 1 },
}

function Chart.New(parent, width, height)
  local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  frame:SetSize(width, height)
  frame:SetBackdrop(BACKDROP)
  frame:SetBackdropColor(0.07, 0.07, 0.07, 0.9)
  frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
  local self = setmetatable({
    frame = frame, w = width, h = height,
    pools = { bars = {}, lines = {}, labels = {}, grid = {} },
    used = { bars = 0, lines = 0, labels = 0, grid = 0 },
    hasLines = frame.CreateLine ~= nil,
  }, Chart)
  self.message = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  self.message:SetPoint("CENTER", frame, "CENTER", 0, 0)
  self.message:Hide()
  return self
end

---------------------------------------------------------------------------
-- pools
---------------------------------------------------------------------------
local function take(self, key, create)
  local list = self.pools[key]
  local idx = self.used[key] + 1
  self.used[key] = idx
  local obj = list[idx]
  if not obj then
    obj = create(self)
    list[idx] = obj
  end
  obj:Show()
  return obj
end

local function newBar(self)
  local bar = CreateFrame("Frame", nil, self.frame)
  bar:EnableMouse(true)
  bar.tex = bar:CreateTexture(nil, "ARTWORK")
  bar.tex:SetAllPoints(bar)
  bar:SetScript("OnEnter", function(b)
    if not b.tipTitle then return end
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    GameTooltip:SetText(b.tipTitle)
    if b.tipText then GameTooltip:AddLine(b.tipText, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  bar:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return bar
end

local function newLine(self)
  local line = self.frame:CreateLine(nil, "ARTWORK")
  line:SetThickness(2)
  return line
end

local function newLabel(self)
  return self.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
end

local function newGrid(self)
  return self.frame:CreateTexture(nil, "BACKGROUND")
end

function Chart:Clear()
  for key, list in pairs(self.pools) do
    for _, obj in ipairs(list) do obj:Hide() end
    self.used[key] = 0
  end
  self.message:Hide()
end

function Chart:Message(text)
  self:Clear()
  self.message:SetText(text)
  self.message:Show()
end

function Chart:PlotArea()
  return PAD_L, PAD_B, self.w - PAD_L - PAD_R, self.h - PAD_T - PAD_B
end

---------------------------------------------------------------------------
-- primitives
---------------------------------------------------------------------------
local function hline(self, y, color, alpha)
  local t = take(self, "grid", newGrid)
  t:ClearAllPoints()
  t:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", PAD_L, y)
  t:SetSize(self.w - PAD_L - PAD_R, 1)
  t:SetColorTexture(color[1], color[2], color[3], alpha or 1)
  return t
end

local function vline(self, x, y, height, color, alpha)
  local t = take(self, "grid", newGrid)
  t:ClearAllPoints()
  t:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", x, y)
  t:SetSize(1, height)
  t:SetColorTexture(color[1], color[2], color[3], alpha or 1)
  return t
end

local function text(self, str, point, x, y, justify, width)
  local fs = take(self, "labels", newLabel)
  fs:ClearAllPoints()
  fs:SetPoint(point, self.frame, "BOTTOMLEFT", x, y)
  fs:SetWidth(width or 0)
  fs:SetJustifyH(justify or "LEFT")
  fs:SetText(str)
  return fs
end

function Chart:YAxis(maxv, fmt)
  fmt = fmt or ns.fmtShort
  local x0, y0, pw, ph = self:PlotArea()
  for _, frac in ipairs({ 0, 0.5, 1 }) do
    local y = y0 + ph * frac
    if frac > 0 then hline(self, y, GRID, 1) end
    text(self, fmt(maxv * frac), "RIGHT", x0 - 4, y, "RIGHT")
  end
end

---------------------------------------------------------------------------
-- bars: items = { { value=, label=, color={r,g,b}, highlight=, tipTitle=, tipText= }, ... }
-- opts: refLine, refText, maxBarWidth, labelWidth, empty, fmt
---------------------------------------------------------------------------
function Chart:DrawBars(items, opts)
  opts = opts or {}
  self:Clear()
  local n = #items
  if n == 0 then
    self:Message(opts.empty or "No data yet.")
    return
  end
  local x0, y0, pw, ph = self:PlotArea()
  local maxv = opts.refLine or 0
  for _, it in ipairs(items) do if it.value > maxv then maxv = it.value end end
  if maxv <= 0 then maxv = 1 end
  maxv = maxv * 1.05
  self:YAxis(maxv, opts.fmt)

  local slot = pw / n
  local bw = math.max(2, math.min(opts.maxBarWidth or 36, slot * 0.72))
  local labelEvery = math.max(1, math.ceil((opts.labelWidth or 18) / slot))
  for i, it in ipairs(items) do
    local h = math.max(1, it.value / maxv * ph)
    local bar = take(self, "bars", newBar)
    bar:ClearAllPoints()
    bar:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", x0 + (i - 1) * slot + (slot - bw) / 2, y0)
    bar:SetSize(bw, h)
    local c = it.color or { 0.6, 0.6, 0.6 }
    bar.tex:SetColorTexture(c[1], c[2], c[3], it.highlight and 1 or 0.8)
    bar.tipTitle, bar.tipText = it.tipTitle, it.tipText
    if it.label and ((i - 1) % labelEvery == 0) then
      text(self, it.label, "TOP", x0 + (i - 1) * slot + slot / 2, y0 - 2, "CENTER")
    end
  end

  if opts.refLine and opts.refLine > 0 then
    local y = y0 + opts.refLine / maxv * ph
    hline(self, y, { 1, 0.85, 0.4 }, 0.9)
    if opts.refText then text(self, opts.refText, "BOTTOMRIGHT", x0 + pw - 2, y + 1, "RIGHT") end
  end
end

---------------------------------------------------------------------------
-- series: points = { y1, y2, ... } evenly spaced
-- opts: color={r,g,b}, refLine, refText, xLabels={first, mid, last}, marks={ {index=, text=} }, empty, fmt
---------------------------------------------------------------------------
function Chart:DrawSeries(points, opts)
  opts = opts or {}
  self:Clear()
  local n = #points
  if n < 2 then
    self:Message(opts.empty or "Not enough data yet.")
    return
  end
  local x0, y0, pw, ph = self:PlotArea()
  local maxv = opts.refLine or 0
  for i = 1, n do if points[i] > maxv then maxv = points[i] end end
  if maxv <= 0 then maxv = 1 end
  maxv = maxv * 1.05
  self:YAxis(maxv, opts.fmt)

  local stepX = pw / (n - 1)
  local c = opts.color or { 1, 0.8, 0.3 }
  for i = 1, n - 1 do
    local x1, y1 = x0 + (i - 1) * stepX, y0 + points[i] / maxv * ph
    local x2, y2 = x0 + i * stepX, y0 + points[i + 1] / maxv * ph
    if self.hasLines then
      local line = take(self, "lines", newLine)
      line:SetColorTexture(c[1], c[2], c[3], 1)
      line:SetStartPoint("BOTTOMLEFT", self.frame, x1, y1)
      line:SetEndPoint("BOTTOMLEFT", self.frame, x2, y2)
    else
      local dot = take(self, "grid", newGrid)
      dot:ClearAllPoints()
      dot:SetPoint("CENTER", self.frame, "BOTTOMLEFT", x2, y2)
      dot:SetSize(3, 3)
      dot:SetColorTexture(c[1], c[2], c[3], 1)
    end
  end

  if opts.xLabels then
    text(self, opts.xLabels[1] or "", "TOPLEFT", x0, y0 - 2, "LEFT")
    if opts.xLabels[2] then text(self, opts.xLabels[2], "TOP", x0 + pw / 2, y0 - 2, "CENTER") end
    text(self, opts.xLabels[3] or "", "TOPRIGHT", x0 + pw, y0 - 2, "RIGHT")
  end

  if opts.refLine and opts.refLine > 0 then
    local y = y0 + opts.refLine / maxv * ph
    hline(self, y, { 1, 1, 1 }, 0.35)
    if opts.refText then text(self, opts.refText, "BOTTOMRIGHT", x0 + pw - 2, y + 1, "RIGHT") end
  end

  for _, mk in ipairs(opts.marks or {}) do
    if mk.index >= 1 and mk.index <= n then
      local x = x0 + (mk.index - 1) * stepX
      vline(self, x, y0, ph, { 0.3, 1, 0.3 }, 0.6)
      if mk.text then text(self, mk.text, "BOTTOM", x, y0 + ph + 1, "CENTER") end
    end
  end
end
