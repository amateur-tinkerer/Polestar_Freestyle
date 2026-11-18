-- Polestar Freestyle: the quest browser's index.
--
-- Every quest this character can ever take (faction, race and class allow
-- it), read from Polestar's Codex (Polestar_Codex: levels, zone, the
-- prerequisites, rewards, reward choices and XP), grouped by zone and linked
-- into chains through the prerequisites. Built once, a slice per frame, the
-- first time the browser opens. Nothing here is typed in by hand: every quest
-- and item id comes from the Codex.
--
-- Per-character state (done, in the log, open, locked) is read live from the
-- client through Polestar.Compat and cached until the quest log changes.
--
--   FQB.Build(onDone)          load the Codex and index it; onDone(ok, reason)
--   FQB.State()                "idle" | "waiting" (combat) | "loading" | "ready" | "failed", reason
--   FQB.Quest(id)              { id, title, level, minLevel, zone, xp, rewards, choices, pre, preAny }
--   FQB.Zones()                { { id, name, min, max, nodes = { chain | quest id } }, ... }
--   FQB.ChainOf(id)            the chain a quest is in, or nil
--   FQB.Status(id)             "done" | "log" | "available" | "level" | "pre"
--   FQB.XP(id)                 the XP this character would get now (Polestar.Levels.Share)
--   FQB.QuestsForItem(itemID)  { { quest = id, choice = bool }, ... }
--   FQB.Matches(id, text)      the quest's title or a reward's name holds text (lower case)
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
if not FQ then return end

local C = P.Compat
local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local floor, min, max = math.floor, math.min, math.max
local lower, find, concat = string.lower, string.find, table.concat

local FQB = FQ.Browser or {}
FQ.Browser = FQB

local SLICE = 250 -- quests indexed per frame

local state, failReason = "idle", nil
local waiters = {}
local quests = {}     -- id -> slim record
local followUps = {}  -- id -> { ids }
local chainOf = {}    -- id -> chain
local chains = {}     -- { chain, ... }
local zones = {}      -- { zone, ... }
local statusCache = {}
local searchText = {} -- id -> lower-case title and reward names

local function Codex() return P.Codex end
local function Lookup() return P.Lookup end

function FQB.State() return state, failReason end
function FQB.Quest(id) return quests[id] end
function FQB.Zones() return zones end
function FQB.ChainOf(id) return chainOf[id] end
function FQB.FollowUps(id) return followUps[id] end

-- Who repaints when the index or the character's quests change.
local listeners = {}
function FQB.Listen(fn) listeners[#listeners + 1] = fn end
function FQB.Changed()
	for _, fn in ipairs(listeners) do pcall(fn) end
end

local function finish(ok, reason)
	state = ok and "ready" or "failed"
	failReason = reason
	local list = waiters
	waiters = {}
	for _, fn in ipairs(list) do pcall(fn, ok, reason) end
	FQB.Changed()
end

---------------------------------------------------------------------------
-- Indexing
---------------------------------------------------------------------------

local function count(list) return type(list) == "table" and #list or 0 end

local function hasStart(q)
	local s = q.start
	if type(s) ~= "table" then return false end
	return count(s.npc) > 0 or count(s.object) > 0 or count(s.item) > 0
end

local function index(id, player)
	local Cx, Lk = Codex(), Lookup()
	local q = Cx.Quest(id)
	if not q or not hasStart(q) then return end
	local why = Lk.QuestBlock(q, player)
	if why == "faction" or why == "race" or why == "class" then return end
	quests[id] = {
		id = id, title = q.title or ("Quest " .. id),
		level = q.level or q.minLevel or 0, minLevel = q.minLevel,
		zone = q.zone, xp = q.xp,
		rewards = q.rewards, choices = q.choices,
		pre = q.pre, preAny = q.preAny,
	}
end

-- Union-find over the prerequisite links.
local function root(parent, id)
	while parent[id] ~= id do
		parent[id] = parent[parent[id]]
		id = parent[id]
	end
	return id
end

local function zoneName(id)
	if not id or id == 0 then return "Other" end
	return (C.MapName and C.MapName(id)) or ("Zone " .. id)
end

-- The zone's level range: Polestar's own (Maps/ZoneLevels.lua, by uiMapID),
-- else the 10th to 90th percentile of its quests' levels.
local function zoneLevels(id, levels)
	local M = P.Maps
	local lo, hi
	if M and M.GetZoneLevels and id then lo, hi = M.GetZoneLevels(id) end
	if lo and hi then return lo, hi end
	if #levels == 0 then return nil, nil end
	table.sort(levels)
	local function pct(p) return levels[max(1, min(#levels, floor(#levels * p + 0.5)))] end
	return pct(0.1), pct(0.9)
end

local function link()
	-- Follow-ups: the quests whose pre or preAny names a quest.
	local parent = {}
	for id in pairs(quests) do parent[id] = id end
	local function join(a, b)
		local ra, rb = root(parent, a), root(parent, b)
		if ra ~= rb then parent[ra] = rb end
	end
	for id, r in pairs(quests) do
		for _, list in ipairs({ r.pre or {}, r.preAny or {} }) do
			for _, p in ipairs(list) do
				if quests[p] then
					local f = followUps[p]
					if not f then
						f = {}
						followUps[p] = f
					end
					f[#f + 1] = id
					join(p, id)
				end
			end
		end
	end

	-- Depth: how many prerequisites deep a quest sits in its chain.
	local depth, visiting = {}, {}
	local function depthOf(id)
		if depth[id] then return depth[id] end
		if visiting[id] then return 0 end
		visiting[id] = true
		local d = 0
		local r = quests[id]
		for _, list in ipairs({ r.pre or {}, r.preAny or {} }) do
			for _, p in ipairs(list) do
				if quests[p] then d = max(d, depthOf(p) + 1) end
			end
		end
		visiting[id] = nil
		depth[id] = d
		return d
	end

	local groups = {}
	for id in pairs(quests) do
		local g = root(parent, id)
		local list = groups[g]
		if not list then
			list = {}
			groups[g] = list
		end
		list[#list + 1] = id
	end

	local singles = {}
	for _, list in pairs(groups) do
		if #list == 1 then
			singles[#singles + 1] = list[1]
		else
			for _, id in ipairs(list) do depthOf(id) end
			table.sort(list, function(a, b)
				if depth[a] ~= depth[b] then return depth[a] < depth[b] end
				local la, lb = quests[a].level or 0, quests[b].level or 0
				if la ~= lb then return la < lb end
				return a < b
			end)
			-- Its end: the deepest quest nothing follows.
			local last
			for _, id in ipairs(list) do
				if not followUps[id] then
					if not last or depth[id] > depth[last] or (depth[id] == depth[last] and (quests[id].level or 0) > (quests[last].level or 0)) then
						last = id
					end
				end
			end
			last = last or list[#list]
			local zone
			for _, id in ipairs(list) do
				if quests[id].zone then zone = quests[id].zone break end
			end
			local zset, others = {}, {}
			for _, id in ipairs(list) do
				local z = quests[id].zone
				if z and z ~= zone and not zset[z] then
					zset[z] = true
					others[#others + 1] = zoneName(z)
				end
			end
			local chain = {
				kind = "chain", id = list[1], quests = list, last = last,
				title = quests[last].title, zone = zone or 0,
				minLevel = quests[list[1]].level, maxLevel = quests[last].level,
				otherZones = #others > 0 and concat(others, ", ") or nil,
			}
			chains[#chains + 1] = chain
			for _, id in ipairs(list) do chainOf[id] = chain end
		end
	end

	-- Zones: their chains (by the chain's first zone) and single quests.
	local byZone = {}
	local function zoneEntry(z)
		z = z or 0
		local e = byZone[z]
		if not e then
			e = { kind = "zone", id = z, name = zoneName(z), nodes = {}, levels = {} }
			byZone[z] = e
		end
		return e
	end
	for _, ch in ipairs(chains) do
		local e = zoneEntry(ch.zone)
		e.nodes[#e.nodes + 1] = ch
		for _, id in ipairs(ch.quests) do
			if (quests[id].zone or 0) == ch.zone then e.levels[#e.levels + 1] = quests[id].level end
		end
	end
	for _, id in ipairs(singles) do
		local e = zoneEntry(quests[id].zone)
		e.nodes[#e.nodes + 1] = id
		e.levels[#e.levels + 1] = quests[id].level
	end
	for _, e in pairs(byZone) do
		e.min, e.max = zoneLevels(e.id ~= 0 and e.id or nil, e.levels)
		e.levels = nil
		zones[#zones + 1] = e
	end
	table.sort(zones, function(a, b)
		if (a.id == 0) ~= (b.id == 0) then return b.id == 0 end
		return lower(a.name) < lower(b.name)
	end)
end

local regenFrame
local function afterCombat()
	if regenFrame then return end
	regenFrame = CreateFrame("Frame")
	regenFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	regenFrame:SetScript("OnEvent", function(self)
		self:UnregisterAllEvents()
		regenFrame = nil
		if state == "waiting" then
			state = "idle"
			FQB.Build()
		end
	end)
end

function FQB.Build(onDone)
	if onDone then
		if state == "ready" then
			onDone(true)
			return
		end
		waiters[#waiters + 1] = onDone
	end
	if state == "loading" or state == "ready" or state == "waiting" then return end
	local Cx, Lk = Codex(), Lookup()
	if not (Cx and Cx.Load and Cx.Each and Cx.Quest and Lk and Lk.QuestBlock and Lk.PlayerInfo) then
		finish(false, "missing")
		return
	end
	local ok, reason = Cx.Load()
	if not ok then
		if reason == "combat" then
			state, failReason = "waiting", "combat"
			afterCombat()
			FQB.Changed()
			return
		end
		finish(false, reason or "unavailable")
		return
	end
	state, failReason = "loading", nil
	local ids = {}
	Cx.Each("quest", function(id)
		id = tonumber(id)
		if id then ids[#ids + 1] = id end
	end)
	table.sort(ids)
	local player = Lk.PlayerInfo()
	local i = 0
	local function slice()
		local ok2, err = pcall(function()
			local stop = min(#ids, i + SLICE)
			for k = i + 1, stop do index(ids[k], player) end
			i = stop
		end)
		if not ok2 then
			finish(false, tostring(err))
			return
		end
		if i < #ids then
			C_Timer.After(0, slice)
		else
			local ok3, err3 = pcall(link)
			finish(ok3, not ok3 and tostring(err3) or nil)
		end
	end
	slice()
end

---------------------------------------------------------------------------
-- The character's state
---------------------------------------------------------------------------

function FQB.PlayerLevel()
	local info = C.GetPlayerInfo and C.GetPlayerInfo()
	return (info and info.level) or (UnitLevel and UnitLevel("player")) or 1
end

local function done(id)
	local s = statusCache[id]
	if s then return s == "done" end
	return C.IsQuestCompleted(id) and true or false
end

local function preDone(r)
	for _, p in ipairs(r.pre or {}) do
		if quests[p] and not done(p) then return false end
	end
	local any = r.preAny
	if type(any) == "table" and #any > 0 then
		local known = false
		for _, p in ipairs(any) do
			if quests[p] then
				known = true
				if done(p) then return true end
			end
		end
		if known then return false end
	end
	return true
end

function FQB.Status(id)
	local s = statusCache[id]
	if s then return s end
	local r = quests[id]
	if C.IsQuestCompleted(id) then
		s = "done"
	elseif C.IsOnQuest(id) then
		s = "log"
	elseif r and r.minLevel and r.minLevel > FQB.PlayerLevel() then
		s = "level"
	elseif r and not preDone(r) then
		s = "pre"
	else
		s = "available"
	end
	statusCache[id] = s
	return s
end

function FQB.Invalidate()
	statusCache = {}
end

-- The XP this quest gives the character now: Forever's share by level gap.
function FQB.XP(id, plevel)
	local r = quests[id]
	if not (r and r.xp) then return nil end
	local L = P.Levels
	local share = (L and L.Share) and L.Share(plevel or FQB.PlayerLevel(), r.level) or 1
	return floor(r.xp * share + 0.5)
end

-- The quests that give itemID, as Lookup lists them (Codex item sources).
function FQB.QuestsForItem(itemID)
	local out = {}
	local Cx = Codex()
	local item = Cx and Cx.IsLoaded and Cx.IsLoaded() and Cx.Item(itemID)
	if not (item and type(item.sources) == "table") then return out end
	for _, src in ipairs(item.sources) do
		if src.type == "quest" and src.quest then
			out[#out + 1] = { quest = src.quest, choice = src.choice and true or false }
		end
	end
	return out
end

function FQB.ItemName(itemID)
	local Cx = Codex()
	local name = Cx and Cx.Name and Cx.Name("item", itemID)
	if name then return name end
	if C_Item and C_Item.GetItemNameByID then return C_Item.GetItemNameByID(itemID) end
	return GetItemInfo and (GetItemInfo(itemID)) or nil
end

function FQB.ItemIcon(itemID)
	if C_Item and C_Item.GetItemIconByID then
		local icon = C_Item.GetItemIconByID(itemID)
		if icon then return icon end
	end
	if GetItemIcon then return GetItemIcon(itemID) end
	return "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- text: lower case. The quest's title or one of its rewards' names holds it.
function FQB.Matches(id, text)
	if not text or text == "" then return true end
	local s = searchText[id]
	if not s then
		local r = quests[id]
		if not r then return false end
		local parts = { r.title }
		for _, list in ipairs({ r.rewards or {}, r.choices or {} }) do
			for _, item in ipairs(list) do
				parts[#parts + 1] = FQB.ItemName(item) or ""
			end
		end
		s = lower(concat(parts, "\n"))
		searchText[id] = s
	end
	return find(s, text, 1, true) ~= nil
end

local events = CreateFrame("Frame")
-- Not QUEST_LOG_UPDATE: it comes with every kill and loot, and nothing the
-- browser shows changes with it.
for _, ev in ipairs({ "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED", "PLAYER_LEVEL_UP" }) do
	events:RegisterEvent(ev)
end
local pendingChange = false
events:SetScript("OnEvent", function()
	FQB.Invalidate()
	if pendingChange then return end
	pendingChange = true
	C_Timer.After(0.5, function()
		pendingChange = false
		FQB.Changed()
	end)
end)
-- Names learned late (the names pack): search again from scratch.
if P.On then
	P.On("NAMES_LOADED", function() searchText = {} end)
end
