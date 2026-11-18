-- Polestar Freestyle: the Quests section of Polestar's hub.
--
-- Every quest this character can take, by zone ("Westfall (10-20)"), each
-- zone a tree of quest chains and single quests: level, state (done, in your
-- log, open, locked), the XP it gives you now and its reward items.
--
--   * Sidebar: In your quest log, Available (your zone first; as far above
--     your level as Polestar's own "Quests above your level" setting, whose
--     slider is on the page too), Marked, All quests.
--   * Column headers sort the list (Lvl, Quest, XP; again to turn it round).
--   * The search (the magnifier, or Ctrl+F) finds a quest by its title or a
--     reward's name.
--   * Tick quests or whole chains, then Start guide: one guide through every
--     picked chain, from the first quest you have not done (Planner.lua). With
--     nothing ticked it takes the marked quests (the star; also on Lookup's
--     item pages, LookupMarks.lua).
--
-- Registered with Polestar.UI.RegisterSection, as Polestar's own Lookup and
-- Dungeons sections are. /freequest browse or /polestar quests opens it.
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
local FQB = FQ and FQ.Browser
local UI, W, Theme = P and P.UI, P and P.Widgets, P and P.Theme
if not (FQB and UI and W and Theme) then return end

local C = P.Compat
local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local format, lower, concat = string.format, string.lower, table.concat

local SH = W.SHELL or { pad = 32 }
local KEY = "Quests"
local ROW_H = 26
local INDENT = 18
local TOOL_H = 40
local STRIP_H = 36
local HEAD_H = 32
local DETAIL_H = 224
local ITEMS = 4      -- reward icons on a row
local DETAIL_ITEMS = 8
local DOT = "  \194\183  "
-- Before a chain's other zones: Polestar's chevron (the game's font has no arrow).
local ARROW = " |TInterface\\AddOns\\Polestar\\Media\\UI\\chevron-right:10:10|t "
-- Where a row's right-hand columns end, from its right edge: the star, the
-- reward icons, then the XP (the header's columns line up with them).
local STAR_W, ITEM_W, ITEM_GAP = 20, 18, 3
local ITEMS_RIGHT = 2 + STAR_W + 6
local XP_RIGHT = ITEMS_RIGHT + ITEMS * ITEM_W + (ITEMS - 1) * ITEM_GAP + 8
local XP_W = 78
local SIZE_W = 44 -- the length meter (or, in your log, the way there), left of the XP

local WINDOW_KEY, LOW_KEY = "qol.questLevelWindow", "qol.lowLevelQuests"

local FILTERS = {
	{ key = "log", label = "In your quest log", icon = "icon-note" },
	{ key = "available", label = "Available", icon = "icon-accept" },
	{ key = "marked", label = "Marked", icon = "star" },
	{ key = "all", label = "All quests", icon = "guides" },
}
local STATUS = {
	done = { glyph = "check", color = "success", text = "Done" },
	log = { glyph = "icon-accept", color = "accent", text = "In your quest log" },
	available = { glyph = "circle", color = "quest", text = "Open to you" },
	level = { glyph = "lock", color = "warning", text = "Needs a higher level" },
	pre = { glyph = "lock", color = "textMuted", text = "Needs an earlier quest first" },
}

local QS = {}
FQB.Section = QS

local root, hub, tool, strip, header, scroll, details, message
local rows = {}
local flat = {}
local query = ""
local searchOpen = {} -- while searching: what the player opened or closed
local focus -- the quest the details strip shows
local focusItem -- a reward to light up (Gear's "Show in Quests")

local function db()
	local d = FQ.CharDB()
	local b = d.browser
	if b.filter ~= "available" and b.filter ~= "all" and b.filter ~= "marked" and b.filter ~= "log" then
		b.filter = "available"
	end
	local s = b.sort
	if s.key ~= "level" and s.key ~= "xp" and s.key ~= "name" and s.key ~= "rewards" then s.key = "level" end
	-- In your quest log has its own order, nearest first unless a column is picked.
	if type(b.sortLog) ~= "table" then b.sortLog = { key = "near", desc = false } end
	local sl = b.sortLog
	if sl.key ~= "near" and sl.key ~= "level" and sl.key ~= "xp" and sl.key ~= "name" and sl.key ~= "rewards" then sl.key = "near" end
	if type(b.open[b.filter]) ~= "table" then b.open[b.filter] = {} end
	return d, b
end

-- The sort the shown list uses.
local function sortOf(b)
	return b.filter == "log" and b.sortLog or b.sort
end

-- In your quest log: how far each quest's next place is (FQ.LogReach), read
-- again when the list is rebuilt, at most every few seconds.
local reach, reachAt = {}, 0
local REACH_EVERY = 3
-- (How far "Near you" reaches: Freestyle's options, Settings.lua.)
local function refreshReach(force)
	local now = GetTime and GetTime() or 0
	if not force and now - reachAt < REACH_EVERY then return end
	reachAt = now
	reach = (FQ.LogReach and FQ.LogReach()) or {}
end

local function travelText(sec)
	if type(sec) ~= "number" or sec >= 1e8 then return "" end
	-- Yards (Freestyle's option): the straight line, as Polestar measures it.
	if FQB.Opt and FQB.Opt("nearUnit") == "yards" then
		local yd = sec * (FQB.RUN_SPEED or 7)
		if yd < 1000 then return format("%d yd", floor(yd / 10 + 0.5) * 10) end
		return format("%.1fk yd", yd / 1000)
	end
	local LK = UI.Lookup
	if LK and LK.Travel then
		local ok, s = pcall(LK.Travel, sec)
		if ok and s then return s end
	end
	if sec < 60 then return "< 1 min" end
	return format("%d min", floor(sec / 60 + 0.5))
end

local function thousands(n)
	if P.Thousands then return P.Thousands(n) end
	return tostring(n)
end

local function repaint()
	if not (root and root:IsVisible()) then return end
	local Pk = UI.Picker
	if Pk and Pk.Render then Pk.Render() else QS.Render() end
end

local function setMessage(text, color)
	if not details then return end
	details.Note:SetText(text or "")
	W.Color(details.Note, color or "warning")
end

---------------------------------------------------------------------------
-- What is shown
---------------------------------------------------------------------------

-- The highest level a quest gives nothing at (Forever's grey level).
local function greyLevel(l)
	local Q = P.QuestDB
	if Q and Q.GreyLevel then return Q.GreyLevel(l) end
	if l <= 5 then return 0 end
	if l <= 39 then return l - floor(l / 10) - 5 end
	if l <= 59 then return l - floor(l / 5) - 1 end
	return l - 9
end

local function anyLevel()
	local Q = P.QuestDB
	return (Q and Q.LEVEL_WINDOW_ANY) or 10
end

-- Polestar's own "Quests above your level" (Options > Map > Quest markers),
-- and its "Low-level quests": the same rules its map markers follow.
local function levelWindow()
	local w = P.Get and tonumber(P.Get(WINDOW_KEY))
	return w or 5
end

local function levelOK(r, plevel)
	local lvl = r and r.level or 0
	local w = levelWindow()
	if w < anyLevel() and lvl > plevel + w then return false end
	if not (P.Get and P.Get(LOW_KEY)) and lvl > 0 and lvl <= greyLevel(plevel) then return false end
	return true
end

local function levelColor(qlevel, plevel)
	if not qlevel or qlevel == 0 then return "textDim" end
	local d = qlevel - plevel
	if d >= 5 then return "danger" end
	if d >= 3 then return "warning" end
	if qlevel <= greyLevel(plevel) then return "textMuted" end
	if d <= -3 then return "success" end
	return "quest"
end

FQB.LevelColor = levelColor
FQB.STATUS = STATUS

local function passes(id, filter, plevel, marked)
	if filter == "all" then return true end
	if filter == "marked" then return marked[id] and true or false end
	local st = FQB.Status(id)
	if filter == "log" then return st == "log" end
	if filter == "available" then
		if st == "log" then return true end
		return st == "available" and levelOK(FQB.Quest(id), plevel)
	end
	return true
end

-- The search looks through every quest, whatever the filter (but Marked and
-- In your log stay what they say).
local function shown(id, filter, plevel, marked)
	if query ~= "" then
		if not FQB.Matches(id, query) then return false end
		if filter == "available" then return true end
	end
	return passes(id, filter, plevel, marked)
end

local function nodeIds(node)
	if type(node) == "table" then return node.quests end
	return { node }
end

local function nodeTitle(node)
	if type(node) == "table" then return node.title end
	local r = FQB.Quest(node)
	return r and r.title or ""
end

-- A node's value for the sort column, over its shown quests.
local function value(ids, key, plevel, title)
	if key == "name" then return lower(title or "") end
	if key == "near" then
		local lo = 1e9
		for _, id in ipairs(ids) do
			local r = reach[id]
			if r and r.cost < lo then lo = r.cost end
		end
		return lo
	end
	if key == "rewards" then
		-- How many items it hands out (rewards and choices), quests not done yet.
		local n = 0
		for _, id in ipairs(ids) do
			local r = FQB.Status(id) ~= "done" and FQB.Quest(id)
			if r then n = n + #(r.rewards or {}) + #(r.choices or {}) end
		end
		return n
	end
	if key == "xp" then
		local sum = 0
		for _, id in ipairs(ids) do
			if FQB.Status(id) ~= "done" then sum = sum + (FQB.XP(id, plevel) or 0) end
		end
		return sum
	end
	local lo = 999
	for _, id in ipairs(ids) do
		local r = FQB.Quest(id)
		if r and r.level and r.level > 0 then lo = min(lo, r.level) end
	end
	return lo
end

local function before(sort)
	return function(a, b)
		if a.here ~= b.here then return a.here and true or false end
		if a.v ~= b.v then
			if sort.desc then return a.v > b.v end
			return a.v < b.v
		end
		return a.title < b.title
	end
end

local function hereZone()
	return C.GetUnitZone and C.GetUnitZone("player") or nil
end

-- Open or closed: what the player chose in this filter, else its default
-- (In your quest log and Marked start open; Available opens your zone).
-- While searching, everything matching starts open.
local function isOpen(key, here)
	local _, b = db()
	if query ~= "" then
		local v = searchOpen[key]
		if v == nil then return true end
		return v
	end
	local v = b.open[b.filter][key]
	if v ~= nil then return v end
	if b.filter == "log" or b.filter == "marked" then return true end
	if b.filter == "available" and here then return true end
	return false
end

local function setOpen(key, on)
	local _, b = db()
	if query ~= "" then
		searchOpen[key] = on
	else
		b.open[b.filter][key] = on
	end
end

-- "Near you" (In your quest log): what is within NEAR of where you stand,
-- quests to hand in first, then your quests' next places, then quests to pick
-- up from givers close by in this zone. Worked out with the reach (every
-- REACH_EVERY seconds at most).

local nearList, nearAt = {}, -1
local function nearYou(plevel)
	if nearAt == reachAt then return nearList end
	nearAt = reachAt
	local list = {}
	-- Freestyle's options (Settings.lua): how far, how many, what kinds.
	local NEAR = (tonumber(FQB.Opt and FQB.Opt("nearMinutes")) or 2.5) * 60
	local NEAR_MAX = tonumber(FQB.Opt and FQB.Opt("nearMax")) or 10
	local turnins = not FQB.Opt or FQB.Opt("nearTurnins") ~= false
	local pickups = not FQB.Opt or FQB.Opt("nearPickups") ~= false
	for id, r in pairs(reach) do
		if r.cost <= NEAR and (turnins or not r.ready) then
			list[#list + 1] = { id = id, cost = r.cost, near = r.ready and "turnin" or "work" }
		end
	end
	local Lk, Cx = P.Lookup, P.Codex
	local from = P.PlayerPoint and P.PlayerPoint()
	local zid = hereZone()
	if pickups and from and zid and Lk and Lk.QuestEnd and Cx and Cx.Quest and P.DirectTravelCost then
		local player = Lk.PlayerInfo and Lk.PlayerInfo()
		for _, z in ipairs(FQB.Zones()) do
			if z.id == zid then
				for _, node in ipairs(z.nodes) do
					for _, id in ipairs(nodeIds(node)) do
						if FQB.Status(id) == "available" and shown(id, "available", plevel, {}) then
							local cq = Cx.Quest(id)
							local ok, giver = pcall(Lk.QuestEnd, cq and cq.start, from, player, true)
							local spawn = ok and type(giver) == "table" and giver.spawn
							local c = spawn and P.DirectTravelCost(from, spawn)
							if c and c <= NEAR then list[#list + 1] = { id = id, cost = c, near = "pickup" } end
						end
					end
				end
			end
		end
	end
	local rank = { turnin = 1, work = 2, pickup = 3 }
	table.sort(list, function(a, b)
		if a.near ~= b.near then return rank[a.near] < rank[b.near] end
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.id < b.id
	end)
	for i = #list, NEAR_MAX + 1, -1 do list[i] = nil end
	nearList = list
	return list
end

-- Near you in the picked column's order: "near" keeps hand-ins first, then
-- the nearest; any other column sorts like the rest of the list.
local function nearSorted(near, sort, plevel)
	local out = {}
	for i, n in ipairs(near) do out[i] = n end
	if sort.key == "near" then
		if sort.desc then
			for i = 1, floor(#out / 2) do out[i], out[#out + 1 - i] = out[#out + 1 - i], out[i] end
		end
		return out
	end
	for _, n in ipairs(out) do
		local r = FQB.Quest(n.id)
		n.title = lower(r and r.title or "")
		n.v = value({ n.id }, sort.key, plevel, r and r.title)
	end
	table.sort(out, before(sort))
	return out
end

local NEAR_ZONE = { id = "near", name = "Near you" }

-- The rows: zones, then their chains and quests, then a chain's quests.
local function buildFlat()
	local d, b = db()
	local plevel = FQB.PlayerLevel()
	local sort, filter = sortOf(b), b.filter
	if filter == "log" then refreshReach() end
	local marked = d.marked
	local here = filter == "available" and hereZone() or nil
	local out = {}
	local zoneList = {}
	for _, z in ipairs(FQB.Zones()) do
		local nodes, all = {}, {}
		for _, node in ipairs(z.nodes) do
			local ids, hit = nodeIds(node), {}
			for _, id in ipairs(ids) do
				if shown(id, filter, plevel, marked) then hit[#hit + 1] = id end
			end
			if #hit > 0 then
				local title = nodeTitle(node)
				nodes[#nodes + 1] = { node = node, hit = hit, title = lower(title), v = value(hit, sort.key, plevel, title) }
				for _, id in ipairs(hit) do all[#all + 1] = id end
			end
		end
		if #nodes > 0 then
			local v
			if sort.key == "level" then v = z.min or value(all, "level", plevel) else v = value(all, sort.key, plevel, z.name) end
			zoneList[#zoneList + 1] = { zone = z, nodes = nodes, count = #all, title = lower(z.name), v = v,
				here = (here ~= nil and z.id == here) or nil }
		end
	end
	table.sort(zoneList, before(sort))
	local total = 0
	if filter == "log" and query == "" then
		local near = nearYou(plevel)
		if #near > 0 then
			local nopen = isOpen("znear", true)
			local ids = {}
			for _, n in ipairs(near) do ids[#ids + 1] = n.id end
			out[#out + 1] = { kind = "zone", zone = NEAR_ZONE, count = #near, depth = 0, key = "znear", open = nopen, here = true, ids = ids }
			if nopen then
				for _, n in ipairs(nearSorted(near, sort, plevel)) do
					out[#out + 1] = { kind = "quest", id = n.id, depth = 1, near = n.near, cost = n.cost }
				end
			end
		end
	end
	for _, ze in ipairs(zoneList) do
		total = total + ze.count
		local zkey = "z" .. ze.zone.id
		local zopen = isOpen(zkey, ze.here)
		-- Ticking a zone ticks what it shows: each chain (to its last quest,
		-- as a chain's own tick does) and each single quest.
		local ids = {}
		for _, ne in ipairs(ze.nodes) do
			ids[#ids + 1] = type(ne.node) == "table" and ne.node.last or ne.node
		end
		out[#out + 1] = { kind = "zone", zone = ze.zone, count = ze.count, depth = 0, key = zkey, open = zopen, here = ze.here, ids = ids }
		if zopen then
			table.sort(ze.nodes, before(sort))
			for _, ne in ipairs(ze.nodes) do
				local node = ne.node
				if type(node) == "table" then
					local ckey = "c" .. node.id
					local copen = isOpen(ckey, false)
					local hitSet = {}
					for _, id in ipairs(ne.hit) do hitSet[id] = true end
					out[#out + 1] = { kind = "chain", chain = node, depth = 1, key = ckey, open = copen, hits = #ne.hit }
					if copen then
						-- The quests still to do first; the done ones folded
						-- under "N done" at the end, opened on a click.
						local done = {}
						for _, id in ipairs(node.quests) do
							if FQB.Status(id) == "done" then
								done[#done + 1] = id
							else
								out[#out + 1] = { kind = "quest", id = id, depth = 2, dim = not hitSet[id] }
							end
						end
						if #done > 0 then
							local dkey = "d" .. node.id
							local dopen = isOpen(dkey, false)
							out[#out + 1] = { kind = "done", depth = 2, key = dkey, open = dopen, count = #done }
							if dopen then
								for _, id in ipairs(done) do
									out[#out + 1] = { kind = "quest", id = id, depth = 3, dim = not hitSet[id] }
								end
							end
						end
					end
				else
					out[#out + 1] = { kind = "quest", id = node, depth = 1 }
				end
			end
		end
	end
	return out, total
end

function QS.Counts()
	local d = db()
	local counts = {}
	if FQB.State() ~= "ready" then return counts end
	local plevel = FQB.PlayerLevel()
	for _, f in ipairs(FILTERS) do counts[f.key] = 0 end
	for _, z in ipairs(FQB.Zones()) do
		for _, node in ipairs(z.nodes) do
			for _, id in ipairs(nodeIds(node)) do
				for _, f in ipairs(FILTERS) do
					if passes(id, f.key, plevel, d.marked) then counts[f.key] = counts[f.key] + 1 end
				end
			end
		end
	end
	return counts
end

---------------------------------------------------------------------------
-- Picking and marking
---------------------------------------------------------------------------

local function selectedIds()
	local _, b = db()
	local out = {}
	for id, on in pairs(b.selected) do
		if on and FQB.Quest(id) then out[#out + 1] = id end
	end
	table.sort(out)
	return out
end

local function markedIds()
	local d = db()
	local out = {}
	for id, on in pairs(d.marked) do
		if on then out[#out + 1] = id end
	end
	table.sort(out)
	return out
end

function QS.ToggleMark(id)
	local d = db()
	d.marked[id] = (not d.marked[id]) and true or nil
	FQB.Changed()
end

function QS.Start(ids)
	ids = ids or selectedIds()
	if #ids == 0 then ids = markedIds() end
	if #ids == 0 then
		setMessage("Tick a quest or a chain (or mark one with the star), then Start guide.")
		return
	end
	local gid, msg = FQB.StartGuide(ids)
	if not gid then setMessage(msg) end
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

-- glow: a ring that lights when the icon is the reward the Gear page asked
-- about (QS.Reveal(ids, { item = id })).
local function itemButton(parent, size, glow)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size, size)
	if glow then
		b.Glow = W.Fill(b, "accent", "BACKGROUND")
		b.Glow:ClearAllPoints()
		b.Glow:SetPoint("TOPLEFT", b, "TOPLEFT", -2, 2)
		b.Glow:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
		b.Glow:Hide()
	end
	b.Icon = b:CreateTexture(nil, "ARTWORK")
	b.Icon:SetAllPoints(b)
	b.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	b:SetScript("OnEnter", function(self) if self.psItem then W.ItemTip(self, self.psItem) end end)
	b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
	b:SetScript("OnClick", function(self) if self.psItem then W.ItemClick(self.psItem) end end)
	return b
end
FQB.ItemButton = itemButton

local function setItem(b, itemID)
	b.psItem = itemID
	if b.Glow then b.Glow:SetShown(itemID ~= nil and itemID == focusItem) end
	if itemID then
		b.Icon:SetTexture(FQB.ItemIcon(itemID))
		b:Show()
	else
		b:Hide()
	end
end
FQB.SetItem = setItem

local function rowQuest(r)
	local e = r.psEntry
	if not e then return nil end
	if e.kind == "quest" then return e.id end
	if e.kind == "chain" then return e.chain.last end
	return nil
end

local function onCheck(self)
	local r = self:GetParent()
	local _, b = db()
	local e = r.psEntry
	-- A zone (or Near you): every quest and chain under it, on or off.
	if e and e.kind == "zone" and e.ids then
		local on = self:GetChecked() and true or nil
		for _, id in ipairs(e.ids) do b.selected[id] = on end
		QS.Paint()
		return
	end
	local id = rowQuest(r)
	if not id then return end
	b.selected[id] = self:GetChecked() and true or nil
	QS.Paint()
end

-- A zone's tick: on when everything under it is ticked.
local function allTicked(ids, selected)
	if not ids or #ids == 0 then return false end
	for _, id in ipairs(ids) do
		if not selected[id] then return false end
	end
	return true
end

local function onStar(self)
	local id = rowQuest(self:GetParent())
	if id then QS.ToggleMark(id) end
end

local function rowMenu(r)
	local id = rowQuest(r)
	if not (id and W.ShowMenu) then return end
	local d = db()
	W.ShowMenu(r, {
		{ text = d.marked[id] and "Unmark" or "Mark", icon = "star", onClick = function() QS.ToggleMark(id) end },
		{ text = "Guide this quest", icon = "icon-goto", onClick = function() QS.Start({ id }) end },
		{ text = "Show in Lookup", icon = "search", onClick = function() QS.ShowInLookup(id) end },
	}, { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = 40, y = 0 })
end

local function onRowClick(self, button)
	local e = self.psEntry
	if not e then return end
	if button == "RightButton" then
		rowMenu(self)
		return
	end
	if e.kind == "done" then
		setOpen(e.key, not e.open)
		QS.Refresh()
		return
	end
	if e.kind == "zone" or e.kind == "chain" then
		setOpen(e.key, not e.open)
		if e.kind == "chain" then focus = e.chain.last; focusItem = nil end
		QS.Refresh()
	else
		if focus ~= e.id then focusItem = nil end
		focus = e.id
		QS.Paint()
	end
end

local function row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, scroll.Child)
	r:SetHeight(ROW_H)
	r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	W.Hover(r)
	r.Sel = r:CreateTexture(nil, "BACKGROUND", nil, 1)
	r.Sel:SetTexture(Theme.Media("white"))
	r.Sel:SetAllPoints(r)
	W.Painter(r.Sel, function(t) t:SetVertexColor(Theme.Wash("selected")) end)
	r.Toggle = W.Tex(r, "ARTWORK", "chevron-right", "textDim")
	r.Toggle:SetSize(12, 12)
	r.Check = W.Checkbox(r, onCheck)
	r.Level = W.Text(r, "small", "textDim")
	r.Level:SetWidth(26)
	r.Level:SetJustifyH("RIGHT")
	r.Status = W.Tex(r, "ARTWORK", "circle", "quest")
	r.Status:SetSize(12, 12)
	r.Star = W.IconButton(r, "star", STAR_W, nil, onStar)
	r.Star:SetPoint("RIGHT", r, "RIGHT", -2, 0)
	r.Items = {}
	local prev = r.Star
	for k = 1, ITEMS do
		local b = itemButton(r, ITEM_W, true)
		b:SetPoint("RIGHT", prev, "LEFT", k == 1 and -6 or -ITEM_GAP, 0)
		r.Items[k] = b
		prev = b
	end
	r.XP = W.Text(r, "small", "textDim")
	r.XP:SetJustifyH("RIGHT")
	r.XP:SetWidth(XP_W)
	r.XP:SetPoint("RIGHT", r, "RIGHT", -XP_RIGHT, 0)
	-- How big the quest is: one to three rising bars, and a glyph when it
	-- needs a group (elite) or a dungeon.
	r.Size = CreateFrame("Frame", nil, r)
	r.Size:SetSize(SIZE_W, 14)
	r.Size:SetPoint("RIGHT", r, "RIGHT", -(XP_RIGHT + XP_W + 6), 0)
	r.Bars = {}
	for k = 1, 3 do
		local t = r.Size:CreateTexture(nil, "ARTWORK")
		t:SetTexture("Interface\\Buttons\\WHITE8X8")
		t:SetSize(4, 4 + k * 3)
		t:SetPoint("BOTTOMRIGHT", r.Size, "BOTTOMRIGHT", -(3 - k) * 6, 1)
		r.Bars[k] = t
	end
	r.Tag = W.Tex(r.Size, "ARTWORK", "icon-elite", "warning")
	r.Tag:SetSize(12, 12)
	r.Tag:SetPoint("RIGHT", r.Size, "RIGHT", -20, 0)
	-- In your quest log, the Length column holds the way there instead.
	r.Near = W.Text(r.Size, "small", "textDim")
	r.Near:SetJustifyH("RIGHT")
	r.Near:SetPoint("RIGHT", r.Size, "RIGHT", 0, 0)
	r.Name = W.Text(r, "body", "text")
	r.Name:SetJustifyH("LEFT")
	r:SetScript("OnClick", onRowClick)
	rows[i] = r
	return r
end

local function questTip(id, plevel)
	local q = FQB.Quest(id)
	if not q then return nil end
	local st = STATUS[FQB.Status(id)] or STATUS.available
	local lines = { format("Level %d%s", q.level or 0, q.minLevel and format(" (from %d)", q.minLevel) or ""), st.text }
	local xp = FQB.XP(id, plevel)
	if xp then lines[#lines + 1] = format("%s XP", thousands(xp)) end
	lines[#lines + 1] = "Click: details. Right-click: mark, guide, Lookup."
	return q.title, lines
end

-- In your quest log: the way to the quest's next place, in travel time.
local function paintNear(r, e, id)
	for k = 1, 3 do r.Bars[k]:Hide() end
	r.Tag:Hide()
	local c = e.cost or (reach[id] and reach[id].cost)
	local t = travelText(c)
	r.Near:SetText(t)
	r.Near:Show()
	r.Size:SetShown(t ~= "")
end

-- The size meter: lit bars up to the quest's size, the glyph for a group
-- (elite) or dungeon quest. Nothing when the size isn't known.
local function paintSize(r, id)
	r.Near:Hide()
	local size, tag = nil, nil
	if FQB.QuestSize then size, tag = FQB.QuestSize(id) end
	if not (size or tag) then r.Size:Hide() return end
	for k = 1, 3 do
		local bar = r.Bars[k]
		bar:SetShown(size ~= nil)
		if size and k <= size then W.Color(bar, "accent") else W.Color(bar, "textMuted", 0.35) end
	end
	r.Tag:SetShown(tag ~= nil)
	if tag then
		r.Tag:SetTexture(Theme.Media(tag == "dungeon" and "icon-dungeon" or "icon-elite"))
		W.Color(r.Tag, tag == "dungeon" and "accent" or "warning")
	end
	r.Size:Show()
end

local function paintRow(r, e, plevel, d, b)
	r.psEntry = e
	local x = 4 + e.depth * INDENT
	r.Toggle:ClearAllPoints()
	r.Toggle:SetPoint("LEFT", r, "LEFT", x, 0)
	r.Check:ClearAllPoints()
	r.Check:SetPoint("LEFT", r, "LEFT", x + 16, 0)
	r.Level:ClearAllPoints()
	r.Level:SetPoint("LEFT", r.Check, "RIGHT", 0, 0)
	r.Status:ClearAllPoints()
	r.Status:SetPoint("LEFT", r.Level, "RIGHT", 6, 0)
	r.Name:ClearAllPoints()
	r.Name:SetPoint("RIGHT", r.Size, "LEFT", -6, 0)
	r.Size:Hide()
	r.Sel:SetShown(false)
	r:SetAlpha(1)

	if e.kind == "zone" then
		local z = e.zone
		r.Toggle:Show()
		r.Toggle:SetTexture(Theme.Media(e.open and "chevron-down" or "chevron-right"))
		-- Tick the whole zone (or everything Near you) for one guide.
		r.Check:SetShown(e.ids ~= nil and #e.ids > 0)
		r.Check:SetChecked(allTicked(e.ids, b.selected))
		r.Level:Hide()
		local after = r.Check:IsShown() and r.Check or r.Toggle
		if e.here then
			-- You are here.
			r.Status:ClearAllPoints()
			r.Status:SetPoint("LEFT", after, "RIGHT", 6, 0)
			r.Status:SetTexture(Theme.Media("icon-goto"))
			W.Color(r.Status, "accent")
			r.Status:Show()
			r.Name:SetPoint("LEFT", r.Status, "RIGHT", 6, 0)
		else
			r.Status:Hide()
			r.Name:SetPoint("LEFT", after, "RIGHT", 6, 0)
		end
		local M = P.Maps
		local range = (z.min and z.max) and format(" (%s)", (M and M.FormatLevels) and M.FormatLevels(z.min, z.max) or (z.min .. "-" .. z.max)) or ""
		r.Name:SetText(z.name .. range)
		W.Color(r.Name, (z.min and z.max and M and M.LevelColor) and M.LevelColor(z.min, z.max, plevel) or "text")
		r.XP:SetText(format("%d quest%s", e.count, e.count == 1 and "" or "s"))
		for k = 1, ITEMS do setItem(r.Items[k], nil) end
		r.Star:Hide()
		r.psTip = e.here and (z.name .. ": you are here") or nil
		r.psTipLines = nil
		return
	end

	-- A chain's finished quests, folded under one row at its end.
	if e.kind == "done" then
		r.Toggle:Show()
		r.Toggle:SetTexture(Theme.Media(e.open and "chevron-down" or "chevron-right"))
		r.Check:Hide()
		r.Level:Hide()
		r.Status:ClearAllPoints()
		r.Status:SetPoint("LEFT", r.Toggle, "RIGHT", 6, 0)
		r.Status:SetTexture(Theme.Media("check"))
		W.Color(r.Status, "success")
		r.Status:Show()
		r.Name:SetPoint("LEFT", r.Status, "RIGHT", 6, 0)
		r.Name:SetText(format("%d done", e.count))
		W.Color(r.Name, "textDim")
		r.XP:SetText("")
		for k = 1, ITEMS do setItem(r.Items[k], nil) end
		r.Star:Hide()
		return
	end

	local id = rowQuest(r)
	local q = FQB.Quest(id)
	r.Check:Show()
	r.Check:SetChecked(b.selected[id] and true or false)
	r.Level:Show()
	r.Status:Show()
	r.Star:Show()
	W.SetIconState(r.Star, d.marked[id] and true or false)
	r.Name:SetPoint("LEFT", r.Status, "RIGHT", 6, 0)
	r.Sel:SetShown(focus == id)

	if e.kind == "chain" then
		local ch = e.chain
		r.Toggle:Show()
		r.Toggle:SetTexture(Theme.Media(e.open and "chevron-down" or "chevron-right"))
		local doneN, xp = 0, 0
		for _, qid in ipairs(ch.quests) do
			if FQB.Status(qid) == "done" then doneN = doneN + 1 else xp = xp + (FQB.XP(qid, plevel) or 0) end
		end
		r.Level:SetText(tostring(ch.minLevel or ""))
		W.Color(r.Level, levelColor(ch.minLevel, plevel))
		local all = doneN == #ch.quests
		r.Status:SetTexture(Theme.Media(all and "check" or "layers"))
		W.Color(r.Status, all and "success" or "accent")
		local text = format("%s  |cff999999%d/%d|r", ch.title, doneN, #ch.quests)
		if ch.otherZones then text = text .. "  |cff999999" .. ARROW .. ch.otherZones .. "|r" end
		r.Name:SetText(text)
		W.Color(r.Name, "text")
		r.XP:SetText(xp > 0 and (thousands(xp) .. " XP") or "")
		local last = FQB.Quest(ch.last)
		local items = {}
		for _, list in ipairs({ last and last.rewards or {}, last and last.choices or {} }) do
			for _, it in ipairs(list) do items[#items + 1] = it end
		end
		for k = 1, ITEMS do setItem(r.Items[k], items[k]) end
		r.psTip = format("Chain: %s", ch.title)
		r.psTipLines = { format("%d quests, %d done", #ch.quests, doneN), "Tick it to guide the whole chain to its last quest.", "Click: open or close." }
		return
	end

	r.Toggle:Hide()
	local st = STATUS[FQB.Status(id)] or STATUS.available
	r.Level:SetText(q and q.level and q.level > 0 and tostring(q.level) or "")
	W.Color(r.Level, levelColor(q and q.level, plevel))
	r.Status:SetTexture(Theme.Media(st.glyph))
	W.Color(r.Status, st.color)
	local title = q and q.title or ("Quest " .. tostring(id))
	-- In "Near you": what to do there.
	if e.near == "turnin" then
		title = title .. "  |cff5fd068hand in|r"
	elseif e.near == "pickup" then
		title = title .. "  |cffe6ba66pick up|r"
	end
	r.Name:SetText(title)
	W.Color(r.Name, FQB.Status(id) == "done" and "textDim" or "text")
	local xp = FQB.XP(id, plevel)
	r.XP:SetText(xp and (thousands(xp) .. " XP") or "")
	if b.filter == "log" then paintNear(r, e, id) else paintSize(r, id) end
	local items = {}
	for _, list in ipairs({ q and q.rewards or {}, q and q.choices or {} }) do
		for _, it in ipairs(list) do items[#items + 1] = it end
	end
	for k = 1, ITEMS do setItem(r.Items[k], items[k]) end
	if e.dim then r:SetAlpha(0.55) end
	r.psTip, r.psTipLines = questTip(id, plevel)
end

local function paintVisible()
	if not scroll then return end
	local d, b = db()
	local plevel = FQB.PlayerLevel()
	local off = scroll:GetVerticalScroll() or 0
	local viewH = scroll:GetHeight()
	if not viewH or viewH <= 0 then viewH = 400 end
	local first = max(1, floor(off / ROW_H) + 1)
	local last = min(#flat, first + ceil(viewH / ROW_H) + 1)
	local n = 0
	for i = first, last do
		n = n + 1
		local r = row(n)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", scroll.Child, "TOPLEFT", 0, -(i - 1) * ROW_H)
		r:SetPoint("TOPRIGHT", scroll.Child, "TOPRIGHT", 0, -(i - 1) * ROW_H)
		paintRow(r, flat[i], plevel, d, b)
		r:Show()
	end
	for i = n + 1, #rows do rows[i]:Hide() end
end

---------------------------------------------------------------------------
-- Toolbar, column headers, search and details
---------------------------------------------------------------------------

local function anyZoneOpen()
	for _, e in ipairs(flat) do
		if e.kind == "zone" and e.open then return true end
	end
	return false
end

-- Collapse all (anything open) or Expand all (every zone), in this filter.
function QS.ToggleAll()
	local open = not anyZoneOpen()
	for _, z in ipairs(FQB.Zones()) do
		setOpen("z" .. z.id, open)
		if not open then
			for _, node in ipairs(z.nodes) do
				if type(node) == "table" then setOpen("c" .. node.id, false) end
			end
		end
	end
	QS.Refresh()
end

local function paintTool()
	local sel, mk = #selectedIds(), #markedIds()
	tool.Info:SetText(format("%d ticked%s%d marked", sel, DOT, mk))
	tool.Clear:SetEnabled(sel > 0)
	W.SetButtonText(tool.All, anyZoneOpen() and "Collapse all" or "Expand all")
	local _, b = db()
	tool.Unit:SetShown(b.filter == "log")
	W.SetButtonText(tool.Unit, (FQB.Opt and FQB.Opt("nearUnit") == "yards") and "In time" or "In yards")
	tool.Options:ClearAllPoints()
	tool.Options:SetPoint("RIGHT", b.filter == "log" and tool.Unit or tool.All, "LEFT", -8, 0)
	tool.Start.psTip = sel > 0 and "One guide through the ticked quests' chains."
		or (mk > 0 and "Nothing ticked: one guide through the marked quests' chains." or "Tick a quest or a chain first.")
end

local function paintHeader()
	local _, b = db()
	local sort, log = sortOf(b), b.filter == "log"
	for _, col in ipairs(header.Cols) do
		local on = sort.key == col.psKey
		W.Color(col.Label, on and "accent" or "textMuted")
		col.Arrow:SetShown(on)
		if on then
			col.Arrow:SetTexture(Theme.Media(sort.desc and "chevron-down" or "chevron-up"))
		end
	end
	local searching = header.Search:IsShown()
	for _, col in ipairs(header.Cols) do
		-- "Near" belongs to In your quest log only.
		col:SetShown(not searching and (col.psKey ~= "near" or log))
	end
	header.Rewards:SetShown(not searching)
	header.Size:SetShown(not searching and not log)
end

local function sortBy(key)
	local _, b = db()
	local sort = sortOf(b)
	if sort.key == key then
		sort.desc = not sort.desc
	else
		sort.key, sort.desc = key, key == "xp" or key == "rewards"
	end
	if scroll then W.ScrollTo(scroll, 0) end
	repaint()
end

local function headerCol(text, key, tip)
	local c = CreateFrame("Button", nil, header)
	c:SetHeight(HEAD_H)
	c.psKey = key
	c.Label = W.Text(c, "small", "textMuted")
	c.Label:SetText(text)
	c.Arrow = W.Tex(c, "ARTWORK", "chevron-down", "accent")
	c.Arrow:SetSize(10, 10)
	c.psTip = tip
	c:SetScript("OnClick", function(self) sortBy(self.psKey) end)
	header.Cols[#header.Cols + 1] = c
	return c
end

function QS.OpenSearch()
	if not header then return end
	header.Search:Show()
	header.Search:SetFocus()
	paintHeader()
end

function QS.CloseSearch()
	if not header then return end
	if header.Search:GetText() ~= "" then header.Search:SetText("") end
	header.Search:ClearFocus()
	header.Search:Hide()
	paintHeader()
end

local function onSearch(text)
	local q = lower((text or ""):match("^%s*(.-)%s*$") or "")
	if q == query then return end
	query = q
	searchOpen = {}
	if root and FQB.State() == "ready" then
		if scroll then W.ScrollTo(scroll, 0) end
		QS.Refresh()
	end
end

local function prereqText(q)
	local names = {}
	for _, src in ipairs({ q.pre or {}, q.preAny or {} }) do
		for _, p in ipairs(src) do
			local r = FQB.Quest(p)
			if r then names[#names + 1] = r.title end
		end
	end
	if #names == 0 then return nil end
	return "After: " .. concat(names, ", ")
end

-- What a quest asks, one line each: the quest log's own lines (with your
-- progress) while you have it, else Polestar's Codex objectives with the
-- mob's rank. At most GOALS lines; the rest as "+N more".
local GOALS = 3
local RANK = { boss = "boss", elite = "elite", rare = "rare" }
local function npcRank(id)
	local n = P.Codex and P.Codex.Npc and P.Codex.Npc(id)
	if not n then return nil end
	if n.boss then return RANK.boss end
	if n.rare and n.elite then return "rare elite" end
	if n.rare then return RANK.rare end
	if n.elite then return RANK.elite end
	return nil
end

local function codexGoals(id)
	local Cx = P.Codex
	local cq = Cx and Cx.Quest and Cx.Quest(id)
	local out = {}
	if not (cq and type(cq.objectives) == "table") then return out, cq end
	local function name(kind, oid, text)
		return (Cx.Name and oid and Cx.Name(kind, oid)) or text or "?"
	end
	for _, o in ipairs(cq.objectives) do
		local n = tonumber(o.count) or 0
		local line
		if o.type == "kill" then
			local who, rank = name("npc", o.id, o.text), o.id and npcRank(o.id)
			line = n > 1 and format("Kill %d %s", n, who) or ("Kill " .. who)
			if rank then line = line .. " (" .. rank .. ")" end
		elseif o.type == "item" then
			local what = name("item", o.id, o.text)
			line = n > 1 and format("Collect %d %s", n, what) or ("Collect " .. what)
		elseif o.type == "object" then
			line = "Use " .. name("object", o.id, o.text)
		elseif o.type == "talk" then
			line = "Speak with " .. name("npc", o.id, o.text)
		elseif o.text and o.text ~= "" then
			line = o.text
		end
		if line then out[#out + 1] = line end
	end
	return out, cq
end

local function goalsText(id)
	local lines = {}
	local live = FQB.Status(id) == "log" and C.GetQuestObjectives and C.GetQuestObjectives(id)
	if type(live) == "table" and #live > 0 then
		for _, o in ipairs(live) do
			if o.text and o.text ~= "" then
				lines[#lines + 1] = o.finished and ("|cff8c8c8c" .. o.text .. "|r") or o.text
			end
		end
	end
	if #lines == 0 then lines = codexGoals(id) end
	if #lines == 0 then return "" end
	local shown = {}
	for i = 1, min(#lines, GOALS) do shown[i] = "\194\183 " .. lines[i] end
	if #lines > GOALS then shown[GOALS] = shown[GOALS] .. format("  (+%d more)", #lines - GOALS) end
	return concat(shown, "\n")
end

local function paintDetails()
	local d = details
	local q = focus and FQB.Quest(focus)
	d.LoreHit.psFull = nil
	if not q then
		d.Title:SetText("Pick a quest")
		d.Sub:SetText("Click a quest for what it asks, its story and rewards; tick quests or chains, then Start guide.")
		d.Facts:SetText("")
		d.Goals:SetText("")
		d.Lore:SetText("")
		d.Story:Hide()
		d.RewardLabel:Hide()
		d.ChoiceLabel:Hide()
		for k = 1, DETAIL_ITEMS do setItem(d.Rewards[k], nil); setItem(d.Choices[k], nil) end
		d.Guide:Hide()
		d.Lookup:Hide()
		d.Mark:Hide()
		return
	end
	local plevel = FQB.PlayerLevel()
	local st = STATUS[FQB.Status(q.id)] or STATUS.available
	d.Title:SetText(q.title)
	local zone = q.zone and C.MapName and C.MapName(q.zone) or nil
	local sub = { format("Level %d", q.level or 0) }
	if q.minLevel then sub[#sub + 1] = format("from %d", q.minLevel) end
	if zone then sub[#sub + 1] = zone end
	sub[#sub + 1] = st.text
	local size, tag = nil, nil
	if FQB.QuestSize then size, tag = FQB.QuestSize(q.id) end
	if size then sub[#sub + 1] = FQB.SIZE_WORDS[size] end
	if tag then sub[#sub + 1] = tag == "dungeon" and "Dungeon" or "Group (elite)" end
	d.Sub:SetText(concat(sub, DOT))
	local facts = {}
	local xp = FQB.XP(q.id, plevel)
	if xp then
		facts[#facts + 1] = (q.xp and xp ~= q.xp) and format("%s XP (%s at its level)", thousands(xp), thousands(q.xp)) or format("%s XP", thousands(xp))
	end
	local ch = FQB.ChainOf(q.id)
	if ch then facts[#facts + 1] = format("Chain: %s (%d quests)", ch.title, #ch.quests) end
	local pre = prereqText(q)
	if pre then facts[#facts + 1] = pre end
	d.Facts:SetText(concat(facts, "\n"))
	d.Goals:SetText(goalsText(q.id))
	local story, source = FQB.QuestStory and FQB.QuestStory(q.id)
	if story then
		-- One paragraph, the start of it; "Story ›" says a click reads on.
		d.Lore:SetText("|cffe6ba66Story \226\128\186|r  " .. (story:gsub("\n+", " ")))
		d.LoreHit.psTitle, d.LoreHit.psFull, d.LoreHit.psSource = q.title, story, source
	else
		d.Lore:SetText("")
	end
	-- Another quest picked: its story stays closed until clicked.
	if d.Story:IsShown() and d.psStoryOf ~= q.id then d.Story:Hide() end
	d.psStoryOf = q.id
	local rewards, choices = q.rewards or {}, q.choices or {}
	d.RewardLabel:SetShown(#rewards > 0)
	d.ChoiceLabel:SetShown(#choices > 0)
	for k = 1, DETAIL_ITEMS do
		setItem(d.Rewards[k], rewards[k])
		setItem(d.Choices[k], choices[k])
	end
	d.ChoiceLabel:ClearAllPoints()
	if #rewards > 0 then
		d.ChoiceLabel:SetPoint("LEFT", d.Rewards[min(#rewards, DETAIL_ITEMS)], "RIGHT", 16, 0)
	else
		d.ChoiceLabel:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", SH.pad, 24)
	end
	d.Guide:Show()
	d.Lookup:SetShown(P.Lookup and P.Lookup.Show ~= nil)
	d.Mark:Show()
	W.SetButtonText(d.Mark, db().marked[q.id] and "Unmark" or "Mark")
end

-- The picked quest's whole story over the details (true), or back (false).
function QS.ShowStory(on)
	local d = details
	if not d then return end
	local hit = d.LoreHit
	if not (on and hit.psFull) then d.Story:Hide() return end
	local sp = d.Story
	sp.Title:SetText(hit.psTitle or "")
	sp.Text:SetText(hit.psFull)
	sp.Source:SetText(hit.psSource or "")
	sp:Show()
	C_Timer.After(0, function()
		local h = (sp.Text:GetStringHeight() or 0) + 8 + (sp.Source:GetStringHeight() or 0) + 8
		W.SetScrollContent(sp.Scroll, h)
		W.ScrollTo(sp.Scroll, 0)
	end)
end

function QS.Paint()
	if not root then return end
	paintVisible()
	paintTool()
	paintHeader()
	paintDetails()
end

-- The level strip shows with Available; the column headers sit under it.
local function layout()
	local _, b = db()
	local withStrip = b.filter == "available" and strip.psHasControls
	strip:SetShown(withStrip and true or false)
	if withStrip and strip.Fit then strip.Fit() end
	header:ClearAllPoints()
	header:SetPoint("TOPLEFT", withStrip and strip or tool, "BOTTOMLEFT", SH.pad - 12, 0)
	header:SetPoint("TOPRIGHT", withStrip and strip or tool, "BOTTOMRIGHT", -(SH.pad - 12) - 10, 0)
end

-- Rows again (filter, sort, search or what is open changed), then paint.
function QS.Refresh()
	if not root then return end
	layout()
	local total
	flat, total = buildFlat()
	QS.total = total
	local w = scroll:GetWidth()
	if w and w > 0 then scroll.Child:SetWidth(w - 10) end
	W.SetScrollContent(scroll, #flat * ROW_H + 8)
	message:SetShown(#flat == 0)
	if #flat == 0 then
		local _, b = db()
		local text
		if query ~= "" then
			text = format("No quest or reward matches \226\128\156%s\226\128\157.", query)
		elseif b.filter == "available" then
			text = "No quests open to you here. Raise Quests above your level, or try All quests."
		else
			text = "No quests here. Try All quests in the sidebar."
		end
		message:SetText(text)
	end
	QS.Paint()
end

---------------------------------------------------------------------------
-- The section
---------------------------------------------------------------------------

local function windowText(v)
	v = tonumber(v) or 0
	if v >= anyLevel() then return "Any level" end
	if v <= 0 then return "Your level" end
	return "+" .. v
end

-- Polestar's own settings, on the page: changed here, changed there.
local function buildStrip()
	strip = CreateFrame("Frame", nil, root)
	strip:SetPoint("TOPLEFT", tool, "BOTTOMLEFT", 0, 0)
	strip:SetPoint("TOPRIGHT", tool, "BOTTOMRIGHT", 0, 0)
	strip:SetHeight(STRIP_H)
	local known = P.GetDefault and P.GetDefault(WINDOW_KEY) ~= nil
	if not (known and W.Slider and W.CompactRow and W.LayoutRow) then return end
	local slider = W.Slider(strip, "Quests above your level", WINDOW_KEY, 0, anyLevel(), 1, windowText,
		nil)
	W.CompactRow(slider, { height = STRIP_H })
	slider:SetPoint("TOPLEFT", strip, "TOPLEFT", SH.pad - 12, 0)
	strip.Slider = slider
	if P.GetDefault(LOW_KEY) ~= nil and W.Toggle then
		local low = W.Toggle(strip, "Low-level quests", LOW_KEY, nil)
		W.CompactRow(low, { height = STRIP_H })
		low:SetPoint("TOPLEFT", slider, "TOPRIGHT", 12, 0)
		strip.Low = low
	end
	-- The rows share the strip's own width: a compact row gives its label
	-- what the control leaves, so the slider takes most of it.
	local function fit()
		local w = strip:GetWidth()
		if not w or w <= 0 then return end
		local avail = w - (SH.pad - 12) * 2
		local lowW = strip.Low and 230 or 0
		local sliderW = max(300, avail - (strip.Low and (lowW + 12) or 0))
		W.LayoutRow(slider, sliderW)
		if strip.Low then W.LayoutRow(strip.Low, max(180, avail - sliderW - 12)) end
	end
	strip.Fit = fit
	strip:SetScript("OnSizeChanged", fit)
	W.LayoutRow(slider, 420)
	if strip.Low then W.LayoutRow(strip.Low, 230) end
	strip.psHasControls = true
end

local function buildHeader()
	header = CreateFrame("Frame", nil, root)
	header:SetHeight(HEAD_H)
	header.Cols = {}
	local rule = W.Divider(header)
	rule:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
	rule:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
	local lvl = headerCol("Lvl", "level", "Sort by level (again: the other way round)")
	lvl:SetPoint("LEFT", header, "LEFT", 4, 0)
	lvl:SetWidth(52)
	header.LvlCol = lvl
	lvl.Label:SetPoint("LEFT", lvl, "LEFT", 4, 0)
	lvl.Arrow:SetPoint("LEFT", lvl.Label, "RIGHT", 4, 0)
	local name = headerCol("Quest", "name", "Sort by name (again: the other way round)")
	name:SetPoint("LEFT", lvl, "RIGHT", 8, 0)
	name:SetWidth(140)
	name.Label:SetPoint("LEFT", name, "LEFT", 4, 0)
	name.Arrow:SetPoint("LEFT", name.Label, "RIGHT", 4, 0)
	header.NameCol = name
	local xp = headerCol("XP", "xp", "Sort by the XP it gives you now (again: the other way round)")
	xp:SetPoint("RIGHT", header, "RIGHT", -XP_RIGHT, 0)
	xp:SetWidth(XP_W)
	xp.Label:SetPoint("RIGHT", xp, "RIGHT", 0, 0)
	xp.Arrow:SetPoint("RIGHT", xp.Label, "LEFT", -4, 0)
	header.XPCol = xp
	local rw = headerCol("Rewards", "rewards", nil)
	rw:SetPoint("RIGHT", header, "RIGHT", -ITEMS_RIGHT, 0)
	rw:SetWidth(70)
	rw.Label:SetPoint("RIGHT", rw, "RIGHT", 0, 0)
	rw.Arrow:SetPoint("RIGHT", rw.Label, "LEFT", -4, 0)
	header.Rewards = rw
	header.Size = W.Text(header, "small", "textMuted")
	header.Size:SetText("Length")
	header.Size:SetPoint("RIGHT", header, "RIGHT", -(XP_RIGHT + XP_W + 6), 0)
	local near = headerCol("Near", "near", nil)
	near:SetPoint("RIGHT", header, "RIGHT", -(XP_RIGHT + XP_W + 6), 0)
	near:SetWidth(SIZE_W + 16)
	near.Label:SetPoint("RIGHT", near, "RIGHT", 0, 0)
	near.Arrow:SetPoint("RIGHT", near.Label, "LEFT", -4, 0)
	header.NearCol = near
	header.Find = W.IconButton(header, "search", 22, nil, function()
		if header.Search:IsShown() then QS.CloseSearch() else QS.OpenSearch() end
	end)
	header.Find:SetPoint("RIGHT", header, "RIGHT", 0, 0)
	header.Search = W.SearchBox(header, { "Search quests and reward items", "Search quests", "Search" }, onSearch)
	-- Across the whole header, the column labels hidden while it shows
	-- (paintHeader), on a solid backing so nothing shows through its fill.
	header.Search:SetPoint("LEFT", header, "LEFT", 4, 0)
	header.Search:SetPoint("RIGHT", header.Find, "LEFT", -6, 0)
	W.Fill(header.Search, "panel", "BACKGROUND", -8)
	header.Search:HookScript("OnEscapePressed", function() QS.CloseSearch() end)
	header.Search:Hide()
end

-- Ctrl+F on the page opens the search; every other key goes on to the game.
local function hookKeys()
	if not (root.EnableKeyboard and root.SetPropagateKeyboardInput) then return end
	local function propagate(on)
		if InCombatLockdown and InCombatLockdown() then return end
		pcall(root.SetPropagateKeyboardInput, root, on)
	end
	root:EnableKeyboard(true)
	propagate(true)
	root:SetScript("OnKeyDown", function(self, key)
		if key == "F" and IsControlKeyDown and IsControlKeyDown() then
			propagate(false)
			QS.OpenSearch()
			C_Timer.After(0, function() propagate(true) end)
		end
	end)
end

function QS.Build(parent, shell)
	if root then return root end
	hub = shell
	root = CreateFrame("Frame", nil, parent)
	root:SetAllPoints(parent)

	tool = CreateFrame("Frame", nil, root)
	tool:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
	tool:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, 0)
	tool:SetHeight(TOOL_H)
	tool.Start = W.Button(tool, "Start guide", function() QS.Start() end, { height = 28, primary = true, icon = "icon-goto" })
	tool.Start:SetPoint("RIGHT", tool, "RIGHT", -SH.pad, 0)
	tool.Clear = W.Button(tool, "Clear ticks", function()
		local _, b = db()
		b.selected = {}
		QS.Paint()
	end, { height = 28, ghost = true })
	tool.Clear:SetPoint("RIGHT", tool.Start, "LEFT", -8, 0)
	tool.All = W.Button(tool, "Collapse all", function() QS.ToggleAll() end, { height = 28, ghost = true })
	tool.All:SetPoint("RIGHT", tool.Clear, "LEFT", -8, 0)
	-- In your quest log: the way shown in time on foot or in yards (also on
	-- Freestyle's options page), and that page itself.
	tool.Unit = W.Button(tool, "In yards", function()
		if FQB.SetOpt then FQB.SetOpt("nearUnit", FQB.Opt("nearUnit") == "yards" and "time" or "yards") end
		if root and root:IsVisible() then repaint() end
	end, { height = 28, ghost = true })
	tool.Unit:SetPoint("RIGHT", tool.All, "LEFT", -8, 0)
	tool.Options = W.IconButton(tool, "sliders", 22, nil, function()
		if FQB.ShowOptions then FQB.ShowOptions() end
	end)
	tool.Options:SetPoint("RIGHT", tool.Unit, "LEFT", -8, 0)
	tool.Info = W.Text(tool, "small", "textDim")
	tool.Info:SetPoint("LEFT", tool, "LEFT", SH.pad, 0)

	buildStrip()
	buildHeader()

	details = CreateFrame("Frame", nil, root)
	details:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 0, 0)
	details:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)
	details:SetHeight(DETAIL_H)
	W.Fill(details, "panel")
	local rule = W.Divider(details)
	rule:SetPoint("TOPLEFT", details, "TOPLEFT", 0, 0)
	rule:SetPoint("TOPRIGHT", details, "TOPRIGHT", 0, 0)
	local d = details
	d.Title = W.Text(d, "body", "accent")
	d.Title:SetPoint("TOPLEFT", d, "TOPLEFT", SH.pad, -14)
	d.Title:SetPoint("RIGHT", d, "RIGHT", -200, 0)
	d.Sub = W.Text(d, "small", "textDim")
	d.Sub:SetPoint("TOPLEFT", d.Title, "BOTTOMLEFT", 0, -4)
	d.Sub:SetPoint("RIGHT", d, "RIGHT", -200, 0)
	d.Facts = W.Text(d, "small", "text")
	d.Facts:SetWordWrap(true)
	d.Facts:SetJustifyV("TOP")
	d.Facts:SetPoint("TOPLEFT", d.Sub, "BOTTOMLEFT", 0, -6)
	d.Facts:SetPoint("RIGHT", d, "RIGHT", -200, 0)
	-- What the quest asks (Codex objectives, or the quest log's own lines).
	d.Goals = W.Text(d, "small", "text")
	d.Goals:SetWordWrap(true)
	d.Goals:SetJustifyV("TOP")
	d.Goals:SetPoint("TOPLEFT", d.Facts, "BOTTOMLEFT", 0, -6)
	d.Goals:SetPoint("RIGHT", d, "RIGHT", -200, 0)
	-- The story, cut short; all of it on hover.
	d.Lore = W.Text(d, "small", "textDim")
	d.Lore:SetWordWrap(true)
	d.Lore:SetJustifyV("TOP")
	if d.Lore.SetMaxLines then d.Lore:SetMaxLines(2) end
	d.Lore:SetPoint("TOPLEFT", d.Goals, "BOTTOMLEFT", 0, -6)
	d.Lore:SetPoint("RIGHT", d, "RIGHT", -200, 0)
	-- Click the story to read all of it: a scrolling page over the details'
	-- left side, closed with the same click or "Close".
	d.LoreHit = CreateFrame("Button", nil, d)
	d.LoreHit:SetAllPoints(d.Lore)
	d.LoreHit:SetScript("OnClick", function(self) if self.psFull then QS.ShowStory(true) end end)
	local sp = CreateFrame("Frame", nil, d)
	sp:SetPoint("TOPLEFT", d, "TOPLEFT", 0, -1)
	sp:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -190, 0)
	sp:SetFrameLevel(d:GetFrameLevel() + 20)
	sp:EnableMouse(true)
	W.Fill(sp, "panel")
	sp.Title = W.Text(sp, "body", "accent")
	sp.Title:SetPoint("TOPLEFT", sp, "TOPLEFT", SH.pad, -14)
	sp.Title:SetPoint("RIGHT", sp, "RIGHT", -110, 0)
	sp.Close = W.Button(sp, "Close", function() QS.ShowStory(false) end, { height = 22, ghost = true, icon = "chevron-up" })
	sp.Close:SetPoint("TOPRIGHT", sp, "TOPRIGHT", -12, -10)
	sp.Scroll = W.Scroll(sp)
	sp.Scroll:SetPoint("TOPLEFT", sp.Title, "BOTTOMLEFT", 0, -8)
	sp.Scroll:SetPoint("BOTTOMRIGHT", sp, "BOTTOMRIGHT", -12, 10)
	sp.Text = W.Text(sp.Scroll.Child, "small", "text")
	sp.Text:SetWordWrap(true)
	sp.Text:SetJustifyH("LEFT")
	sp.Text:SetJustifyV("TOP")
	sp.Text:SetPoint("TOPLEFT", sp.Scroll.Child, "TOPLEFT", 0, 0)
	sp.Source = W.Text(sp.Scroll.Child, "small", "textMuted")
	sp.Source:SetWordWrap(true)
	sp.Source:SetJustifyH("LEFT")
	sp.Source:SetPoint("TOPLEFT", sp.Text, "BOTTOMLEFT", 0, -8)
	sp.Scroll:HookScript("OnSizeChanged", function(self, w)
		if not (w and w > 0) then return end
		self.Child:SetWidth(w - 14)
		sp.Text:SetWidth(w - 14)
		sp.Source:SetWidth(w - 14)
	end)
	sp:SetScript("OnMouseUp", function() QS.ShowStory(false) end)
	sp:Hide()
	d.Story = sp
	d.RewardLabel = W.Text(d, "small", "textMuted")
	d.RewardLabel:SetText("Rewards")
	d.RewardLabel:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", SH.pad, 24)
	d.Rewards, d.Choices = {}, {}
	local prev = d.RewardLabel
	for k = 1, DETAIL_ITEMS do
		local b = itemButton(d, 26, true)
		b:SetPoint("LEFT", prev, "RIGHT", k == 1 and 8 or 4, 0)
		d.Rewards[k] = b
		prev = b
	end
	d.ChoiceLabel = W.Text(d, "small", "textMuted")
	d.ChoiceLabel:SetText("Choose one")
	prev = d.ChoiceLabel
	for k = 1, DETAIL_ITEMS do
		local b = itemButton(d, 26, true)
		b:SetPoint("LEFT", prev, "RIGHT", k == 1 and 8 or 4, 0)
		d.Choices[k] = b
		prev = b
	end
	d.Guide = W.Button(d, "Guide this quest", function() if focus then QS.Start({ focus }) end end, { height = 26, icon = "icon-goto" })
	d.Guide:SetPoint("TOPRIGHT", d, "TOPRIGHT", -SH.pad, -14)
	d.Lookup = W.Button(d, "Show in Lookup", function() if focus then QS.ShowInLookup(focus) end end, { height = 26, ghost = true })
	d.Lookup:SetPoint("TOPRIGHT", d.Guide, "BOTTOMRIGHT", 0, -6)
	d.Mark = W.Button(d, "Mark", function() if focus then QS.ToggleMark(focus) end end, { height = 26, ghost = true, icon = "star" })
	d.Mark:SetPoint("TOPRIGHT", d.Lookup, "BOTTOMRIGHT", 0, -6)
	d.Note = W.Text(d, "small", "warning")
	d.Note:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -SH.pad, 18)
	d.Note:SetJustifyH("RIGHT")

	scroll = W.Scroll(root)
	scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
	scroll:SetPoint("BOTTOMRIGHT", details, "TOPRIGHT", -(SH.pad - 12), 4)
	scroll:HookScript("OnVerticalScroll", function() paintVisible() end)
	scroll:HookScript("OnSizeChanged", function(self, w)
		if w and w > 0 then self.Child:SetWidth(w - 10) end
		paintVisible()
	end)

	message = W.Text(root, "note", "textMuted")
	message:SetPoint("TOP", scroll, "TOP", 0, -40)
	message:SetWordWrap(true)
	message:SetWidth(420)
	message:SetJustifyH("CENTER")

	layout()
	hookKeys()
	return root
end

local LOADING = {
	idle = "Reading Polestar's quest data...",
	loading = "Reading Polestar's quest data...",
	waiting = "Polestar's quest data loads after combat.",
}

function QS.Render()
	if not root then return end
	local st, why = FQB.State()
	local plevel = FQB.PlayerLevel()
	if hub and W.ShellTitle then
		local sub
		if st == "ready" then
			local counts = QS.Counts()
			sub = format("Level %d%s%d available%s%d marked", plevel, DOT, counts.available or 0, DOT, #markedIds())
		else
			sub = "Every quest you can take, by zone"
		end
		W.ShellTitle(hub, "Quests", sub)
	end
	if st ~= "ready" then
		-- Built on the next frame: never from inside the hub's own render.
		if st == "idle" then C_Timer.After(0, function() FQB.Build() end) end
		local text = LOADING[st]
		if st == "failed" then
			text = (why == "missing" or why == "unavailable" or why == "empty")
				and "The quest browser needs Polestar's Lookup data (the Polestar_Codex addon). Turn it on in the addon list."
				or ("Polestar's quest data could not be read (" .. tostring(why) .. ").")
		end
		flat = {}
		for i = 1, #rows do rows[i]:Hide() end
		W.SetScrollContent(scroll, 8)
		message:SetText(text or "")
		message:Show()
		tool:Hide()
		strip:Hide()
		header:Hide()
		details:Hide()
		return
	end
	tool:Show()
	header:Show()
	details:Show()
	QS.Refresh()
end

function QS.Nav()
	local _, b = db()
	local counts = QS.Counts()
	local items = {}
	for i, f in ipairs(FILTERS) do
		items[i] = { key = f.key, label = f.label, icon = f.icon, count = counts[f.key] }
	end
	return items, b.filter
end

function QS.OnNav(key)
	local _, b = db()
	b.filter = key
	focusItem = nil
	if scroll then W.ScrollTo(scroll, 0) end
	repaint()
end

function QS.Show()
	if UI.ShowPicker then UI.ShowPicker() end
	local Pk = UI.Picker
	if Pk and Pk.ShowSection then Pk.ShowSection(KEY) end
end
FQ.Browse = QS.Show

-- Where the player is on the Quests page, to come back to (Nav.lua): the
-- list, the picked quest, the search and how far it was scrolled.
function QS.Origin()
	local _, b = db()
	local filter, picked, lit, text = b.filter, focus, focusItem, query
	local off = scroll and scroll:GetVerticalScroll() or 0
	return { key = KEY, label = "Quests", restore = function()
		local _, b2 = db()
		b2.filter = filter
		focus, focusItem = picked, lit
		QS.Show()
		if header and text ~= "" then
			QS.OpenSearch()
			header.Search:SetText(text)
		end
		C_Timer.After(0, function()
			if not scroll then return end
			QS.Refresh()
			W.ScrollTo(scroll, off)
			paintVisible()
		end)
	end }
end

-- Lookup's page for a quest, with "Back to Quests" there.
function QS.ShowInLookup(id)
	if not (id and P.Lookup and P.Lookup.Show) then return end
	local go = function() P.Lookup.Show(nil, "quest", id) end
	if FQB.Nav then FQB.Nav.Jump(QS.Origin(), go) else go() end
end

-- Show these quests in the browser (from the Gear page or Lookup): All
-- quests, their zones and chains open, the first one picked and scrolled to.
-- opts.item: a reward of theirs to light up (the one the Gear page was on).
function QS.Reveal(ids, opts)
	local _, b = db()
	b.filter = "all"
	db()
	focus = nil
	focusItem = opts and opts.item or nil
	for _, id in ipairs(ids or {}) do
		local q = FQB.Quest(id)
		if q then
			local ch = FQB.ChainOf(id)
			b.open.all["z" .. ((ch and ch.zone) or q.zone or 0)] = true
			if ch then b.open.all["c" .. ch.id] = true end
			focus = focus or id
		end
	end
	if header and header.Search and header.Search:IsShown() then QS.CloseSearch() end
	QS.Show()
	-- Once the list is built: its row in view.
	C_Timer.After(0, function()
		if not (scroll and focus) then return end
		QS.Refresh()
		for i, e in ipairs(flat) do
			if e.kind == "quest" and e.id == focus then
				W.ScrollTo(scroll, max(0, (i - 1) * ROW_H - 3 * ROW_H))
				paintVisible()
				return
			end
		end
	end)
end

FQB.Listen(function()
	if root and root:IsVisible() then repaint() end
end)

-- The level window or low-level quests changed (here, in Options, or by a
-- reset): Available follows.
if P.On then
	P.On("SETTING_CHANGED", function(path)
		if path == WINDOW_KEY or path == LOW_KEY or path == "" or path == "qol" or path == nil then
			if root and root:IsVisible() then repaint() end
		elseif type(path) == "string" and path:find("^freestyle") then
			-- Freestyle's own options (Near you): planned again now.
			reachAt = 0
			if root and root:IsVisible() then refreshReach(true); repaint() end
		end
	end)
end

if UI.RegisterSection then
	UI.RegisterSection({
		key = KEY, label = "Quests", icon = FQ.ICON, order = 25,
		build = QS.Build, render = QS.Render,
		nav = QS.Nav, onNav = QS.OnNav,
		enter = function() QS.Start() end,
	})
	QS.Registered = true
end

-- In your quest log, while it shows: "Near you" and the Near column follow
-- you as you move (a light pass every few seconds, never in combat).
if C_Timer and C_Timer.NewTicker then
	C_Timer.NewTicker(5, function()
		if not (root and root:IsVisible()) or query ~= "" then return end
		if InCombatLockdown and InCombatLockdown() then return end
		local _, b = db()
		if b.filter ~= "log" or FQB.State() ~= "ready" then return end
		refreshReach(true)
		QS.Refresh()
	end)
end
