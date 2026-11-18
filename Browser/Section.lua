-- Polestar Free Questing: the Quests section of Polestar's hub.
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
local DETAIL_H = 156
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

local function db()
	local d = FQ.CharDB()
	local b = d.browser
	if b.filter ~= "available" and b.filter ~= "all" and b.filter ~= "marked" and b.filter ~= "log" then
		b.filter = "available"
	end
	local s = b.sort
	if s.key ~= "level" and s.key ~= "xp" and s.key ~= "name" then s.key = "level" end
	if type(b.open[b.filter]) ~= "table" then b.open[b.filter] = {} end
	return d, b
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

-- The rows: zones, then their chains and quests, then a chain's quests.
local function buildFlat()
	local d, b = db()
	local plevel = FQB.PlayerLevel()
	local sort, filter = b.sort, b.filter
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
	for _, ze in ipairs(zoneList) do
		total = total + ze.count
		local zkey = "z" .. ze.zone.id
		local zopen = isOpen(zkey, ze.here)
		out[#out + 1] = { kind = "zone", zone = ze.zone, count = ze.count, depth = 0, key = zkey, open = zopen, here = ze.here }
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
						for _, id in ipairs(node.quests) do
							out[#out + 1] = { kind = "quest", id = id, depth = 2, dim = not hitSet[id] }
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

local function itemButton(parent, size)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size, size)
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
	local id = rowQuest(r)
	if not id then return end
	local _, b = db()
	b.selected[id] = self:GetChecked() and true or nil
	QS.Paint()
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
		{ text = "Show in Lookup", icon = "search", onClick = function()
			if P.Lookup and P.Lookup.Show then P.Lookup.Show(nil, "quest", id) end
		end },
	}, { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = 40, y = 0 })
end

local function onRowClick(self, button)
	local e = self.psEntry
	if not e then return end
	if button == "RightButton" then
		rowMenu(self)
		return
	end
	if e.kind == "zone" or e.kind == "chain" then
		setOpen(e.key, not e.open)
		if e.kind == "chain" then focus = e.chain.last end
		QS.Refresh()
	else
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
	r.Star = W.IconButton(r, "star", STAR_W, "Mark: Start guide takes the marked quests when none is ticked.", onStar)
	r.Star:SetPoint("RIGHT", r, "RIGHT", -2, 0)
	r.Items = {}
	local prev = r.Star
	for k = 1, ITEMS do
		local b = itemButton(r, ITEM_W)
		b:SetPoint("RIGHT", prev, "LEFT", k == 1 and -6 or -ITEM_GAP, 0)
		r.Items[k] = b
		prev = b
	end
	r.XP = W.Text(r, "small", "textDim")
	r.XP:SetJustifyH("RIGHT")
	r.XP:SetWidth(XP_W)
	r.XP:SetPoint("RIGHT", r, "RIGHT", -XP_RIGHT, 0)
	r.Name = W.Text(r, "body", "text")
	r.Name:SetJustifyH("LEFT")
	r:SetScript("OnClick", onRowClick)
	r:SetScript("OnEnter", W.SimpleTip)
	r:SetScript("OnLeave", W.HideTip)
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
	r.Name:SetPoint("RIGHT", r.XP, "LEFT", -8, 0)
	r.Sel:SetShown(false)
	r:SetAlpha(1)

	if e.kind == "zone" then
		local z = e.zone
		r.Toggle:Show()
		r.Toggle:SetTexture(Theme.Media(e.open and "chevron-down" or "chevron-right"))
		r.Check:Hide()
		r.Level:Hide()
		if e.here then
			-- You are here.
			r.Status:ClearAllPoints()
			r.Status:SetPoint("LEFT", r.Toggle, "RIGHT", 6, 0)
			r.Status:SetTexture(Theme.Media("icon-goto"))
			W.Color(r.Status, "accent")
			r.Status:Show()
			r.Name:SetPoint("LEFT", r.Status, "RIGHT", 6, 0)
		else
			r.Status:Hide()
			r.Name:SetPoint("LEFT", r.Toggle, "RIGHT", 6, 0)
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
	r.Name:SetText(q and q.title or ("Quest " .. tostring(id)))
	W.Color(r.Name, FQB.Status(id) == "done" and "textDim" or "text")
	local xp = FQB.XP(id, plevel)
	r.XP:SetText(xp and (thousands(xp) .. " XP") or "")
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
	tool.Start.psTip = sel > 0 and "One guide through the ticked quests' chains."
		or (mk > 0 and "Nothing ticked: one guide through the marked quests' chains." or "Tick a quest or a chain first.")
end

local function paintHeader()
	local _, b = db()
	for _, col in ipairs(header.Cols) do
		local on = b.sort.key == col.psKey
		W.Color(col.Label, on and "accent" or "textMuted")
		col.Arrow:SetShown(on)
		if on then
			col.Arrow:SetTexture(Theme.Media(b.sort.desc and "chevron-down" or "chevron-up"))
		end
	end
	local searching = header.Search:IsShown()
	header.XPCol:SetShown(not searching)
	header.Rewards:SetShown(not searching)
end

local function sortBy(key)
	local _, b = db()
	if b.sort.key == key then
		b.sort.desc = not b.sort.desc
	else
		b.sort.key, b.sort.desc = key, key == "xp"
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
	c:SetScript("OnEnter", W.SimpleTip)
	c:SetScript("OnLeave", W.HideTip)
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

local function paintDetails()
	local d = details
	local q = focus and FQB.Quest(focus)
	if not q then
		d.Title:SetText("Pick a quest")
		d.Sub:SetText("Click a quest for its rewards; tick quests or chains, then Start guide.")
		d.Facts:SetText("")
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
		"How far above your level Available reaches. The same setting as Polestar's quest markers on the map (Options > Map).")
	W.CompactRow(slider, { height = STRIP_H })
	slider:SetPoint("TOPLEFT", strip, "TOPLEFT", SH.pad - 12, 0)
	strip.Slider = slider
	if P.GetDefault(LOW_KEY) ~= nil and W.Toggle then
		local low = W.Toggle(strip, "Low-level quests", LOW_KEY, "Include grey quests, which give little XP.")
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
	header.Rewards = W.Text(header, "small", "textMuted")
	header.Rewards:SetText("Rewards")
	header.Rewards:SetPoint("RIGHT", header, "RIGHT", -ITEMS_RIGHT, 0)
	header.Find = W.IconButton(header, "search", 22, "Search quests and rewards (Ctrl+F)", function()
		if header.Search:IsShown() then QS.CloseSearch() else QS.OpenSearch() end
	end)
	header.Find:SetPoint("RIGHT", header, "RIGHT", 0, 0)
	header.Search = W.SearchBox(header, { "Search quests and reward items", "Search quests", "Search" }, onSearch)
	header.Search:SetPoint("LEFT", name, "LEFT", 0, 0)
	header.Search:SetPoint("RIGHT", header.Find, "LEFT", -6, 0)
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
	tool.Start:HookScript("OnEnter", W.SimpleTip)
	tool.Start:HookScript("OnLeave", W.HideTip)
	tool.Clear = W.Button(tool, "Clear ticks", function()
		local _, b = db()
		b.selected = {}
		QS.Paint()
	end, { height = 28, ghost = true })
	tool.Clear:SetPoint("RIGHT", tool.Start, "LEFT", -8, 0)
	tool.All = W.Button(tool, "Collapse all", function() QS.ToggleAll() end, { height = 28, ghost = true })
	tool.All:SetPoint("RIGHT", tool.Clear, "LEFT", -8, 0)
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
	d.RewardLabel = W.Text(d, "small", "textMuted")
	d.RewardLabel:SetText("Rewards")
	d.RewardLabel:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", SH.pad, 24)
	d.Rewards, d.Choices = {}, {}
	local prev = d.RewardLabel
	for k = 1, DETAIL_ITEMS do
		local b = itemButton(d, 26)
		b:SetPoint("LEFT", prev, "RIGHT", k == 1 and 8 or 4, 0)
		d.Rewards[k] = b
		prev = b
	end
	d.ChoiceLabel = W.Text(d, "small", "textMuted")
	d.ChoiceLabel:SetText("Choose one")
	prev = d.ChoiceLabel
	for k = 1, DETAIL_ITEMS do
		local b = itemButton(d, 26)
		b:SetPoint("LEFT", prev, "RIGHT", k == 1 and 8 or 4, 0)
		d.Choices[k] = b
		prev = b
	end
	d.Guide = W.Button(d, "Guide this quest", function() if focus then QS.Start({ focus }) end end, { height = 26, icon = "icon-goto" })
	d.Guide:SetPoint("TOPRIGHT", d, "TOPRIGHT", -SH.pad, -14)
	d.Lookup = W.Button(d, "Show in Lookup", function()
		if focus and P.Lookup and P.Lookup.Show then P.Lookup.Show(nil, "quest", focus) end
	end, { height = 26, ghost = true })
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
	if scroll then W.ScrollTo(scroll, 0) end
	repaint()
end

function QS.Show()
	if UI.ShowPicker then UI.ShowPicker() end
	local Pk = UI.Picker
	if Pk and Pk.ShowSection then Pk.ShowSection(KEY) end
end
FQ.Browse = QS.Show

-- Show these quests in the browser (from the Gear page or Lookup): All
-- quests, their zones and chains open, the first one picked and scrolled to.
function QS.Reveal(ids)
	local _, b = db()
	b.filter = "all"
	db()
	focus = nil
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
