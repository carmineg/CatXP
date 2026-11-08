--[[-------------------------------------------------------------------------
  Cat facts: which one gets said. Every announcement CatXP makes (promotions,
  demotions, levels cleared, lead changes, races) ends with one, and
  /catxp fact gives one on demand. The facts themselves are in FactBank.lua.

  Two pools. Each cat on the ladder has its own facts about that species,
  said on its promotions and demotions until every one of them has been
  heard once. After that, and for anything without a cat, the bank takes
  over: thousands of facts in a shuffled order, each said once before the
  deck is shuffled again. The place in the deck is saved account-wide
  (CatXPDB.facts), so logging out or switching characters never starts the
  same facts over.
---------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...
local CatXP = ns.CatXP

local FACTS = ns.CAT_FACTS or {}
local BANK = ns.GENERAL_FACTS or {}

for _, tier in ipairs(CatXP.TIERS) do tier.facts = FACTS[tier.name] end

-- A deterministic shuffle: the same seed always gives the same order, so a deck can be rebuilt
-- after a reload from the two numbers saved for it (Park-Miller sequence, exact in doubles).
local MODULUS = 2147483647
local function nextSeed(s) return (s * 48271) % MODULUS end

local function shuffle(n, seed)
  local p = {}
  for i = 1, n do p[i] = i end
  local s = seed
  for i = n, 2, -1 do
    s = nextSeed(s)
    local j = (s % i) + 1
    p[i], p[j] = p[j], p[i]
  end
  return p
end

local function randomSeed() return math.random(1, MODULUS - 1) end

-- A seed of its own for each cat, derived from the saved one and the cat's name.
local function seedFor(base, name)
  local s = base
  for i = 1, #name do s = (s * 31 + name:byte(i)) % MODULUS end
  if s == 0 then s = 1 end
  return s
end

local deck          -- the current shuffle of the bank, rebuilt from the saved seed
local catDecks = {} -- one shuffle per cat
local lastSaid

local function state()
  CatXPDB = CatXPDB or {}
  local f = CatXPDB.facts
  if type(f) ~= "table" then f = {}; CatXPDB.facts = f end
  if type(f.heard) ~= "table" then f.heard = {} end        -- [cat name] = how many of its own facts said
  if type(f.catSeed) ~= "number" then f.catSeed = randomSeed() end
  return f
end

local function newDeck(f)
  f.seed = randomSeed()
  f.pos = 1
  f.size = #BANK
  deck = shuffle(#BANK, f.seed)
end

-- The next fact from the bank. Every fact once per pass, then a new shuffle. A version with a
-- different number of facts starts a new pass.
local function nextBankFact()
  if #BANK == 0 then return nil end
  local f = state()
  if not deck or f.size ~= #BANK or type(f.seed) ~= "number" or type(f.pos) ~= "number" then
    if f.size == #BANK and type(f.seed) == "number" and type(f.pos) == "number" then
      deck = shuffle(#BANK, f.seed)
    else
      newDeck(f)
    end
  end
  if f.pos > #BANK then newDeck(f) end
  if #BANK > 1 and BANK[deck[f.pos]] == lastSaid then   -- a new pass that opens with the fact that closed the last
    f.pos = f.pos + 1
    if f.pos > #BANK then newDeck(f) end
  end
  local fact = BANK[deck[f.pos]]
  f.pos = f.pos + 1
  lastSaid = fact
  return fact
end

-- A fact about this cat while it still has ones nobody has heard, then one from the bank.
function ns.CatFact(tier)
  local list = tier and tier.facts
  if list and #list > 0 then
    local f = state()
    local name = tier.name
    local heard = f.heard[name] or 0
    if heard < #list then
      local d = catDecks[name]
      if not d or #d ~= #list then
        d = shuffle(#list, seedFor(f.catSeed, name))
        catDecks[name] = d
      end
      f.heard[name] = heard + 1
      lastSaid = list[d[heard + 1]]
      return lastSaid
    end
  end
  local fact = nextBankFact()
  if not fact and list then fact = list[math.random(#list)] end
  return fact
end

-- " Cat fact: ..." ready to append to a line; "" if there is somehow nothing to say
function ns.FactLine(tier)
  local fact = ns.CatFact(tier)
  return fact and (" Cat fact: " .. fact) or "", fact
end

-- Bank size, how many of it this pass has said, and how many facts the cats have of their own.
function ns.FactCounts()
  local f = state()
  local cats = 0
  for _, list in pairs(FACTS) do cats = cats + #list end
  local said = (f.size == #BANK and type(f.pos) == "number") and (f.pos - 1) or 0
  return #BANK, said, cats
end
