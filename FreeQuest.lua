-- Polestar Freestyle: a guide built from the quests already in your log.
--
-- Polestar's leveling guides walk a planned route. This addon plays the quests
-- you picked up yourself in the same guide window, with the same arrow, map
-- pins and auto turn-in: one step per quest for its objectives (kill, collect,
-- use, talk), placed where Polestar's quest database (Polestar_QuestDB) has
-- the mobs, drops and objects, and hand-in steps at the quest's ender. Steps
-- are ordered by a nearest-first walk from where you stand, a hand-in always
-- after its quest's work.
--
-- Scope: "zone" (default) takes the quests of the zone you are in (the quest
-- log's zone header, or work or a ready hand-in on its map) and follows you
-- from zone to zone; "pin" stays on one zone you chose wherever you are;
-- "all" takes every quest in the log. Chosen in the guide window's menu
-- (Questing zone) or with the command.
--
-- Built only on Polestar's public API (docs/API.md: RegisterGuide,
-- Engine.SetGuide, API.ReplaceSteps, On/Off, Compat's quest state) plus the
-- read-only lookups of Polestar.QuestDB, which Polestar's own map markers use.
--
--   /polestar free          open (or refresh) free questing for this zone
--   /polestar free all      every quest in the log
--   /polestar free zone     back to following the zone you are in
--   /polestar free wetlands one zone's quests, wherever you are (a part of
--                           the name will do: /polestar free dusk)
--   /polestar free close    close its tab
--   (/freequest works the same when Polestar's command is unavailable.)
--
-- License: GPL-3.0-only, as Polestar.

local ADDON = ...

local P = Polestar
-- Polestar 0.4.0+ has the public API (ReplaceSteps); 0.3.x gets new steps by
-- registering the guide again and PACKS_CHANGED, as its own Import page does.
local API = P and P.API
if API and API.version ~= 1 then API = nil end
if not (P and P.RegisterPack and P.RegisterGuide and P.Engine and P.QuestDB and P.Compat and P.On) then
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_LOGIN")
	f:SetScript("OnEvent", function()
		print("|cffe6ba66Polestar Freestyle|r needs Polestar 0.3.7 or newer.")
	end)
	return
end

local Q, C, E = P.QuestDB, P.Compat, P.Engine

local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local format, lower, find, concat = string.format, string.lower, string.find, table.concat
local huge, max, min, floor = math.huge, math.max, math.min, math.floor

local FQ = {}
P.FreeQuest = FQ -- for /dump and tests; not an API

local PACK = "freequest"
local GUIDE_ID = "freequest/log"
FQ.GUIDE_ID = GUIDE_ID
local TITLE = "Freestyle questing"
-- The guide's category: its own, so its tab and card carry its icon.
local CATEGORY = "Freestyle questing"
FQ.CATEGORY = CATEGORY
local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
local ICON = MEDIA .. "freequest"
FQ.ICON = ICON
local NEXT = " \226\128\186" -- " ›", as Polestar's own sub-menus

-- Spawn areas, as Polestar's own generated goals have them: the cluster
-- nearest the goal point first, a few camps, the rest alternatives.
local SPOT_CAMPS, SPOT_CAP, SPOT_R_MIN, SPOT_R_MAX = 6, 24, 15, 70
-- An item source is kept when it gives the item at least this share of the
-- best source's chance.
local SOURCE_SHARE, SOURCE_CAP = 0.3, 4
local REPLAN_DELAY = 0.5

local function say(msg)
	if P.Print then P.Print(msg) else print("|cffe6ba66Polestar|r " .. msg) end
end

local function charDB()
	PolestarFreeQuestCharDB = type(PolestarFreeQuestCharDB) == "table" and PolestarFreeQuestCharDB or {}
	local db = PolestarFreeQuestCharDB
	if db.scope ~= "zone" and db.scope ~= "all" and db.scope ~= "pin" then db.scope = "zone" end
	if db.scope == "pin" and not (type(db.pin) == "table" and type(db.pin.name) == "string") then db.scope = "zone" end
	-- The quest browser (Browser/): marked quests, and its own view.
	if type(db.marked) ~= "table" then db.marked = {} end
	if type(db.browser) ~= "table" then db.browser = {} end
	local b = db.browser
	if type(b.selected) ~= "table" then b.selected = {} end
	-- Open zones and chains, per filter (0.3's one `expanded` set became the
	-- All quests filter's).
	if type(b.open) ~= "table" then
		b.open = {}
		if type(b.expanded) == "table" then b.open.all = b.expanded end
	end
	b.expanded = nil
	if b.filter == "level" then b.filter = "available" end
	-- 0.3 kept the sort as a key: now a column and a direction.
	if type(b.sort) ~= "table" then b.sort = { key = (b.sort == "xp" or b.sort == "name") and b.sort or "level", desc = b.sort == "xp" } end
	-- The gear section: marked items, the sources it lists, the slot it shows.
	if type(db.gear) ~= "table" then db.gear = {} end
	local g = db.gear
	if type(g.marked) ~= "table" then g.marked = {} end
	if type(g.sources) ~= "table" then g.sources = { quest = true, dungeon = true, rare = true, vendor = false } end
	if type(g.slot) ~= "number" then g.slot = 18 end
	return db
end
FQ.CharDB = charDB

---------------------------------------------------------------------------
-- Places
---------------------------------------------------------------------------

-- Travel seconds between two points { map, x, y, f }, straight-line; huge
-- when either cannot be placed. The plan asks thousands of times, so never
-- the route planner.
local function cost(a, b)
	if not (a and b) then return huge end
	local d = P.DirectTravelCost and P.DirectTravelCost(a, b)
	return d or huge
end

local function nearest(spawns, from)
	if type(spawns) ~= "table" or #spawns == 0 then return nil, huge end
	if not from then return spawns[1], huge end
	local best, bestC = nil, huge
	for i = 1, #spawns do
		local s = spawns[i]
		local c = cost(from, s)
		if c < bestC or not best then best, bestC = s, c end
	end
	return best, bestC
end

-- A goal at spawn s, with the target's other clusters on the same map and
-- frame as spawn areas.
local function place(goal, s, spawns)
	if not (s and s.map and s.x and s.y) then return goal end
	goal.map, goal.x, goal.y, goal.f = s.map, s.x, s.y, s.f == "e" and "e" or nil
	if type(spawns) ~= "table" then return goal end
	local same = {}
	for _, p in ipairs(spawns) do
		if p.map == s.map and (p.f == "e") == (goal.f == "e") and p.x and p.y then same[#same + 1] = p end
	end
	if #same < 2 then
		if s.r and s.r > 8 then goal.r = min(floor(s.r + 0.5), SPOT_R_MAX) end
		return goal
	end
	local d = {}
	for _, p in ipairs(same) do d[p] = cost(s, p) end
	table.sort(same, function(a, b)
		if d[a] ~= d[b] then return d[a] < d[b] end
		if a.x ~= b.x then return a.x < b.x end
		return a.y < b.y
	end)
	local spots = {}
	for i = 1, min(#same, SPOT_CAP) do
		local p = same[i]
		local r = floor(max(SPOT_R_MIN, min(SPOT_R_MAX, p.r or 30)) + 0.5)
		spots[i] = { x = p.x, y = p.y, r = r, n = 1, alt = i > SPOT_CAMPS or nil }
	end
	goal.spots = spots
	return goal
end

local function onMap(spawns, map)
	if not (map and type(spawns) == "table") then return false end
	for i = 1, #spawns do
		if spawns[i].map == map then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- The quest log
---------------------------------------------------------------------------

-- { { id, header }, ... } in log order. Quests under a collapsed header are
-- found through the database (header unknown).
local function logQuests()
	local out, seen, header, collapsed = {}, {}, nil, false
	local QL = C_QuestLog
	if QL and QL.GetNumQuestLogEntries and QL.GetInfo then
		for i = 1, QL.GetNumQuestLogEntries() or 0 do
			local info = QL.GetInfo(i)
			if info then
				if info.isHeader then
					header = info.title
					if info.isCollapsed then collapsed = true end
				elseif not info.isHidden then
					local q = C.Readable and C.Readable(info.questID) or info.questID
					if type(q) == "number" and q > 0 and not seen[q] then
						seen[q] = true
						out[#out + 1] = { id = q, header = header }
					end
				end
			end
		end
	end
	if collapsed and Q.QuestIds then
		for _, q in ipairs(Q.QuestIds()) do
			if not seen[q] and C.IsOnQuest(q) then
				seen[q] = true
				out[#out + 1] = { id = q }
			end
		end
	end
	return out
end

-- Which log line each database objective is, by name as Polestar's tracker
-- matches them (a label equal to the name, then a name inside the text, then
-- the same position) -> finished[oi], line[oi].
local function matchLines(objectives, lines)
	local finished, lineOf, used = {}, {}, {}
	if not lines then return finished, lineOf end
	local label = C.ObjectiveLabel or function(t) return t end
	local labels = {}
	for k, l in ipairs(lines) do labels[k] = label(l.text or "") end
	local function claim(oi, test)
		if lineOf[oi] then return end
		for k = 1, #lines do
			if not used[k] and test(k) then
				used[k], lineOf[oi] = true, k
				return
			end
		end
	end
	for oi, o in ipairs(objectives) do
		if o.name then claim(oi, function(k) return labels[k] == o.name end) end
	end
	for oi, o in ipairs(objectives) do
		if o.name then claim(oi, function(k) return labels[k] ~= "" and find(lines[k].text or "", o.name, 1, true) ~= nil end) end
	end
	for oi in ipairs(objectives) do
		if not lineOf[oi] and lines[oi] and not used[oi] then used[oi], lineOf[oi] = true, oi end
	end
	for oi in ipairs(objectives) do
		local k = lineOf[oi]
		finished[oi] = k and lines[k].finished or false
	end
	return finished, lineOf
end

---------------------------------------------------------------------------
-- One quest's work and hand-in
---------------------------------------------------------------------------

local function npcOf(id) return id and Q.GetNpc(id) or nil end
local function objectOf(id) return id and Q.GetObject(id) or nil end

-- Where an item comes from: its best sources with a known place, best
-- chance first -> spawns (all of them), the sources, a vendor line or nil.
local function itemSources(itemId)
	local item = Q.GetItem(itemId)
	if not item then return nil end
	local srcs = {}
	for _, d in ipairs(item.droppers or {}) do
		local n = npcOf(d.id)
		if n and #n.spawns > 0 then srcs[#srcs + 1] = { kind = "npc", id = d.id, name = n.name or d.name, chance = d.chance or 0, spawns = n.spawns } end
	end
	for _, o in ipairs(item.objects or {}) do
		local ob = objectOf(o.id)
		if ob and #ob.spawns > 0 then srcs[#srcs + 1] = { kind = "object", id = o.id, name = ob.name or o.name, chance = o.chance or 0, spawns = ob.spawns } end
	end
	table.sort(srcs, function(a, b)
		if a.chance ~= b.chance then return a.chance > b.chance end
		return a.id < b.id
	end)
	local kept, spawns = {}, {}
	local best = srcs[1] and srcs[1].chance or 0
	for _, s in ipairs(srcs) do
		if #kept < SOURCE_CAP and (s.chance >= best * SOURCE_SHARE or s.chance == 0) then
			kept[#kept + 1] = s
			for _, p in ipairs(s.spawns) do spawns[#spawns + 1] = p end
		end
	end
	if #kept > 0 then return item, spawns, kept end
	-- Nothing drops it where the data knows: a vendor that sells it.
	for _, v in ipairs(item.vendors or {}) do
		local n = npcOf(v.id)
		if n and #n.spawns > 0 then
			return item, n.spawns, nil, format("Sold by %s.", n.name or v.name or "a vendor")
		end
	end
	return item, nil, nil
end

-- A quest's objective goals with where each can be done:
-- { goal = goal, spawns = spawns | nil, done = bool }, ...
local function objectiveWork(q, rec, title, ready)
	local work = {}
	local objs = rec and rec.objectives or {}
	local named = {}
	for oi, o in ipairs(objs) do
		local name
		if o.kind == "kill" or o.kind == "talk" then
			local n = npcOf(o.id)
			name = n and n.name
		elseif o.kind == "item" then
			local it = Q.GetItem(o.id)
			name = it and it.name
		elseif o.kind == "object" then
			local ob = objectOf(o.id)
			name = ob and ob.name
		end
		named[oi] = { name = name }
	end
	local lines = C.GetQuestObjectives(q)
	local finished, lineOf = matchLines(named, lines)
	local event
	for oi, o in ipairs(objs) do
		local done = ready or finished[oi] or false
		local count = o.count or 1
		local w
		if o.kind == "kill" and o.id then
			local n = npcOf(o.id)
			local target = (n and n.name) or (lineOf[oi] and C.ObjectiveLabel(lines[lineOf[oi]].text or "")) or ("NPC " .. o.id)
			w = { goal = { t = "kill", target = target, npc = o.id, quest = q, oi = oi, count = count, title = title }, spawns = n and n.spawns }
		elseif o.kind == "item" and o.id then
			local item, spawns, srcs, vendor = itemSources(o.id)
			local goal = { t = "collect", item = o.id, itemName = (item and item.name) or ("Item " .. o.id), quest = q, oi = oi, count = count, title = title }
			if srcs and srcs[1] then
				goal.from, goal.fromId, goal.fromKind = srcs[1].name, srcs[1].id, srcs[1].kind
				local s2 = srcs[2]
				if s2 and s2.kind == srcs[1].kind and s2.name ~= goal.from then goal.fromAlso, goal.fromAlsoId = s2.name, s2.id end
			end
			if vendor then goal.note = vendor end
			w = { goal = goal, spawns = spawns }
		elseif o.kind == "object" and o.id then
			local ob = objectOf(o.id)
			w = { goal = { t = "interact", object = o.id, objName = (ob and ob.name) or ("Object " .. o.id), quest = q, oi = oi, count = count, title = title }, spawns = ob and ob.spawns }
		elseif o.kind == "talk" and o.id then
			local n = npcOf(o.id)
			w = { goal = { t = "talk", npc = o.id, npcName = (n and n.name) or ("NPC " .. o.id), quest = q, oi = oi, title = title }, spawns = n and n.spawns }
		elseif not event then
			-- An event (explore, escort, use at a place): one "complete" for the quest.
			local text = lineOf[oi] and C.ObjectiveLabel(lines[lineOf[oi]].text or "") or nil
			event = true
			local spawns = (o.map and o.x and o.y) and { { map = o.map, x = o.x, y = o.y, f = o.f } } or nil
			w = { goal = { t = "complete", quest = q, title = title, text = (text and text ~= "") and text or nil }, spawns = spawns, last = true }
		end
		if w then
			w.done = done
			work[#work + 1] = w
		end
	end
	-- The database knows no objectives but the log has lines: finish it as a whole.
	if #work == 0 and not ready then
		work[1] = { goal = { t = "complete", quest = q, title = title }, done = false, last = true }
	end
	return work
end

-- The quest's ender: { ref, name, spawns } candidates (NPCs, then objects).
local function enders(rec)
	local out = {}
	if not rec then return out end
	for _, id in ipairs(rec.finish and rec.finish.npc or {}) do
		local n = npcOf(id)
		out[#out + 1] = { npc = id, name = (n and n.name) or ("NPC " .. id), spawns = n and n.spawns }
	end
	for _, id in ipairs(rec.finish and rec.finish.object or {}) do
		local ob = objectOf(id)
		out[#out + 1] = { object = id, name = (ob and ob.name) or ("Object " .. id), spawns = ob and ob.spawns }
	end
	return out
end

---------------------------------------------------------------------------
-- Scope
---------------------------------------------------------------------------

local function zoneHere()
	local map = C.GetUnitZone and C.GetUnitZone("player") or nil
	local name = map and C.MapName and C.MapName(map) or nil
	local text = C.GetZoneText and C.GetZoneText() or (GetZoneText and GetZoneText())
	return map, name or text, text
end

local function sameName(a, b)
	return type(a) == "string" and type(b) == "string" and a ~= "" and lower(a) == lower(b)
end

---------------------------------------------------------------------------
-- The plan
---------------------------------------------------------------------------

-- Tasks: { kind = "work"|"turnin", q, title, ... }. A work task is a quest's
-- objectives (one step); a turn-in task its hand-in, which waits for the work.
local function buildTasks(scope, zone)
	local zoneMap, zoneName, zoneText = zone.map, zone.name, zone.text
	local tasks, order = {}, 0
	for _, entry in ipairs(logQuests()) do
		local q = entry.id
		local rec = Q.GetQuest(q)
		local title = C.GetQuestTitle(q) or (rec and rec.title) or ("Quest " .. q)
		local ready = C.IsQuestReadyForTurnIn(q) and true or false
		local work = (not ready) and objectiveWork(q, rec, title, ready) or {}
		local ends = enders(rec)
		local wanted = scope == "all" or sameName(entry.header, zoneName) or sameName(entry.header, zoneText)
		if not wanted and zoneMap then
			if ready then
				for _, e in ipairs(ends) do
					if onMap(e.spawns, zoneMap) then wanted = true end
				end
			else
				for _, w in ipairs(work) do
					if not w.done and onMap(w.spawns, zoneMap) then wanted = true end
				end
			end
		end
		if wanted then
			order = order + 1
			local workTask
			if #work > 0 then
				workTask = { kind = "work", q = q, title = title, work = work, order = order, level = rec and rec.level }
				tasks[#tasks + 1] = workTask
			end
			tasks[#tasks + 1] = { kind = "turnin", q = q, title = title, ends = ends, after = workTask, order = order, ready = ready }
		end
	end
	return tasks
end

-- Where a task would take the player next, from point `from`: its nearest
-- open place and the cost to get there.
local function taskReach(t, from)
	local bestS, bestC = nil, huge
	if t.kind == "work" then
		for _, w in ipairs(t.work) do
			if not w.done and w.spawns then
				local s, c = nearest(w.spawns, from)
				if s and (c < bestC or not bestS) then bestS, bestC = s, c end
			end
		end
	else
		for _, e in ipairs(t.ends) do
			if e.spawns then
				local s, c = nearest(e.spawns, from)
				if s and (c < bestC or not bestS) then bestS, bestC, t.ender = s, c, e end
			end
		end
		if not t.ender then t.ender = t.ends[1] end
	end
	return bestS, bestC
end

-- Nearest first, a hand-in only after its quest's work; tasks with no place
-- go last, in log order.
local function route(tasks, from)
	local left, out, placed = {}, {}, {}
	for i, t in ipairs(tasks) do left[i] = t end
	local here = from
	while #left > 0 do
		local bi, bs, bc = nil, nil, huge
		for i, t in ipairs(left) do
			if not (t.after and not placed[t.after]) then
				local s, c = taskReach(t, here)
				if c == huge and not here then c = 1e9 + t.order end -- no player position: log order
				if not s then c = 2e9 + t.order end
				if not bi or c < bc or (c == bc and t.order < left[bi].order) then bi, bs, bc = i, s, c end
			end
		end
		if not bi then break end
		local t = table.remove(left, bi)
		placed[t] = true
		t.at = bs
		out[#out + 1] = t
		if bs then here = bs end
	end
	return out
end

-- A work task's goals: open ones nearest-first from where the walk enters
-- the step, each at its nearest spawn; done ones keep their place in the
-- step (Polestar ticks them from the log) at their nearest spawn too.
local function workGoals(t, from)
	local goals, open, closed, last = {}, {}, {}, {}
	for _, w in ipairs(t.work) do
		if w.last then last[#last + 1] = w
		elseif w.done then closed[#closed + 1] = w
		else open[#open + 1] = w end
	end
	local here = from
	while #open > 0 do
		local bi, bs, bc = 1, nil, huge
		for i, w in ipairs(open) do
			local s, c = nearest(w.spawns, here)
			if s and (c < bc or not bs) then bi, bs, bc = i, s, c end
		end
		local w = table.remove(open, bi)
		local s = bs or nearest(w.spawns, here)
		goals[#goals + 1] = place(w.goal, s, w.spawns)
		if s then here = s end
	end
	for _, w in ipairs(closed) do
		goals[#goals + 1] = place(w.goal, (nearest(w.spawns, here)), w.spawns)
	end
	for _, w in ipairs(last) do
		goals[#goals + 1] = place(w.goal, (nearest(w.spawns, here)), w.spawns)
	end
	return goals, here
end

local function turninGoal(t)
	local e = t.ender
	local g = { t = "turnin", quest = t.q, title = t.title }
	if e then
		if e.npc then g.npc, g.npcName = e.npc, e.name else g.object, g.objName = e.object, e.name end
		if t.at then place(g, t.at) end
	end
	return g
end

local function emptyStep(zoneName, scope)
	local text
	if scope == "all" then
		text = "Your quest log is empty. Pick up some quests and they show up here."
	else
		text = format("No quests for %s in your log. Pick some up, or choose another zone: the window's menu, Questing zone.", zoneName or "this zone")
	end
	return { title = TITLE, goals = { { t = "task", text = text } } }
end

-- The guide's steps for the log as it is now -> steps, title, zone map, zone name.
function FQ.Plan(scope)
	local db = charDB()
	scope = scope or db.scope
	local now = {}
	if scope == "pin" and type(db.pin) == "table" and db.pin.name then
		now.map, now.name, now.text = db.pin.map, db.pin.name, db.pin.name
	else
		now.map, now.name, now.text = zoneHere()
	end
	local zone = now
	local tasks = buildTasks(scope, now)
	if scope == "zone" then
		-- A zone with none of your quests (passing through on the way to a
		-- hand-in): the last zone that had some stays the guide's.
		local last = db.lastZone
		if #tasks == 0 and type(last) == "table" and last.map and last.map ~= now.map then
			local kept = buildTasks(scope, last)
			if #kept > 0 then tasks, zone = kept, last end
		elseif #tasks > 0 then
			db.lastZone = { map = now.map, name = now.name, text = now.text }
		end
	end
	local zoneMap, zoneName = zone.map, zone.name or zone.text
	local from = P.PlayerPoint and P.PlayerPoint() or nil
	local steps = {}
	local here = from
	for _, t in ipairs(route(tasks, from)) do
		if t.kind == "work" then
			local goals
			goals, here = workGoals(t, here)
			local step = { title = t.title, goals = goals }
			if not t.at then step.note = "Polestar's quest database has no place for this quest's work: read its log entry." end
			steps[#steps + 1] = step
		else
			local g = turninGoal(t)
			local prev = steps[#steps]
			-- Hand-ins to the same NPC in a row: one stop.
			if prev and prev.turnins and g.npc and prev.turnins == g.npc then
				prev.goals[#prev.goals + 1] = g
			else
				local step = { title = (g.npcName or g.objName) and ("Hand in: " .. (g.npcName or g.objName)) or t.title, goals = { g }, turnins = g.npc }
				if not g.map then step.note = "Polestar's quest database does not know who takes this quest: read its log entry." end
				steps[#steps + 1] = step
			end
			if t.at then here = t.at end
		end
	end
	for _, s in ipairs(steps) do s.turnins = nil end
	if #steps == 0 then steps[1] = emptyStep(zoneName, scope) end
	local title = scope == "all" and (TITLE .. ": all quests") or (TITLE .. (zoneName and (": " .. zoneName) or ""))
	return steps, title, zoneMap, zoneName
end

---------------------------------------------------------------------------
-- The guide
---------------------------------------------------------------------------

local registeredTitle
local function register(steps, title, zoneMap, zoneName)
	local def = {
		id = GUIDE_ID, pack = PACK, title = title, category = CATEGORY,
		author = "Polestar_Freestyle", version = 1,
		why = "The quests already in your log: where to kill, collect and hand in, nearest first.",
		pitch = "Your own quests, Polestar's arrow.",
		keywords = { "free", "questing", "quest log", "my quests" },
		zone = zoneMap, zoneName = zoneName,
		steps = steps,
	}
	local ok, err = P.RegisterGuide(def)
	if ok then registeredTitle = title end
	return ok, err
end

-- Polestar's pack and a first guide, while the files load: a saved tab of it
-- comes back at login, and the guide menu lists it. Its one step waits for
-- the quest log (the plan replaces it as soon as it can be read).
local function packFormat()
	local F = P.Guides and P.Guides.FORMATS
	if type(F) ~= "table" then return 4 end
	for f = 10, 1, -1 do
		if F[f] then return f end
	end
	return 4
end

P.RegisterPack({
	addon = ADDON, id = PACK, format = packFormat(), title = "Freestyle questing", author = "Polestar_Freestyle",
	version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "0.1.0",
	license = "GPL-3.0-only",
	notes = "Polestar's guide window for the quests already in your log. /polestar free",
})
register({ { title = TITLE, goals = { { t = "task", text = "Reading your quest log..." } } } }, TITLE)

local function tabIndex()
	local ok, tabs = pcall(E.GetTabs)
	if not (ok and type(tabs) == "table") then return nil end
	for i, t in ipairs(tabs) do
		if t.guideId == GUIDE_ID then return i end
	end
	return nil
end

-- The quest log's shape the plan depends on: which quests, which are ready,
-- which objectives are done, and the zone in scope.
local function signature(scope)
	local parts = { scope }
	if scope == "zone" then parts[#parts + 1] = tostring((zoneHere())) end
	if scope == "pin" then parts[#parts + 1] = tostring(charDB().pin.name) end
	for _, entry in ipairs(logQuests()) do
		local q = entry.id
		local s = q .. (C.IsQuestReadyForTurnIn(q) and "r" or "")
		local lines = C.GetQuestObjectives(q)
		if lines then
			for _, l in ipairs(lines) do s = s .. (l.finished and "1" or "0") end
		end
		parts[#parts + 1] = s
	end
	return concat(parts, ",")
end

local lastSig
local function dbReady()
	if Q.IsLoaded() then return true end
	local ok, reason = Q.Load()
	return ok and true or false, reason
end

-- For the Quests section's log list: each quest in your log, how far its next
-- place is from where you stand (travel seconds, straight line) and whether it
-- is ready to hand in. nil while the quest database can't load (combat).
-- -> { [questID] = { cost = seconds, ready = bool } }
function FQ.LogReach()
	if not Q.IsLoaded() then
		if InCombatLockdown and InCombatLockdown() then return nil end
		if not dbReady() then return nil end
	end
	local from = P.PlayerPoint and P.PlayerPoint()
	if not from then return nil end
	local out = {}
	local ok = pcall(function()
		for _, t in ipairs(buildTasks("all", {})) do
			if t.kind == "work" or (t.kind == "turnin" and t.ready) then
				local _, c = taskReach(t, from)
				local cur = out[t.q]
				if not cur or c < cur.cost then out[t.q] = { cost = c, ready = t.kind == "turnin" } end
			end
		end
	end)
	return ok and out or nil
end

-- Plans again and gives the guide its new steps: in its tab (ReplaceSteps
-- keeps your place, ticks and skips), else as a fresh registration.
-- force: even when the log's shape is the same.
function FQ.Refresh(force)
	local ready, reason = dbReady()
	if not ready then return false, reason end
	local scope = charDB().scope
	local sig = signature(scope)
	if not force and sig == lastSig then return true end
	local steps, title, zoneMap, zoneName = FQ.Plan(scope)
	if not tabIndex() then
		local ok, err = register(steps, title, zoneMap, zoneName)
		if ok then lastSig = sig end
		return ok, err
	end
	if not (API and API.ReplaceSteps) then
		-- Polestar 0.3.x: the guide registered again in its place; its tab
		-- takes it where it stands (Engine's PACKS_CHANGED, as an import
		-- updated on the Import page), ticks and skips carried by its steps.
		local ok, err = register(steps, title, zoneMap, zoneName)
		if not ok then return ok, err end
		lastSig = sig
		if P.Fire then P.Fire("PACKS_CHANGED", PACK) end
		return true
	end
	if title ~= registeredTitle then
		-- A new zone: the tab's title follows (the registration carries it,
		-- ReplaceSteps the steps), so plan twice: Polestar keeps the tables.
		register(FQ.Plan(scope), title, zoneMap, zoneName)
	end
	local ok, err = API.ReplaceSteps(GUIDE_ID, steps)
	if ok then lastSig = sig end
	return ok, err
end

local pending, pendingForce = false, false
local function later(delay, force)
	if force then pendingForce = true end
	if pending then return end
	pending = true
	C_Timer.After(delay or REPLAN_DELAY, function()
		pending = false
		local f = pendingForce
		pendingForce = false
		if not tabIndex() then return end
		local ok, err = FQ.Refresh(f)
		if ok == false and err == "busy" then later(0.2, f) end
	end)
end
FQ.Later = later

-- Opens free questing in a tab of its own (the leveling guide's tab stays),
-- or selects it when it is open.
function FQ.Open()
	local ready, reason = dbReady()
	if not ready then
		if reason == "combat" then
			say("Freestyle questing: the quest database loads after combat. Try again in a moment.")
		else
			say("Freestyle questing needs Polestar's quest database: turn on Options > Questing > the quest database (any quest marker or quest tooltip loads it).")
		end
		return false
	end
	local i = tabIndex()
	if i then
		if E.SelectTab then E.SelectTab(i) end
		FQ.Refresh(true)
	else
		local ok, err = FQ.Refresh(true)
		if not ok then
			say("Freestyle questing: could not build the guide (" .. tostring(err) .. ").")
			return false
		end
		local opened = E.OpenTab and E.OpenTab(GUIDE_ID, true)
		if not opened then
			if E.OpenTab then
				say("Freestyle questing: six guide tabs is the limit. Close one, then try again.")
				return false
			end
			E.SetGuide(GUIDE_ID)
		end
	end
	if P.Fire then P.Fire("SHOW_FRAME") end
	return true
end

function FQ.Close()
	local i = tabIndex()
	if i and E.CloseTab then E.CloseTab(i) end
end

---------------------------------------------------------------------------
-- Zones: which one free questing takes
---------------------------------------------------------------------------

-- Every map the client knows by its name (zones first, then cities and
-- dungeons): lower-case name -> { id, name }. Built once.
local mapIndex
local function maps()
	if mapIndex then return mapIndex end
	mapIndex = {}
	if not (C_Map and C_Map.GetMapChildrenInfo) then return mapIndex end
	for _, root in ipairs({ 947, 1414, 1415 }) do
		local ok, kids = pcall(C_Map.GetMapChildrenInfo, root, nil, true)
		if ok and type(kids) == "table" then
			for _, m in ipairs(kids) do
				if type(m.name) == "string" and m.name ~= "" and m.mapID then
					local k = lower(m.name)
					local cur = mapIndex[k]
					if not cur or (m.mapType == 3 and cur.t ~= 3) then mapIndex[k] = { id = m.mapID, name = m.name, t = m.mapType } end
				end
			end
		end
	end
	return mapIndex
end

local function mapByName(name)
	local m = type(name) == "string" and maps()[lower(name)]
	return m and m.id or nil
end

-- The zones of your quest log (its headers), A to Z:
-- { { name, count, map }, ... }.
function FQ.Zones()
	local counts, order = {}, {}
	for _, e in ipairs(logQuests()) do
		local h = e.header
		if type(h) == "string" and h ~= "" then
			if not counts[h] then
				counts[h] = 0
				order[#order + 1] = h
			end
			counts[h] = counts[h] + 1
		end
	end
	local out = {}
	for _, h in ipairs(order) do out[#out + 1] = { name = h, count = counts[h], map = mapByName(h) } end
	table.sort(out, function(a, b) return lower(a.name) < lower(b.name) end)
	return out
end

-- A zone by what the player typed: a zone of the log (whole name, then its
-- start, then a part of it), else any map of that name -> { name, map } or nil.
function FQ.FindZone(text)
	local t = lower(text or "")
	if t == "" then return nil end
	local list = FQ.Zones()
	local _, hereName = zoneHere()
	if hereName then list[#list + 1] = { name = hereName, map = (zoneHere()) } end
	for _, test in ipairs({
		function(n) return n == t end,
		function(n) return n:sub(1, #t) == t end,
		function(n) return find(n, t, 1, true) ~= nil end,
	}) do
		for _, z in ipairs(list) do
			if test(lower(z.name)) then return { name = z.name, map = z.map or mapByName(z.name) } end
		end
	end
	local m = maps()[t]
	if m then return { name = m.name, map = m.id } end
	local best
	for k, v in pairs(maps()) do
		if k:sub(1, #t) == t and (not best or #v.name < #best.name) then best = v end
	end
	return best and { name = best.name, map = best.id } or nil
end

-- What the guide takes now, as the menu reads it.
function FQ.ScopeLabel()
	local db = charDB()
	if db.scope == "all" then return "All quests" end
	if db.scope == "pin" then return db.pin.name end
	local _, here = zoneHere()
	return here and ("Follow (" .. here .. ")") or "Follow my zone"
end

-- scope: "zone" (follow), "all" or "pin" with zone { name, map }. Opens the
-- guide's tab if it is not open, and plans for it.
function FQ.SetScope(scope, zone)
	local db = charDB()
	db.scope = scope
	if scope == "pin" then db.pin = { name = zone.name, map = zone.map } end
	lastSig = nil
	return FQ.Open()
end

local menuAnchor -- the button whose menu opened last (the guide window's "...")

-- The Questing zone menu: follow, all, then each zone of the log with its
-- quest count; the current choice ticked.
function FQ.ShowZoneMenu(anchor)
	local W = P.Widgets
	anchor = anchor or menuAnchor
	if not (W and W.ShowMenu and anchor) then return end
	local db = charDB()
	local _, here = zoneHere()
	local items = {}
	local back = anchor.GetScript and anchor:GetScript("OnClick")
	if back then
		items[#items + 1] = { text = "Back", icon = "chevron-left", onClick = function() back(anchor, "LeftButton") end }
		items[#items + 1] = { separator = true }
	end
	items[#items + 1] = { text = "Follow my zone" .. (here and (" (" .. here .. ")") or ""), icon = "icon-goto",
		checked = db.scope == "zone", tip = "The quests of the zone you are in, changing as you travel.",
		onClick = function() FQ.SetScope("zone") end }
	items[#items + 1] = { text = format("All quests (%d)", #logQuests()), icon = "guides", checked = db.scope == "all",
		onClick = function() FQ.SetScope("all") end }
	local list = FQ.Zones()
	if #list > 0 then items[#items + 1] = { separator = true } end
	for _, z in ipairs(list) do
		items[#items + 1] = { text = format("%s (%d)", z.name, z.count), icon = ICON,
			checked = db.scope == "pin" and db.pin.name == z.name,
			onClick = function() FQ.SetScope("pin", z) end }
	end
	W.ShowMenu(anchor, items, { current = true, minWidth = 220 })
end

-- Polestar's windows, reached where they make their lists (each wrapped
-- only when it is there, so a Polestar without one just goes without):
do
	local W = P.Widgets
	local GF = P.UI and P.UI.GuideFrame
	-- Which button a menu opened from: the Questing zone page opens there.
	if W and type(W.ShowMenu) == "function" then
		local show = W.ShowMenu
		W.ShowMenu = function(anchor, ...)
			menuAnchor = anchor
			return show(anchor, ...)
		end
	end
	-- The guide window's menu, while free questing is the open guide:
	-- "Questing zone: <zone> ›" above the pins.
	if GF and type(GF.PinItems) == "function" then
		local pins = GF.PinItems
		GF.PinItems = function(...)
			local items = pins(...)
			local ok, g = pcall(E.GetGuide)
			if ok and type(g) == "table" and g.id == GUIDE_ID and type(items) == "table" then
				table.insert(items, 1, { text = "Questing zone: " .. FQ.ScopeLabel() .. NEXT, icon = ICON,
					onClick = function() FQ.ShowZoneMenu(menuAnchor) end })
			end
			return items
		end
	end
	-- The guide menu's Community guides entry: this icon, not the stack.
	if W and type(W.ShellNav) == "function" then
		local nav = W.ShellNav
		W.ShellNav = function(f, items, ...)
			if type(items) == "table" then
				for _, it in ipairs(items) do
					if it.key == "pack:" .. PACK then it.icon = ICON end
				end
			end
			return nav(f, items, ...)
		end
	end
	-- Its tab, tab list and card: the category's icon.
	if GF and type(GF.CATEGORY_ICON) == "table" then GF.CATEGORY_ICON[CATEGORY] = ICON end
	local Picker = P.UI and P.UI.Picker
	if Picker and type(Picker.CATEGORY_ICON) == "table" then Picker.CATEGORY_ICON[CATEGORY] = ICON end
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function command(rest)
	local text = (rest or ""):match("^%s*(.-)%s*$") or ""
	local arg = lower(text)
	if arg == "all" then
		FQ.SetScope("all")
		say("Freestyle questing: every quest in your log.")
	elseif arg == "zone" or arg == "here" or arg == "follow" then
		FQ.SetScope("zone")
		say("Freestyle questing: the quests of the zone you are in.")
	elseif arg == "" then
		FQ.Open()
	elseif arg == "close" or arg == "off" or arg == "stop" then
		FQ.Close()
	elseif arg == "refresh" then
		FQ.Refresh(true)
	elseif arg == "options" or arg == "settings" or arg == "config" then
		if not (FQ.Browser and FQ.Browser.ShowOptions and FQ.Browser.ShowOptions()) then
			say("Polestar Freestyle's options are in Polestar's Options (Polestar_Options must be enabled).")
		end
	elseif arg == "browse" or arg == "browser" or arg == "quests" then
		if FQ.Browse then
			FQ.Browse()
		else
			say("The quest browser needs a Polestar with hub sections (0.4.0 or newer).")
		end
	elseif arg == "gear" then
		if FQ.ShowGear then
			FQ.ShowGear()
		else
			say("The gear planner needs a Polestar with hub sections and gear advice (0.4.0 or newer).")
		end
	elseif arg == "help" or arg == "?" then
		say("/polestar free [zone|all|<zone name>|close|refresh]: the quests in your log as a guide.")
		say("/freequest browse (or /polestar quests): every quest by zone, its chain, XP and rewards; pick some and start a guide.")
		say("/freequest gear: your gear by slot and the upgrades quests, dungeons and rares give; mark some and start a guide.")
	else
		local z = FQ.FindZone(text)
		if z then
			FQ.SetScope("pin", z)
			say("Freestyle questing: the quests of " .. z.name .. ".")
		else
			local names = {}
			for _, zz in ipairs(FQ.Zones()) do names[#names + 1] = zz.name end
			say(format("Freestyle questing: no zone called \"%s\".%s", text,
				#names > 0 and (" Zones in your log: " .. concat(names, ", ") .. ".") or ""))
		end
	end
end
FQ.Command = command

if P.RegisterCommand then
	P.RegisterCommand("free", command, "Freestyle questing: your quest log as a guide (free [zone|all|<zone name>|close])")
	P.RegisterCommand("quests", function() command("browse") end, "Quest browser: every quest by zone, with chains, XP and rewards")
end
SLASH_POLESTARFREEQUEST1 = "/freequest"
SLASH_POLESTARFREEQUEST2 = "/freestyle"
SlashCmdList.POLESTARFREEQUEST = command

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
local loggedIn = false
for _, ev in ipairs({ "PLAYER_LOGIN", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN",
	"ZONE_CHANGED_NEW_AREA", "PLAYER_CONTROL_GAINED", "PLAYER_REGEN_ENABLED" }) do
	events:RegisterEvent(ev)
end
events:SetScript("OnEvent", function(_, ev)
	if ev == "PLAYER_LOGIN" then
		loggedIn = true
		return
	end
	if not loggedIn then return end
	if ev == "ZONE_CHANGED_NEW_AREA" and C.IsOnTaxi and C.IsOnTaxi() then return end -- wait for the landing
	later()
end)

-- Opened from the guide menu, or a tab of it restored at login: plan now.
-- Not forced: ReplaceSteps fires GUIDE_CHANGED itself, and an unchanged log
-- must not plan again.
P.On("GUIDE_CHANGED", function(id)
	if id == GUIDE_ID then later(0) end
end)
