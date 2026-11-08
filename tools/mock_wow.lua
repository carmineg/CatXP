-- Minimal headless mock of the World of Warcraft UI API, enough to load and drive CatXP.
local M = {
  now = 1000, wall = 1700000000,
  level = 10, xp = 500, xpMax = 10000, rested = 250, afk = false, maxLevel = 60,
  zone = "Elwynn Forest", shift = false, ctrl = false, inGroup = false, inRaid = false, inGuild = false,
  sent = {}, addonSent = {}, prefixes = {},
  prints = {}, tickers = {}, frames = {}, popups = {}, secretTest = nil, acceptPopups = false,
}
_G.MOCK = M

GetTime = function() return M.now end
time = function() return M.wall end
date = function(fmt, t) return os.date(fmt, t or M.wall) end
UnitLevel = function() return M.level end
UnitXP = function() return M.xp end
UnitXPMax = function() return M.xpMax end
GetXPExhaustion = function() return M.rested end
UnitIsAFK = function() return M.afk end
GetMaxPlayerLevel = function() return M.maxLevel end
GetRealZoneText = function() return M.zone end
GetZoneText = function() return M.zone end
IsShiftKeyDown = function() return M.shift end
IsInGroup = function(category) if category then return false end return M.inGroup end
IsInRaid = function() return M.inRaid end
LE_PARTY_CATEGORY_INSTANCE = 2
UnitName = function() return "Tester" end
UnitClass = function() return "Warrior", "WARRIOR" end
GetNormalizedRealmName = function() return "Realm" end
GetRealmName = function() return "Realm" end
IsInGuild = function() return M.inGuild end
IsControlKeyDown = function() return M.ctrl end
GetServerTime = function() return M.wall end
SendChatMessage = function(msg, chan) M.sent[#M.sent + 1] = { msg = msg, chan = chan } end
RAID_CLASS_COLORS = {
  WARRIOR = { r = 0.78, g = 0.61, b = 0.43, colorStr = "ffc79c6e" },
  MAGE    = { r = 0.41, g = 0.80, b = 0.94, colorStr = "ff69ccf0" },
  HUNTER  = { r = 0.67, g = 0.83, b = 0.45, colorStr = "ffabd473" },
  ROGUE   = { r = 1.00, g = 0.96, b = 0.41, colorStr = "fffff569" },
  PRIEST  = { r = 1.00, g = 1.00, b = 1.00, colorStr = "ffffffff" },
  DRUID   = { r = 1.00, g = 0.49, b = 0.04, colorStr = "ffff7d0a" },
  PALADIN = { r = 0.96, g = 0.55, b = 0.73, colorStr = "fff58cba" },
  WARLOCK = { r = 0.53, g = 0.53, b = 0.93, colorStr = "ff8787ed" },
  SHAMAN  = { r = 0.00, g = 0.44, b = 0.87, colorStr = "ff0070de" },
}
C_ChatInfo = {
  RegisterAddonMessagePrefix = function(prefix) M.prefixes[prefix] = true; return true end,
  SendAddonMessage = function(prefix, msg, chan, target)
    M.addonSent[#M.addonSent + 1] = { prefix = prefix, msg = msg, chan = chan, target = target }
    return 0
  end,
}
-- deliver an addon message from another player
function M.receiveAddon(text, chan, sender)
  M.fire("CHAT_MSG_ADDON", "CatXP", text, chan, sender)
end
issecretvalue = function(v) if M.secretTest then return M.secretTest(v) end return false end
print = function(...)
  local t = {}
  for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
  M.prints[#M.prints + 1] = table.concat(t, " ")
end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) M.prints[#M.prints + 1] = msg end }
YES, NO = "Yes", "No"
COMBATLOG_XPGAIN_FIRSTPERSON = "%s dies, you gain %d experience."
StaticPopupDialogs = {}
StaticPopup_Show = function(which)
  M.popups[#M.popups + 1] = which
  local d = StaticPopupDialogs[which]
  if M.acceptPopups and d and d.OnAccept then d.OnAccept() end
  return {}
end
UISpecialFrames = {}
SlashCmdList = {}
C_AddOns = { GetAddOnMetadata = function(_, field) if field == "Version" then return "2.0.0-test" end end }
C_Timer = {
  NewTicker = function(interval, fn)
    local t = { interval = interval, fn = fn, cancelled = false, acc = 0 }
    function t:Cancel() self.cancelled = true end
    M.tickers[#M.tickers + 1] = t
    return t
  end,
}

-- Regions / frames -----------------------------------------------------------
local Region = {}
Region.__index = Region
local function noop() end
for _, m in ipairs({
  "ClearAllPoints", "SetFrameStrata", "SetClampedToScreen", "SetMovable", "EnableMouse",
  "RegisterForDrag", "RegisterForClicks", "SetBackdrop", "SetBackdropColor", "SetUserPlaced",
  "StartMoving", "StopMovingOrSizing", "SetTexCoord", "SetVertexColor", "SetJustifyH",
  "SetJustifyV", "SetTextColor", "SetWordWrap", "SetMaxLines", "SetFont", "SetShadowOffset",
  "SetDrawLayer", "SetBlendMode", "SetFontObject", "Raise", "SetToplevel", "SetHitRectInsets",
  "SetAllPoints", "Disable", "Enable", "SetHighlightTexture", "SetThickness",
}) do Region[m] = noop end

function Region:SetSize(w, h) self.w, self.h = w, h end
function Region:SetWidth(w) self.w = w end
function Region:SetHeight(h) self.h = h end
function Region:GetWidth() return self.w or 0 end
function Region:GetHeight() return self.h or 0 end
function Region:GetFont() return "Fonts\\FRIZQT__.TTF", 10, "" end
function Region:SetFrameLevel(l) self.flevel = l end
function Region:GetFrameLevel() return self.flevel or 1 end
function Region:SetScale(s) self.scale = s end
function Region:GetScale() return self.scale or 1 end
function Region:GetEffectiveScale() return self.scale or 1 end
function Region:SetAlpha(a) self.alpha = a end
function Region:GetAlpha() return self.alpha or 1 end
function Region:Show()
  local was = self.shown
  self.shown = true
  if not was and self.scripts and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function Region:Hide()
  local was = self.shown
  self.shown = false
  if was and self.scripts and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function Region:SetShown(b) if b then self:Show() else self:Hide() end end
function Region:IsShown() return self.shown == true end
function Region:IsVisible() return self.shown == true end
function Region:GetName() return self.name end
function Region:GetParent() return self.parent end
function Region:SetText(t) self.text = t end
function Region:GetText() return self.text end
function Region:SetTexture(t) self.texture = t end
function Region:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function Region:SetBackdropBorderColor(r, g, b, a) self.borderColor = { r, g, b, a } end
function Region:SetPoint(point, relTo, relPoint, x, y)
  if type(relTo) == "number" then x, y, relTo, relPoint = relTo, relPoint, nil, nil end
  self.point, self.relTo, self.relPoint, self.x, self.y = point, relTo, relPoint, x or 0, y or 0
end
function Region:GetPoint() return self.point or "CENTER", self.relTo, self.relPoint or "CENTER", self.x or 0, self.y or 0 end
function Region:GetBottom() return self.bottom or 500 end
function Region:SetStartPoint(_, _, x, y) self.x1, self.y1 = x, y end
function Region:SetEndPoint(_, _, x, y) self.x2, self.y2 = x, y end
function Region:SetScript(name, fn) self.scripts = self.scripts or {}; self.scripts[name] = fn end
function Region:GetScript(name) return self.scripts and self.scripts[name] end
function Region:RegisterEvent(e) self.events = self.events or {}; self.events[e] = true end
function Region:UnregisterEvent(e) if self.events then self.events[e] = nil end end
function Region:RegisterUnitEvent(e) self:RegisterEvent(e) end
function Region:CreateTexture() return setmetatable({ parent = self, shown = true, kind = "Texture" }, Region) end
function Region:CreateLine() return setmetatable({ parent = self, shown = true, kind = "Line" }, Region) end
function Region:CreateFontString(_, _, font) return setmetatable({ parent = self, shown = true, kind = "FontString", font = font }, Region) end
function Region:Click(button)
  if self.scripts and self.scripts.OnClick then self.scripts.OnClick(self, button or "LeftButton") end
end
function Region:Enter() if self.scripts and self.scripts.OnEnter then self.scripts.OnEnter(self) end end
function Region:Leave() if self.scripts and self.scripts.OnLeave then self.scripts.OnLeave(self) end end

function CreateFrame(ftype, name, parent, template)
  local f = setmetatable({ kind = ftype, name = name, parent = parent, template = template, shown = true, scripts = {}, events = {} }, Region)
  M.frames[#M.frames + 1] = f
  if name then _G[name] = f end
  return f
end

local function makeGlobals()
  UIParent = CreateFrame("Frame", "UIParent")
  UIParent.w, UIParent.h = 1024, 768
  GameTooltip = CreateFrame("GameTooltip", "GameTooltip")
  GameTooltip.lines = {}
  function GameTooltip:SetOwner() self.lines = {} end
  function GameTooltip:ClearLines() self.lines = {} end
  function GameTooltip:SetText(text) self.lines = { tostring(text) } end
  function GameTooltip:AddLine(text) self.lines[#self.lines + 1] = tostring(text) end
  function GameTooltip:AddDoubleLine(l, r) self.lines[#self.lines + 1] = tostring(l) .. " | " .. tostring(r) end
end
makeGlobals()

-- Menu API -------------------------------------------------------------------
MenuUtil = {}
local function newDescription()
  local d = { elements = {} }
  local function add(kind, text, a, b, data)
    local e = { kind = kind, text = text, a = a, b = b, data = data }
    function e:SetTooltip() end
    function e:SetResponder() end
    d.elements[#d.elements + 1] = e
    return e
  end
  function d:CreateTitle(text) return add("title", text) end
  function d:CreateButton(text, cb, data) return add("button", text, cb, nil, data) end
  function d:CreateCheckbox(text, isSel, setSel, data) return add("checkbox", text, isSel, setSel, data) end
  function d:CreateRadio(text, isSel, setSel, data) return add("radio", text, isSel, setSel, data) end
  function d:CreateDivider() return add("divider") end
  return d
end
function MenuUtil.CreateContextMenu(owner, generator)
  local root = newDescription()
  generator(owner, root)
  M.lastMenu = root
  return root
end
function M.menuClick(text)
  for _, e in ipairs(M.lastMenu.elements) do
    if e.text == text then
      if e.kind == "button" then return e.a(e.data) end
      if e.kind == "checkbox" or e.kind == "radio" then return e.b(e.data) end
    end
  end
  error("menu element not found: " .. tostring(text))
end
function M.menuChecked(text)
  for _, e in ipairs(M.lastMenu.elements) do
    if e.text == text and e.kind == "checkbox" then return e.a(e.data) end
  end
  error("checkbox not found: " .. tostring(text))
end
function M.menuHas(text)
  for _, e in ipairs(M.lastMenu.elements) do if e.text == text then return true end end
  return false
end

-- Driving --------------------------------------------------------------------
function M.fire(event, ...)
  for _, f in ipairs(M.frames) do
    if f.events and f.events[event] and f.scripts and f.scripts.OnEvent then
      f.scripts.OnEvent(f, event, ...)
    end
  end
end

-- advance the clock one second at a time, firing tickers
function M.advance(secs)
  for _ = 1, secs do
    M.now = M.now + 1
    M.wall = M.wall + 1
    for _, t in ipairs(M.tickers) do
      if not t.cancelled then
        t.acc = t.acc + 1
        if t.acc >= t.interval then t.acc = 0; t.fn() end
      end
    end
  end
end

function M.activeTickers()
  local n = 0
  for _, t in ipairs(M.tickers) do if not t.cancelled then n = n + 1 end end
  return n
end

-- forget all frames and tickers (simulates /reload); saved variables are untouched
function M.resetUI()
  M.frames, M.tickers, M.prints, M.popups = {}, {}, {}, {}
  SlashCmdList = {}
  UISpecialFrames = {}
  StaticPopupDialogs = {}
  makeGlobals()
end

function M.deepcopy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[M.deepcopy(k)] = M.deepcopy(v) end
  return o
end
