-- Polestar Freestyle: guides for the quests picked in the browser.
--
-- One guide for every quest picked (or marked): each quest's chain from the
-- first quest this character has not done (Polestar's Lookup.QuestChain:
-- prerequisites first, done ones left out, one branch of a "one of these"),
-- the chains merged without repeats and walked nearest giver first, never a
-- quest before its prerequisites. Each quest is one step made the way
-- Lookup's own quest guides make theirs (Lookup.QuestStep: accept, objectives
-- placed from the Codex, turn-in).
--
-- It is a Lookup planner kind (Polestar.Lookup.RegisterPlanner), so the guide
-- opens in its own tab as Lookup's and Dungeons' guides do:
--   lookup/freequestchain/<quest>-<quest>-...
-- On a hand-in the open guide is planned again in place (API.ReplaceSteps),
-- so it always leads to the next quest in line.
--
--   FQB.StartGuide(ids) -> guideId | nil, message
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
local FQB = FQ and FQ.Browser
if not (FQB and P.Lookup and P.Lookup.RegisterPlanner) then return end

local C, E = P.Compat, P.Engine
local API = P.API
if API and API.version ~= 1 then API = nil end
local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local huge, format, concat = math.huge, string.format, table.concat

local KIND = "freequestchain"
local PREFIX = "lookup/" .. KIND .. "/"
FQB.KIND, FQB.PREFIX = KIND, PREFIX
local MAX_TARGETS = 24

local function say(msg)
	if P.Print then P.Print(msg) else print("|cffe6ba66Polestar|r " .. msg) end
end

-- Targets -> the guide's key: quests as bare numbers (0.3's keys), items as
-- "i<id>" (Gear.lua's marked upgrades). Sorted, no repeats.
--   ids: { questID, ... }   items: { itemID, ... } (optional)
function FQB.GuideKey(ids, items)
	local seen, list = {}, {}
	local function add(tok, sortKey)
		if not seen[tok] then
			seen[tok] = true
			list[#list + 1] = { tok = tok, k = sortKey }
		end
	end
	for _, id in ipairs(ids or {}) do
		id = tonumber(id)
		if id then add(tostring(id), id) end
	end
	for _, id in ipairs(items or {}) do
		id = tonumber(id)
		if id then add("i" .. id, 1e9 + id) end
	end
	table.sort(list, function(a, b) return a.k < b.k end)
	local parts = {}
	for i = 1, math.min(#list, MAX_TARGETS) do parts[i] = list[i].tok end
	return concat(parts, "-"), #list
end

-- -> quest ids, item ids
local function parseKey(key)
	local quests, items = {}, {}
	for tok in tostring(key or ""):gmatch("[^%-]+") do
		local item = tok:match("^i(%d+)$")
		if item then
			items[#items + 1] = tonumber(item)
		else
			local q = tok:match("^q?(%d+)$")
			if q then quests[#quests + 1] = tonumber(q) end
		end
	end
	return quests, items
end

-- An item's way in: the lowest quest open to this character that gives it
-- (not done), else nil.
-- Read from the Codex itself: the browser's index may not be built yet (a
-- guide rebuilt at login).
local SHUT = { faction = true, race = true, class = true }
local function itemQuest(itemID)
	local Cx, Lk = P.Codex, P.Lookup
	local player = Lk.PlayerInfo()
	local best, bestLevel
	for _, s in ipairs(FQB.QuestsForItem(itemID)) do
		local q = Cx.Quest(s.quest)
		local why = q and Lk.QuestBlock(q, player)
		if q and not SHUT[why or ""] and not C.IsQuestCompleted(s.quest) and (not bestLevel or (q.level or 0) < bestLevel) then
			best, bestLevel = s.quest, q.level or 0
		end
	end
	return best
end

local function cost(a, b)
	if not (a and b) then return huge end
	return (P.DirectTravelCost and P.DirectTravelCost(a, b)) or huge
end

-- Where a quest is picked up, nearest `from`: a spawn { map, x, y, f } or nil.
local function giverPoint(Lk, q, from, player)
	local g = Lk.QuestEnd and Lk.QuestEnd(q.start, from, player, true)
	return g and g.spawn or nil
end

local function lastPoint(step)
	local goals = step and step.goals
	if type(goals) ~= "table" then return nil end
	for i = #goals, 1, -1 do
		local g = goals[i]
		if g.map and g.x and g.y then return { map = g.map, x = g.x, y = g.y, f = g.f } end
	end
	return nil
end

-- The quests to do, in order: every target's chain, merged, then walked
-- nearest giver first among the quests whose prerequisites are placed.
local function plan(targets)
	local Lk = P.Lookup
	local player = Lk.PlayerInfo()
	local list, byId = {}, {}
	for _, t in ipairs(targets) do
		local ok, chain = pcall(Lk.QuestChain, t, player)
		if ok and type(chain) == "table" then
			for _, q in ipairs(chain) do
				if q and q.id and not byId[q.id] and not C.IsQuestCompleted(q.id) then
					byId[q.id] = q
					list[#list + 1] = q
				end
			end
		end
	end
	-- Before each quest: its prerequisites in the list.
	local needs = {}
	for _, q in ipairs(list) do
		local n = {}
		for _, src in ipairs({ q.pre or {}, q.preAny or {} }) do
			for _, p in ipairs(src) do
				if byId[p] then n[#n + 1] = p end
			end
		end
		needs[q.id] = n
	end
	local placed, out = {}, {}
	local left = {}
	for i, q in ipairs(list) do left[i] = q end
	local here = P.PlayerPoint and P.PlayerPoint() or nil
	while #left > 0 do
		local bi, bc, bp
		for i, q in ipairs(left) do
			local ready = true
			for _, p in ipairs(needs[q.id]) do
				if not placed[p] then
					ready = false
					break
				end
			end
			if ready then
				local pt = giverPoint(Lk, q, here, player)
				local c = cost(here, pt)
				if not pt then c = huge end
				if not bi or c < bc then bi, bc, bp = i, c, pt end
			end
		end
		-- A loop in the data: take them in chain order.
		bi = bi or 1
		local q = table.remove(left, bi)
		placed[q.id] = true
		out[#out + 1] = q
		if bp then here = bp end
	end
	return out
end

local function titleFor(targets, items)
	local Cx = P.Codex
	local name
	local n = #targets + #items
	if #items > 0 then
		name = FQB.ItemName(items[1]) or ("Item " .. tostring(items[1]))
		name = "Gear: " .. name
	else
		local q = targets[1] and Cx.Quest(targets[1])
		name = "Quest chains: " .. ((q and q.title) or ("Quest " .. tostring(targets[1])))
	end
	if n > 1 then return format("%s (+%d)", name, n - 1) end
	return name
end

-- An item no open quest gives: Lookup's own guide to its best source (a
-- dungeon boss, a rare, a vendor), its steps.
local function itemSteps(itemID)
	local Lk = P.Lookup
	local ok, def = pcall(Lk.BuildGuide, "item", itemID)
	if not (ok and type(def) == "table" and type(def.steps) == "table") then return {} end
	local name = FQB.ItemName(itemID)
	local steps = {}
	for i, s in ipairs(def.steps) do
		if i == 1 and name and type(s.title) == "string" and not s.title:find(name, 1, true) then
			s.title = name .. ": " .. s.title
		end
		steps[#steps + 1] = s
	end
	return steps
end

local function build(key)
	local Cx, Lk = P.Codex, P.Lookup
	if not (Cx and Lk and Lk.QuestChain and Lk.QuestStep) then return nil, "missing" end
	local ok, reason = Cx.Load()
	if not ok then return nil, reason end
	local targets, items = parseKey(key)
	if #targets == 0 and #items == 0 then return nil, "unknown" end
	-- Items a quest gives join the quest chains; the rest get Lookup's guides.
	local questTargets, rest = {}, {}
	for _, id in ipairs(targets) do questTargets[#questTargets + 1] = id end
	for _, item in ipairs(items) do
		local q = itemQuest(item)
		if q then questTargets[#questTargets + 1] = q else rest[#rest + 1] = item end
	end
	local quests = plan(questTargets)
	local steps = {}
	local here = P.PlayerPoint and P.PlayerPoint() or nil
	for _, q in ipairs(quests) do
		local okStep, step = pcall(Lk.QuestStep, q, here)
		if okStep and type(step) == "table" and type(step.goals) == "table" and #step.goals > 0 then
			steps[#steps + 1] = step
			here = lastPoint(step) or here
		end
	end
	for _, item in ipairs(rest) do
		if not (C.GetItemCount and (C.GetItemCount(item, true) or 0) > 0) then
			for _, s in ipairs(itemSteps(item)) do steps[#steps + 1] = s end
		end
	end
	if #steps == 0 then
		if #quests == 0 then return nil, "done" end
		return nil, "noguide"
	end
	return {
		title = titleFor(targets, items),
		category = FQ.CATEGORY or "Freestyle questing",
		why = "The quests you picked in the quest browser, each from the first quest of its chain you have not done.",
		keywords = { "free", "questing", "quest chain", "rewards" },
		steps = steps,
	}
end

P.Lookup.RegisterPlanner(KIND, build)

local MESSAGES = {
	done = "All the picked quests are done.",
	tabs = "Six guide tabs is the limit. Close one, then try again.",
	login = "Log in first.",
	combat = "Polestar's data loads after combat. Try again in a moment.",
	noguide = "No guide could be made: Polestar's data has no place for these quests' givers.",
	unknown = "Pick a quest first.",
	missing = "This needs Polestar's Lookup data (Polestar_Codex).",
}
FQB.MESSAGES = MESSAGES

function FQB.StartGuide(ids, items)
	local key, n = FQB.GuideKey(ids or {}, items)
	if key == "" then return nil, MESSAGES.unknown end
	local gid, reason = P.Lookup.Guide(KIND, key)
	if not gid then
		return nil, MESSAGES[reason] or format("No guide could be made (%s).", tostring(reason))
	end
	-- The guide opens in its tab; the hub steps aside, as Lookup's guides do.
	if P.Set then pcall(P.Set, "ui.shown", true) end
	local Pk = P.UI and P.UI.Picker
	if Pk and Pk.frame and Pk.frame.Hide then Pk.frame:Hide() end
	if P.Fire then P.Fire("SHOW_FRAME") end
	if n > MAX_TARGETS then say(format("Quest chains: the first %d of %d picked quests.", MAX_TARGETS, n)) end
	return gid
end

---------------------------------------------------------------------------
-- Keeping open guides on the next quest
---------------------------------------------------------------------------

local function openGuides()
	local out = {}
	local ok, tabs = pcall(E.GetTabs)
	if not (ok and type(tabs) == "table") then return out end
	for _, t in ipairs(tabs) do
		if type(t.guideId) == "string" and t.guideId:sub(1, #PREFIX) == PREFIX then out[#out + 1] = t.guideId end
	end
	return out
end

local pending = false
local function replan(delay)
	if pending or not (API and API.ReplaceSteps) then return end
	pending = true
	C_Timer.After(delay or 1, function()
		pending = false
		for _, gid in ipairs(openGuides()) do
			local def = P.Lookup.BuildGuide(KIND, gid:sub(#PREFIX + 1))
			if def and def.steps then
				local ok, err = API.ReplaceSteps(gid, def.steps)
				if not ok and err == "busy" then replan(0.2) end
			end
		end
	end)
end
FQB.Replan = replan

local events = CreateFrame("Frame")
events:RegisterEvent("QUEST_TURNED_IN")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, ev)
	-- At login the quests done are known: the restored tabs get their real steps.
	replan(ev == "PLAYER_LOGIN" and 3 or 1)
end)

-- A tab of one of these guides saved at logout comes back: Polestar rebuilds
-- planner guides before this addon loads, so build them here, while the
-- files load, before the Engine reopens its tabs at login.
do
	local ok, s = pcall(P.CharState)
	if ok and type(s) == "table" then
		local ids = {}
		if type(s.tabs) == "table" then
			for _, gid in pairs(s.tabs) do ids[#ids + 1] = gid end
		end
		ids[#ids + 1] = s.guide
		for _, gid in ipairs(ids) do
			if type(gid) == "string" and gid:sub(1, #PREFIX) == PREFIX and not (P.Guides and P.Guides.Get and P.Guides.Get(gid)) then
				local okB, def = pcall(P.Lookup.BuildGuide, KIND, gid:sub(#PREFIX + 1))
				if okB and type(def) == "table" and def.id == gid then
					P.RegisterGuide(def)
				else
					-- No data yet: a holder the login replan fills.
					P.RegisterGuide({ id = gid, pack = "lookup", title = "Quest chains", category = FQ.CATEGORY or "Freestyle questing",
						author = "Polestar_Freestyle", version = 1,
						steps = { { title = "Quest chains", goals = { { t = "task", text = "Reading Polestar's quest data..." } } } } })
				end
			end
		end
	end
end
