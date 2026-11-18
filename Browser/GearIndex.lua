-- Polestar Freestyle: the gear planner's index.
--
-- Every uncommon or better item this character could wear (Polestar's gear
-- advice decides: armour type, weapon skills, class), by equipment slot, with
-- where it comes from, read from Polestar's Codex:
--   quest    a quest this character can take (the quest browser's index)
--   dungeon  a drop inside a dungeon (or raid)
--   rare     a drop from a rare or elite mob in the open world
--   vendor   sold by an NPC
-- Never the auction house, world drops, crafting or PvP.
--
-- What is recommended: an item you can wear now or at your next level, from
-- a source within reach. Reach is Polestar's own "Quests above your level"
-- setting, applied to the sources (the quest's level, the dungeon's, the
-- rare's), never to the item. An item for a higher level is kept only when a
-- quest within reach gives it (a level 28 doing a level 30 quest for its
-- level 30 boots). Scored against what is worn with Polestar's own upgrade
-- maths (the percentages of its item tooltips); a ring or trinket against
-- the one in the slot you picked.
--
-- Each source of a result carries how near it is:
--   tier   1 under way (in your log, or its chain started)
--          2 ready now (open quest, dungeon or rare at your level, vendor)
--          3 soon (earlier quests first, a level to go)
--   steps  quests left in its chain up to it; rare 2, dungeon 3, vendor 1
--   todo   what that reads as ("in your log", "3 quests left", "dungeon")
--
--   FQG.Build()                 -> starts the index (sliced); FQG.State()
--   FQG.Results(slot)           -> { { id, pct, delta, empty, req, wearNow, quality, sources }, ... } | nil
--   FQG.Rank(res, keep)         -> tier, steps, best source (over the sources keep(src) lets through)
--   FQG.Rescore()               -> scores again (gear, level, quests or the setting changed)
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
local FQB = FQ and FQ.Browser
if not FQB then return end

local C = P.Compat
local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local min, max = math.min, math.max
local format = string.format

local FQG = {}
FQB.Gear = FQG

-- The slots, as the character pane has them.
FQG.SLOTS = { 1, 2, 3, 15, 5, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 }
-- Rings and trinkets: scored against the one in the slot picked.
local PAIRED = { [11] = 12, [12] = 11, [13] = 14, [14] = 13 }

local SLICE = 400   -- items read per frame
local SCORE_SLICE = 120
local KEEP = 200    -- results kept per slot (best gain first)

local state, failReason = "idle", nil
local bySlot = {}      -- slot -> { itemID, ... }
local sources = {}     -- itemID -> { source, ... } | false
local results = {}     -- slot -> results
local scoring = false
local scoreGen = 0

function FQG.State() return state, failReason end
function FQG.Scoring() return scoring end

local function changed() FQB.Changed() end

local function anyLevel()
	local Q = P.QuestDB
	return (Q and Q.LEVEL_WINDOW_ANY) or 10
end

-- How far above your level a source may be: Polestar's level window.
function FQG.Window()
	local w = P.Get and tonumber(P.Get("qol.questLevelWindow")) or 5
	if w >= anyLevel() then return nil end
	return w
end

local function reachLevel(plevel)
	local w = FQG.Window()
	return w and (plevel + w) or 999
end

local function api()
	local G, DB, Cx = P.Gear, P.ItemDB, P.Codex
	if not (G and G.Usability and G.SLOTS_OF and G.CompareToEquipped and G.ScoreItem and DB and DB.Get and DB.Load and Cx and Cx.Each and Cx.Item) then
		return nil
	end
	return G, DB, Cx
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
			FQG.Build()
		end
	end)
end

local function fail(reason)
	state, failReason = "failed", reason
	changed()
end

-- After the player fixed what stopped it (gear advice turned on): try again.
function FQG.Retry()
	if state == "failed" then
		state, failReason = "idle", nil
		FQG.Build()
	end
end

---------------------------------------------------------------------------
-- Where an item comes from
---------------------------------------------------------------------------

local function classify(id)
	local s = sources[id]
	if s ~= nil then return s or nil end
	local Cx = P.Codex
	local item = Cx.Item(id)
	local out = {}
	if item and type(item.sources) == "table" then
		for _, src in ipairs(item.sources) do
			if src.type == "quest" and src.quest then
				local q = FQB.Quest(src.quest)
				if q then
					out[#out + 1] = { kind = "quest", quest = src.quest, choice = src.choice and true or false,
						name = q.title, zone = q.zone, level = q.level, minLevel = q.minLevel }
				end
			elseif src.type == "drop" and src.npc then
				local npc = Cx.Npc(src.npc)
				local inst = src.instance or (npc and npc.instance)
				if inst then
					local I = Cx.Instance and Cx.Instance(inst)
					out[#out + 1] = { kind = "dungeon", instance = inst, name = (I and I.name) or tostring(inst),
						raid = I and I.kind == "raid" or nil, levelMin = I and I.levels and I.levels[1] or nil,
						npc = src.npc, npcName = npc and npc.name, chance = src.chance }
				elseif npc and (npc.rare or npc.elite) then
					out[#out + 1] = { kind = "rare", npc = src.npc, name = npc.name, level = npc.level,
						rare = npc.rare and true or nil, elite = npc.elite and true or nil, chance = src.chance }
				end
			elseif src.type == "vendor" and src.npc then
				local npc = Cx.Npc(src.npc)
				out[#out + 1] = { kind = "vendor", npc = src.npc, name = npc and npc.name, cost = src.cost }
			end
		end
	end
	if #out == 0 then out = false end
	sources[id] = out
	return out or nil
end
FQG.Sources = classify

-- The quests still to do in a quest's chain, up to and with it; the chain's
-- done count and length. -> left, done, total (nil, nil, nil: no chain)
local function chainLeft(qid)
	local ch = FQB.ChainOf(qid)
	if not ch then return nil end
	local left, done = 0, 0
	local reached = false
	for _, id in ipairs(ch.quests) do
		local isDone = FQB.Status(id) == "done"
		if isDone then done = done + 1 end
		if not reached and not isDone then left = left + 1 end
		if id == qid then reached = true end
	end
	return max(1, left), done, #ch.quests
end

-- A source as reached from where you stand -> a copy with tier, steps, todo;
-- nil when out of reach or done.
local function reach(src, plevel, top)
	local r = {}
	for k, v in pairs(src) do r[k] = v end
	if src.kind == "quest" then
		local st = FQB.Status(src.quest)
		if st == "done" then return nil end
		if (src.level or 0) > top or (src.minLevel or 0) > top then return nil end
		local left, done, total = chainLeft(src.quest)
		r.chainDone, r.chainTotal = done, total
		r.steps = left or 1
		if st == "log" or (done and done > 0) then
			r.tier = 1
		elseif st == "available" then
			r.tier = 2
		else
			r.tier = 3
		end
		if st == "log" then
			r.todo = "in your log"
		elseif left and left > 1 then
			r.todo = format("%d quests left", left)
		elseif st == "level" then
			r.todo = format("quest lvl %d", src.minLevel or src.level or 0)
		else
			r.todo = "quest"
		end
	elseif src.kind == "dungeon" then
		local lo = src.levelMin
		if lo and lo > top + (src.raid and 0 or 2) then return nil end
		r.tier = (not lo or lo <= plevel) and 2 or 3
		r.steps = 3
		r.todo = src.raid and "raid" or "dungeon"
	elseif src.kind == "rare" then
		local lvl = src.level
		if lvl and lvl > top + (src.elite and 2 or 0) then return nil end
		r.tier = (not lvl or lvl <= plevel + 2) and 2 or 3
		r.steps = 2
		r.todo = src.rare and "rare" or "elite"
	elseif src.kind == "vendor" then
		r.tier, r.steps, r.todo = 2, 1, "vendor"
	else
		return nil
	end
	return r
end

-- A result's nearness over the sources keep(src) lets through ->
-- tier, steps, the best source (nil: none kept).
function FQG.Rank(res, keep)
	local best
	for _, src in ipairs(res.sources or {}) do
		if not keep or keep(src) then
			if not best or src.tier < best.tier or (src.tier == best.tier and src.steps < best.steps) then best = src end
		end
	end
	if not best then return nil end
	local tier, steps = best.tier, best.steps
	if not res.wearNow then
		if tier == 2 then tier = 3 end
		steps = steps + 1
	end
	return tier, steps, best
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------

function FQG.Build()
	if state == "loading" or state == "ready" or state == "waiting" then return end
	local G, DB, Cx = api()
	if not G then
		fail("missing")
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		state, failReason = "waiting", "combat"
		afterCombat()
		changed()
		return
	end
	state, failReason = "loading", nil
	-- The quest browser's index first: it says which quests are this character's.
	FQB.Build(function(ok, reason)
		if not ok then
			fail(reason == "combat" and "combat" or (reason or "codex"))
			return
		end
		if not DB.Load() and not (DB.IsLoaded and DB.IsLoaded()) then
			fail("itemdb")
			return
		end
		local ids = {}
		Cx.Each("item", function(id, _, quality, status)
			id = tonumber(id)
			if id and (quality or 0) >= 2 and status ~= "retired" then ids[#ids + 1] = id end
		end)
		local i = 0
		local function slice()
			local okSlice, err = pcall(function()
				local stop = min(#ids, i + SLICE)
				for k = i + 1, stop do
					local id = ids[k]
					local rec = DB.Get(id)
					local slots = rec and rec.inv and G.SLOTS_OF[rec.inv]
					if slots and G.Usability(rec) then
						for _, slot in ipairs(slots) do
							local list = bySlot[slot]
							if not list then
								list = {}
								bySlot[slot] = list
							end
							list[#list + 1] = id
						end
					end
				end
				i = stop
			end)
			if not okSlice then
				fail(tostring(err))
				return
			end
			if i < #ids then
				C_Timer.After(0, slice)
			else
				state = "ready"
				FQG.Rescore()
			end
		end
		slice()
	end)
end

---------------------------------------------------------------------------
-- Scoring
---------------------------------------------------------------------------

local function byGain(a, b)
	local pa, pb = a.pct or (a.empty and 1e6) or 0, b.pct or (b.empty and 1e6) or 0
	if pa ~= pb then return pa > pb end
	if (a.delta or 0) ~= (b.delta or 0) then return (a.delta or 0) > (b.delta or 0) end
	return (a.req or 0) < (b.req or 0)
end

-- The sources within reach; above your next level, only the quests that
-- give gear for about their own level.
local function reachable(srcs, req, plevel, top)
	local out = {}
	local high = req > plevel + 1
	for _, src in ipairs(srcs) do
		if not high or (src.kind == "quest" and (src.level or 0) >= req - 2) then
			local r = reach(src, plevel, top)
			if r then out[#out + 1] = r end
		end
	end
	return out
end

-- The gain for a ring or trinket against the one in this slot.
local function pairedGain(G, slot, id, rec)
	local wornID = GetInventoryItemID and GetInventoryItemID("player", slot)
	if wornID == id then return nil end
	-- A unique one already worn in the other slot cannot go here too.
	local other = PAIRED[slot]
	if rec.unique and other and GetInventoryItemID and GetInventoryItemID("player", other) == id then return nil end
	local new = G.ScoreItem("item:" .. id)
	if not new then return nil end
	local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
	if not link then return { delta = new, empty = true } end
	local old = G.ScoreItem(link)
	if not old then return nil end
	local delta = new - old
	return { delta = delta, pct = old > 0 and delta / old * 100 or nil }
end

-- Scores every slot again, a slice per frame; the page repaints when done.
function FQG.Rescore()
	if state ~= "ready" then return end
	local G, DB = api()
	if not G then return end
	scoreGen = scoreGen + 1
	local gen = scoreGen
	scoring = true
	local plevel = FQB.PlayerLevel()
	local top = reachLevel(plevel)
	local fresh = {}
	local work = {}
	for _, slot in ipairs(FQG.SLOTS) do
		fresh[slot] = {}
		for _, id in ipairs(bySlot[slot] or {}) do work[#work + 1] = { slot = slot, id = id } end
	end
	local compared = {} -- itemID -> CompareToEquipped's answer (the other slots share it)
	local i = 0
	local function slice()
		if gen ~= scoreGen then return end
		local ok, err = pcall(function()
			local stop = min(#work, i + SCORE_SLICE)
			for k = i + 1, stop do
				local w = work[k]
				local rec = DB.Get(w.id)
				local srcs = rec and classify(w.id)
				local req = rec and rec.req or 0
				if srcs and req <= max(plevel + 1, top + 2) then
					local near = reachable(srcs, req, plevel, top)
					if #near > 0 then
						local gain
						if PAIRED[w.slot] then
							gain = pairedGain(G, w.slot, w.id, rec)
						else
							local r = compared[w.id]
							if r == nil then
								r = G.CompareToEquipped("item:" .. w.id) or false
								compared[w.id] = r
							end
							if r and r.usable and not r.equipped and r.delta then
								gain = { delta = r.delta, pct = r.pct, empty = r.empty }
							end
						end
						if gain and gain.delta and gain.delta > 0 then
							local list = fresh[w.slot]
							list[#list + 1] = {
								id = w.id, pct = gain.pct, delta = gain.delta, empty = gain.empty,
								req = req, wearNow = req <= plevel, quality = rec.quality, ilvl = rec.ilvl,
								sources = near,
							}
						end
					end
				end
			end
			i = stop
		end)
		if not ok then
			scoring = false
			fail(tostring(err))
			return
		end
		if i < #work then
			C_Timer.After(0, slice)
			return
		end
		for _, list in pairs(fresh) do
			table.sort(list, byGain)
			for k = #list, KEEP + 1, -1 do list[k] = nil end
		end
		results = fresh
		scoring = false
		changed()
	end
	slice()
end

function FQG.Results(slot)
	return results[slot]
end

-- Gear, level, quests or the level window changed: score again (once a
-- second at most).
local pending = false
local function later()
	if pending or state ~= "ready" then return end
	pending = true
	C_Timer.After(1, function()
		pending = false
		FQG.Rescore()
	end)
end
FQG.Later = later

local events = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED" }) do
	events:RegisterEvent(ev)
end
events:SetScript("OnEvent", later)
if P.On then
	P.On("GEAR_UPDATED", later)
	P.On("SETTING_CHANGED", function(path)
		if path == "qol.questLevelWindow" or path == "" or path == "qol" or path == nil then later() end
	end)
end
