-- Polestar Free Questing: the Gear section of Polestar's hub.
--
-- Your gear as the character pane lays it out (head to wrist on the left,
-- hands to trinkets on the right, weapons along the foot), and between the
-- columns the slot you picked: what you wear there, then the upgrades you can
-- get for it (GearIndex.lua: items you can wear now or at your next level,
-- from sources within the reach of Polestar's "Quests above your level"),
-- with the gain Polestar's item tooltips show. A slot with an upgrade under
-- way or ready now carries a dot.
--
-- The list sorts like the Quests list, by its column headers: Recommended
-- (what you are already on first, then what is ready now, then the rest;
-- each by gain), Item, Closest (fewest steps), Lvl, Gain. The sidebar picks
-- the sources (quests, dungeons, rares and elites, vendors; never the auction
-- house) or only your marked items.
--
-- Star the pieces you want, then Gear guide: one guide, the quest chains for
-- quest rewards first (Planner.lua), then Lookup's own way to the rest.
--
-- /freequest gear opens it.
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
local FQB = FQ and FQ.Browser
local FQG = FQB and FQB.Gear
local UI, W, Theme = P and P.UI, P and P.Widgets, P and P.Theme
if not (FQG and UI and W and Theme and UI.RegisterSection) then return end

local C = P.Compat
local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor, max, min = math.floor, math.max, math.min
local format, concat, lower = string.format, table.concat, string.lower

local SH = W.SHELL or { pad = 32 }
local KEY = "Gear"
local SLOT_SIZE = 40
local SLOT_GAP = 6
local SIDE = SH.pad - 12      -- the columns' distance from the page's edges
local CARD_H = 60
local TOOL_H = 36
local HEAD_H = 28
local ROW_H = 40
local MAX_ROWS = 40
-- A row's right-hand columns, under the header's: Closest, Lvl, Gain.
local COL_TODO, COL_LVL, COL_GAIN, COL_GAP = 88, 34, 64, 6
local DOT = "  \194\183  "
-- On and off in the sidebar: Polestar's own glyphs (the game's font has no tick).
local GLYPHS = "Interface\\AddOns\\Polestar\\Media\\UI\\"
local ON = "|T" .. GLYPHS .. "check:12:12:0:0:16:16:0:16:0:16:95:208:104|t "
local OFF = "|T" .. GLYPHS .. "circle:12:12:0:0:16:16:0:16:0:16:120:120:120|t "

local LEFT = { 1, 2, 3, 15, 5, 9 }
local RIGHT = { 10, 6, 7, 8, 11, 12, 13, 14 }
local FOOT = { 16, 17, 18 }
local SLOT_KEY = {
	[1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot", [15] = "BackSlot", [5] = "ChestSlot", [9] = "WristSlot",
	[10] = "HandsSlot", [6] = "WaistSlot", [7] = "LegsSlot", [8] = "FeetSlot", [11] = "Finger0Slot", [12] = "Finger1Slot",
	[13] = "Trinket0Slot", [14] = "Trinket1Slot", [16] = "MainHandSlot", [17] = "SecondaryHandSlot", [18] = "RangedSlot",
}

local SOURCES = {
	{ key = "quest", label = "Quests", icon = "icon-accept" },
	{ key = "dungeon", label = "Dungeons", icon = "icon-dungeon" },
	{ key = "rare", label = "Rares & elites", icon = "icon-elite" },
	{ key = "vendor", label = "Vendors", icon = "icon-vendor" },
}
local TIER_COLOR = { "accent", "success", "textMuted" }
local TIER_TEXT = { "Under way: in your log or its chain started", "Ready now", "Soon: earlier quests or a level to go" }

local GV = {}
FQB.GearSection = GV

local root, hub, center, card, tool, header, list, message
local banner, shield
local slots = {}
local rows = {}

local function db()
	local d = FQ.CharDB()
	local g = d.gear
	if type(g.sort) ~= "table" then g.sort = { key = "rec", desc = false } end
	return d, g
end

local function repaint()
	if not (root and root:IsVisible()) then return end
	local Pk = UI.Picker
	if Pk and Pk.Render then Pk.Render() else GV.Render() end
end

local function qualityColor(q)
	local c = ITEM_QUALITY_COLORS and q and ITEM_QUALITY_COLORS[q]
	if c then return c.r, c.g, c.b end
	if GetItemQualityColor and q then
		local r, g, b = GetItemQualityColor(q)
		if r then return r, g, b end
	end
	return 1, 1, 1
end

-- A gain of 100% or more in the list: Polestar's upgrade glyph, not the
-- words ("big upgrade" does not fit its column).
local BIG = "|T" .. GLYPHS .. "qol-upgrade:14:14:0:0:16:16:0:16:0:16:95:208:104|t 100%+"

local function gainText(res, short)
	if not res.pct then return short and "new" or "fills slot" end
	if short and res.pct >= 100 then return BIG end
	local G = P.Gear
	if G and G.GainText then return (G.GainText(res.pct)) end
	return format("+%d%%", floor(res.pct + 0.5))
end

local function slotName(slot)
	local G = P.Gear
	return (G and G.SlotName and G.SlotName(slot)) or ("Slot " .. slot)
end

local function itemInfo(link)
	if not link then return nil end
	local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if not get then return nil end
	local name, _, quality, ilvl, req = get(link)
	return name, quality, ilvl, req
end

---------------------------------------------------------------------------
-- What the planner needs: gear advice on, and Polestar's data addons
---------------------------------------------------------------------------

local DATA_ADDONS = {
	{ name = "Polestar_ItemDB", label = "item data" },
	{ name = "Polestar_Codex", label = "Lookup data" },
}

-- "ok" | "disabled" | "missing" for a load-on-demand addon.
local function addonState(name)
	local A = C_AddOns
	if not (A and A.GetAddOnInfo) then return "ok" end
	if A.IsAddOnLoaded and A.IsAddOnLoaded(name) then return "ok" end
	local _, _, _, loadable, reason = A.GetAddOnInfo(name)
	if reason == "MISSING" then return "missing" end
	if A.GetAddOnEnableState then
		local who = UnitName and UnitName("player") or nil
		local on = A.GetAddOnEnableState(name, who)
		if on == 0 or on == false then return "disabled" end
	end
	if not loadable and reason == "DISABLED" then return "disabled" end
	return "ok"
end

-- What stops the planner, if anything: { text, button, action } | nil.
local function blocker()
	local G = P.Gear
	if not (G and G.CompareToEquipped and G.Usability and G.ScoreItem and P.ItemDB) then
		return { text = "This Polestar has no gear advice. The gear planner needs Polestar 0.4.0 or newer." }
	end
	if P.Get and not P.Get("gear.enabled") then
		return {
			text = "Polestar's gear advice is turned off. The gear planner uses it to weigh every item for your class and talents.",
			button = "Turn on gear advice",
			tip = "The same setting as Options > Questing > Rewards & gear > Gear advice.",
			action = function()
				P.Set("gear.enabled", true)
				FQG.Retry()
			end,
		}
	end
	for _, a in ipairs(DATA_ADDONS) do
		local st = addonState(a.name)
		if st == "missing" then
			return { text = format("Polestar's %s (%s) is not installed. Install Polestar again to get it.", a.label, a.name) }
		elseif st == "disabled" then
			return {
				text = format("Polestar's %s (%s) is turned off in your addon list. The gear planner reads every item from it.", a.label, a.name),
				button = "Turn on and reload",
				tip = "Turns it on for this character and reloads the interface.",
				action = function()
					local who = UnitName and UnitName("player") or nil
					if C_AddOns and C_AddOns.EnableAddOn then C_AddOns.EnableAddOn(a.name, who) end
					if ReloadUI then ReloadUI() end
				end,
			}
		end
	end
	return nil
end
GV.Blocker = blocker

---------------------------------------------------------------------------
-- What is shown
---------------------------------------------------------------------------

local function keepSource(src)
	local _, g = db()
	return g.sources[src.kind] and true or false
end

local function shownSources(res)
	local out = {}
	for _, src in ipairs(res.sources or {}) do
		if keepSource(src) then out[#out + 1] = src end
	end
	return out
end

local function shown(res)
	local _, g = db()
	if g.markedOnly and not g.marked[res.id] then return false end
	return FQG.Rank(res, keepSource) ~= nil
end

local function sourceText(src)
	if src.kind == "quest" then
		local zone = src.zone and C.MapName and C.MapName(src.zone)
		local parts = { format("%s: %s", src.choice and "Quest reward choice" or "Quest", src.name or "?") }
		if zone then parts[#parts + 1] = zone end
		if src.chainTotal then parts[#parts + 1] = format("chain %d/%d", src.chainDone or 0, src.chainTotal) end
		return concat(parts, DOT)
	elseif src.kind == "dungeon" then
		return format("%s: %s%s", src.raid and "Raid" or "Dungeon", src.name or "?", src.npcName and (DOT .. src.npcName) or "")
	elseif src.kind == "rare" then
		local what = src.rare and "Rare" or "Elite"
		return format("%s: %s%s", what, src.name or "?", src.level and format(" (%d)", src.level) or "")
	elseif src.kind == "vendor" then
		return format("Vendor: %s", src.name or "?")
	end
	return ""
end

local function markedIds()
	local _, g = db()
	local out = {}
	for id, on in pairs(g.marked) do
		if on then out[#out + 1] = id end
	end
	table.sort(out)
	return out
end

-- The slot's list as shown: the sources the sidebar keeps, in the header's order.
-- The slot's list as shown; with Marked only (all = true), every marked item
-- of every slot, each with the slot it is for.
local function rankedList(slot, all)
	local _, g = db()
	local out, seen = {}, {}
	local slotList = all and FQG.SLOTS or { slot }
	for _, s in ipairs(slotList) do
		for _, res in ipairs(FQG.Results(s) or {}) do
			if not seen[res.id] and (not (all or g.markedOnly) or g.marked[res.id]) then
				local tier, steps, best = FQG.Rank(res, keepSource)
				if tier then
					seen[res.id] = true
					out[#out + 1] = { res = res, tier = tier, steps = steps, best = best, slot = s,
						gain = res.pct or (res.empty and 1e6) or 0, name = lower(FQB.ItemName(res.id) or "") }
				end
			end
		end
	end
	local key, desc = g.sort.key, g.sort.desc
	local function cmp(a, b)
		local va, vb
		if key == "rec" then
			if a.tier ~= b.tier then return a.tier < b.tier end
			va, vb = -a.gain, -b.gain
		elseif key == "gain" then
			va, vb = -a.gain, -b.gain
		elseif key == "closest" then
			if a.steps ~= b.steps then va, vb = a.steps, b.steps else va, vb = -a.gain, -b.gain end
		elseif key == "level" then
			va, vb = a.res.req or 0, b.res.req or 0
		else
			va, vb = a.name, b.name
		end
		if va ~= vb then
			if desc then return va > vb end
			return va < vb
		end
		return a.res.id < b.res.id
	end
	table.sort(out, cmp)
	return out
end

local function setNote(text, color)
	if not tool then return end
	tool.Note:SetText(text or "")
	W.Color(tool.Note, color or "warning")
end

function GV.ToggleMark(id)
	local _, g = db()
	g.marked[id] = (not g.marked[id]) and true or nil
	FQB.Changed()
end

function GV.Start(items)
	items = items or markedIds()
	if #items == 0 then
		setNote("Star the upgrades you want, then Gear guide.")
		return
	end
	local gid, msg = FQB.StartGuide({}, items)
	if not gid then setNote(msg) end
end

-- Shared with the item page (GearItem.lua).
GV.db, GV.QualityColor, GV.GainText, GV.SlotName, GV.ItemInfo = db, qualityColor, gainText, slotName, itemInfo
GV.SourceText, GV.KeepSource, GV.MarkedIds = sourceText, keepSource, markedIds

---------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------

local function bestOf(slot)
	local listed = rankedList(slot)
	local best
	for _, e in ipairs(listed) do
		if not best or e.tier < best.tier or (e.tier == best.tier and e.gain > best.gain) then best = e end
	end
	return best
end

local function slotTip(self)
	local slot = self.psSlot
	if not GameTooltip then return end
	GameTooltip:SetOwner(self, self.psRight and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
	if GetInventoryItemLink("player", slot) then
		GameTooltip:SetInventoryItem("player", slot)
	else
		GameTooltip:SetText(slotName(slot), 1, 1, 1)
		GameTooltip:AddLine("Empty", 0.6, 0.6, 0.6)
	end
	local best = bestOf(slot)
	if best then
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(format("Upgrade: %s (%s, %s)", FQB.ItemName(best.res.id) or ("Item " .. best.res.id),
			gainText(best.res), best.best and best.best.todo or ""), 0.37, 0.82, 0.41, true)
	end
	GameTooltip:Show()
end

local function makeSlot(slot, right)
	local b = CreateFrame("Button", nil, root)
	b:SetSize(SLOT_SIZE, SLOT_SIZE)
	b.psSlot, b.psRight = slot, right
	W.Fill(b, "panel")
	b.Icon = b:CreateTexture(nil, "ARTWORK")
	b.Icon:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
	b.Icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
	b.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	W.Hover(b)
	-- The frame: the item's quality, the selected slot in the accent.
	b.Edge = {}
	for i, spec in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, 2 }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, 2 }, { "TOPLEFT", "BOTTOMLEFT", 2, nil }, { "TOPRIGHT", "BOTTOMRIGHT", 2, nil } }) do
		local t = b:CreateTexture(nil, "OVERLAY")
		t:SetTexture(Theme.Media("white"))
		t:SetPoint(spec[1], b, spec[1], 0, 0)
		t:SetPoint(spec[2], b, spec[2], 0, 0)
		if spec[3] then t:SetWidth(spec[3]) end
		if spec[4] then t:SetHeight(spec[4]) end
		b.Edge[i] = t
	end
	-- An upgrade under way or ready now: a dot in the corner.
	b.Dot = b:CreateTexture(nil, "OVERLAY", nil, 2)
	b.Dot:SetTexture(Theme.Media("circle"))
	b.Dot:SetSize(10, 10)
	b.Dot:SetPoint("TOPRIGHT", b, "TOPRIGHT", 3, 3)
	W.Color(b.Dot, "success")
	b:SetScript("OnClick", function(self)
		local _, g = db()
		g.slot = self.psSlot
		GV.item = nil -- another slot: back to its list
		GV.Paint()
	end)
	b:SetScript("OnEnter", slotTip)
	b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
	slots[slot] = b
	return b
end

local function paintSlot(b, selected)
	local slot = b.psSlot
	local worn = GetInventoryItemTexture and GetInventoryItemTexture("player", slot)
	local tex = worn
	if not tex and GetInventorySlotInfo then
		local _, empty = GetInventorySlotInfo(SLOT_KEY[slot])
		tex = empty
	end
	b.Icon:SetTexture(tex)
	b.Icon:SetDesaturated(not worn)
	local r, g, bl, a
	if selected then
		r, g, bl = Theme.Color("accent")
		a = 1
	else
		local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
		local _, quality = itemInfo(link)
		if link and quality then
			r, g, bl = qualityColor(quality)
			a = 0.8
		else
			r, g, bl, a = 0.4, 0.4, 0.4, 0.5
		end
	end
	for _, t in ipairs(b.Edge) do t:SetVertexColor(r, g, bl, a) end
	local best = bestOf(slot)
	b.Dot:SetShown(best ~= nil and best.tier <= 2)
	if best then W.Color(b.Dot, TIER_COLOR[best.tier] or "success") end
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

local function rowMenu(r)
	local id = r.psItem
	if not (id and W.ShowMenu) then return end
	local _, g = db()
	W.ShowMenu(r, {
		{ text = g.marked[id] and "Unmark" or "Mark", icon = "star", onClick = function() GV.ToggleMark(id) end },
		{ text = "Guide to this item", icon = "icon-goto", onClick = function() GV.Start({ id }) end },
		{ text = "Show in Lookup", icon = "search", onClick = function()
			if P.Lookup and P.Lookup.Show then P.Lookup.Show(nil, "item", id) end
		end },
	}, { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = 40, y = 0 })
end

local function row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, list.Child)
	r:SetHeight(ROW_H)
	r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	W.Hover(r)
	r.Tier = r:CreateTexture(nil, "ARTWORK")
	r.Tier:SetTexture(Theme.Media("white"))
	r.Tier:SetWidth(2)
	r.Tier:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -4)
	r.Tier:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 4)
	r.Star = W.IconButton(r, "star", 20, "Mark: Gear guide takes the marked items.", function(self)
		local id = self:GetParent().psItem
		if id then GV.ToggleMark(id) end
	end)
	r.Star:SetPoint("LEFT", r, "LEFT", 6, 0)
	-- The icon: no tooltip in the list (the item page compares), but its
	-- modified clicks (link, dressing room) still work.
	r.Item = FQB.ItemButton(r, 28)
	r.Item:SetPoint("LEFT", r.Star, "RIGHT", 4, 0)
	r.Item:SetScript("OnEnter", nil)
	r.Item:SetScript("OnLeave", nil)
	r.Item:SetScript("OnClick", function(self)
		if self.psItem and not W.ItemClick(self.psItem) then GV.OpenItem(self.psItem, self:GetParent().psSlot) end
	end)
	-- The columns under the header: Closest, Lvl, Gain.
	r.Gain = W.Text(r, "body", "success")
	r.Gain:SetJustifyH("RIGHT")
	r.Gain:SetWidth(COL_GAIN)
	r.Gain:SetPoint("RIGHT", r, "RIGHT", -6, 0)
	r.Level = W.Text(r, "body", "textDim")
	r.Level:SetJustifyH("CENTER")
	r.Level:SetWidth(COL_LVL)
	r.Level:SetPoint("RIGHT", r.Gain, "LEFT", -COL_GAP, 0)
	r.Todo = W.Text(r, "small", "textDim")
	r.Todo:SetJustifyH("RIGHT")
	r.Todo:SetWidth(COL_TODO)
	r.Todo:SetPoint("RIGHT", r.Level, "LEFT", -COL_GAP, 0)
	r.Name = W.Text(r, "body", "text")
	r.Name:SetPoint("TOPLEFT", r.Item, "TOPRIGHT", 8, 0)
	r.Name:SetPoint("RIGHT", r.Todo, "LEFT", -8, 0)
	r.Source = W.Text(r, "small", "textDim")
	r.Source:SetPoint("BOTTOMLEFT", r.Item, "BOTTOMRIGHT", 8, 0)
	r.Source:SetPoint("RIGHT", r.Todo, "LEFT", -8, 0)
	r:SetScript("OnClick", function(self, button)
		if button == "RightButton" then
			rowMenu(self)
		elseif self.psItem then
			GV.OpenItem(self.psItem, self.psSlot)
		end
	end)
	rows[i] = r
	return r
end

local function paintRow(r, e, g, plevel)
	local res = e.res
	r.psItem = res.id
	FQB.SetItem(r.Item, res.id)
	r.Item.psItem = res.id
	W.SetIconState(r.Star, g.marked[res.id] and true or false)
	W.Color(r.Tier, TIER_COLOR[e.tier] or "textMuted")
	r.Name:SetText(FQB.ItemName(res.id) or ("Item " .. res.id))
	W.Uncolor(r.Name)
	r.Name:SetTextColor(qualityColor(res.quality))
	local srcs = shownSources(res)
	local text = e.best and sourceText(e.best) or ""
	if #srcs > 1 then text = text .. format("  |cff999999(+%d more)|r", #srcs - 1) end
	-- Marked only lists every slot's: which slot it is for, first.
	if g.markedOnly and e.slot then text = "|cffc2b9a9" .. slotName(e.slot) .. "|r" .. DOT .. text end
	r.Source:SetText(text)
	r.psSlot = e.slot
	r.Gain:SetText(gainText(res, true))
	r.Level:SetText(res.req and res.req > 0 and tostring(res.req) or "")
	W.Color(r.Level, FQB.LevelColor and FQB.LevelColor(res.req, plevel) or "textDim")
	if res.wearNow then
		W.Color(r.Gain, "success")
		r.Todo:SetText(e.best and e.best.todo or "")
		W.Color(r.Todo, e.tier == 1 and "accent" or "textDim")
	else
		W.Color(r.Gain, "warning")
		r.Todo:SetText(format("at level %d", res.req or (plevel + 1)))
		W.Color(r.Todo, "warning")
	end
	r:Show()
end

local function paintCard(slot)
	local link = GetInventoryItemLink and GetInventoryItemLink("player", slot)
	card.Slot:SetText(slotName(slot))
	if link then
		local name, quality, ilvl, req = itemInfo(link)
		card.Icon:SetTexture(GetInventoryItemTexture("player", slot))
		card.Icon:SetDesaturated(false)
		card.Name:SetText(name or link)
		W.Uncolor(card.Name)
		card.Name:SetTextColor(qualityColor(quality))
		local sub = {}
		if ilvl and ilvl > 0 then sub[#sub + 1] = "Item level " .. ilvl end
		if req and req > 0 then sub[#sub + 1] = "Requires level " .. req end
		card.Sub:SetText(concat(sub, DOT))
	else
		local _, empty = GetInventorySlotInfo and GetInventorySlotInfo(SLOT_KEY[slot])
		card.Icon:SetTexture(empty)
		card.Icon:SetDesaturated(true)
		card.Name:SetText("Nothing worn")
		W.Color(card.Name, "textDim")
		card.Sub:SetText("Anything below fills the slot.")
	end
	local G = P.Gear
	local scored = G and G.ScoredFor and G.ScoredFor(true)
	card.Scored:SetText(scored or "")
end

local function paintHeader()
	local _, g = db()
	for _, col in ipairs(header.Cols) do
		local on = g.sort.key == col.psKey
		W.Color(col.Label, on and "accent" or "textMuted")
		col.Arrow:SetShown(on)
		if on then col.Arrow:SetTexture(Theme.Media(g.sort.desc and "chevron-up" or "chevron-down")) end
	end
end

local function paintList(slot)
	local _, g = db()
	local plevel = FQB.PlayerLevel()
	local st, why = FQG.State()
	local n = 0
	if st == "ready" then
		for _, e in ipairs(rankedList(slot, g.markedOnly)) do
			if n >= MAX_ROWS then break end
			n = n + 1
			local r = row(n)
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", list.Child, "TOPLEFT", 0, -(n - 1) * (ROW_H + 2))
			r:SetPoint("TOPRIGHT", list.Child, "TOPRIGHT", 0, -(n - 1) * (ROW_H + 2))
			paintRow(r, e, g, plevel)
		end
	end
	for i = n + 1, #rows do rows[i]:Hide() end
	local w = list:GetWidth()
	if w and w > 0 then list.Child:SetWidth(w - 10) end
	W.SetScrollContent(list, n * (ROW_H + 2) + 8)
	local text
	if st == "failed" then
		text = (why == "missing") and "Gear needs Polestar's gear advice and Lookup data (Polestar_ItemDB, Polestar_Codex)."
			or (why == "itemdb") and "Gear needs Polestar's item data (the Polestar_ItemDB addon). Turn it on in the addon list."
			or ("Gear could not be read (" .. tostring(why) .. ").")
	elseif st == "waiting" then
		text = "Polestar's item data loads after combat."
	elseif st ~= "ready" or FQG.Scoring() and n == 0 then
		text = "Weighing every item you could wear..."
	elseif n == 0 then
		text = g.markedOnly and "No marked upgrades for this slot."
			or "No upgrades within reach for this slot. Raise Quests above your level on the Quests tab, or turn on more sources in the sidebar."
	end
	message:SetText(text or "")
	message:SetShown(text ~= nil)
end

local function reachText()
	local w = FQG.Window()
	if not w then return "Sources at any level (Quests above your level)" end
	if w == 0 then return "Sources up to your level (Quests above your level)" end
	return format("Sources up to +%d levels (Quests above your level)", w)
end

-- The item page (GearItem.lua) in place of the list, or the list.
-- slot: the slot it is for (Marked only lists every slot's); the page
-- compares against that slot's piece, so the slot follows.
function GV.OpenItem(id, slot)
	if slot then
		local _, g = db()
		g.slot = slot
	end
	GV.item = id
	GV.Paint()
end

-- Leave for another hub section (the Quests list, a dungeon's page), keeping
-- the way back: a "Back to Gear" button shows there until it is used or the
-- player comes back another way.
function GV.Jump(fn)
	local _, g = db()
	GV.returnTo = { item = GV.item, slot = g.slot }
	fn()
	if GV.UpdateBack then GV.UpdateBack() end
end

function GV.GoBack()
	local back = GV.returnTo
	GV.returnTo = nil
	if back then
		local _, g = db()
		g.slot = back.slot or g.slot
		GV.item = back.item
	end
	GV.Show()
	if GV.UpdateBack then GV.UpdateBack() end
end

function GV.CloseItem()
	GV.item = nil
	GV.Paint()
end

function GV.Paint()
	if not root then return end
	local _, g = db()
	for slot, b in pairs(slots) do paintSlot(b, slot == g.slot) end
	paintCard(g.slot)
	local GI = FQB.GearItem
	local onItem = GV.item ~= nil and GI ~= nil and GV.page ~= nil
	header:SetShown(not onItem)
	list:SetShown(not onItem)
	if GV.page then GV.page:SetShown(onItem) end
	if onItem then
		message:Hide()
		GI.Paint(GV.item, g.slot)
	else
		paintHeader()
		paintList(g.slot)
	end
	local n = #markedIds()
	W.SetButtonText(tool.Start, n > 0 and format("Gear guide (%d)", n) or "Gear guide")
	tool.Reach:SetText(reachText())
end

---------------------------------------------------------------------------
-- The section
---------------------------------------------------------------------------

local function sortBy(key)
	local _, g = db()
	if g.sort.key == key then
		g.sort.desc = not g.sort.desc
	else
		g.sort.key, g.sort.desc = key, false
	end
	if list then W.ScrollTo(list, 0) end
	GV.Paint()
end

local function headerCol(text, key, tip, width)
	local c = CreateFrame("Button", nil, header)
	c:SetHeight(HEAD_H)
	c:SetWidth(width)
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

local function leftCol(c, anchor)
	if anchor then c:SetPoint("LEFT", anchor, "RIGHT", 6, 0) else c:SetPoint("LEFT", header, "LEFT", 6, 0) end
	c.Label:SetPoint("LEFT", c, "LEFT", 0, 0)
	c.Arrow:SetPoint("LEFT", c.Label, "RIGHT", 3, 0)
end

local function rightCol(c, anchor)
	if anchor then c:SetPoint("RIGHT", anchor, "LEFT", -6, 0) else c:SetPoint("RIGHT", header, "RIGHT", -6, 0) end
	c.Label:SetPoint("RIGHT", c, "RIGHT", 0, 0)
	c.Arrow:SetPoint("RIGHT", c.Label, "LEFT", -3, 0)
end

local function buildHeader()
	header = CreateFrame("Frame", nil, center)
	header:SetHeight(HEAD_H)
	header:SetPoint("TOPLEFT", tool, "BOTTOMLEFT", 0, -2)
	header:SetPoint("TOPRIGHT", tool, "BOTTOMRIGHT", -10, -2)
	header.Cols = {}
	local rule = W.Divider(header)
	rule:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
	rule:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
	local rec = headerCol("Recommended", "rec", "What you are on first (in your log, chain started), then ready now, then soon; each by gain", 100)
	leftCol(rec)
	local item = headerCol("Item", "name", "By name", 50)
	leftCol(item, rec)
	local gain = headerCol("Gain", "gain", "Best upgrade first", COL_GAIN)
	rightCol(gain)
	local lvl = headerCol("Lvl", "level", "By the level it needs", COL_LVL)
	lvl:SetPoint("RIGHT", gain, "LEFT", -COL_GAP, 0)
	lvl.Label:SetPoint("CENTER", lvl, "CENTER", 0, 0)
	lvl.Arrow:SetPoint("RIGHT", lvl.Label, "LEFT", -2, 0)
	local closest = headerCol("Closest", "closest", "Fewest steps first: quests left in its chain, a rare, a dungeon", COL_TODO)
	rightCol(closest, lvl)
end

function GV.Build(parent, shell)
	if root then return root end
	hub = shell
	root = CreateFrame("Frame", nil, parent)
	root:SetAllPoints(parent)

	-- The columns: left from the top, right from the top, weapons at the foot.
	local top = -10
	for i, slot in ipairs(LEFT) do
		local b = makeSlot(slot, false)
		b:SetPoint("TOPLEFT", root, "TOPLEFT", SIDE, top - (i - 1) * (SLOT_SIZE + SLOT_GAP))
	end
	for i, slot in ipairs(RIGHT) do
		local b = makeSlot(slot, true)
		b:SetPoint("TOPRIGHT", root, "TOPRIGHT", -SIDE, top - (i - 1) * (SLOT_SIZE + SLOT_GAP))
	end
	local footW = #FOOT * SLOT_SIZE + (#FOOT - 1) * SLOT_GAP * 2
	for i, slot in ipairs(FOOT) do
		local b = makeSlot(slot, false)
		b:SetPoint("BOTTOMLEFT", root, "BOTTOM", -footW / 2 + (i - 1) * (SLOT_SIZE + SLOT_GAP * 2), 10)
	end

	-- Between the columns: the slot's card, the tools, the upgrades.
	center = CreateFrame("Frame", nil, root)
	center:SetPoint("TOPLEFT", root, "TOPLEFT", SIDE + SLOT_SIZE + 14, top)
	center:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -(SIDE + SLOT_SIZE + 14), SLOT_SIZE + 20)

	card = CreateFrame("Frame", nil, center)
	card:SetPoint("TOPLEFT", center, "TOPLEFT", 0, 0)
	card:SetPoint("TOPRIGHT", center, "TOPRIGHT", 0, 0)
	card:SetHeight(CARD_H)
	W.Fill(card, "panel")
	card.Icon = card:CreateTexture(nil, "ARTWORK")
	card.Icon:SetSize(40, 40)
	card.Icon:SetPoint("LEFT", card, "LEFT", 10, 0)
	card.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	card.Slot = W.Text(card, "small", "textMuted")
	card.Slot:SetPoint("TOPLEFT", card.Icon, "TOPRIGHT", 10, 0)
	card.Scored = W.Text(card, "small", "textDim")
	card.Scored:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -9)
	card.Scored:SetJustifyH("RIGHT")
	card.Name = W.Text(card, "body", "text")
	card.Name:SetPoint("LEFT", card.Icon, "RIGHT", 10, 0)
	card.Name:SetPoint("RIGHT", card, "RIGHT", -10, 0)
	card.Sub = W.Text(card, "small", "textDim")
	card.Sub:SetPoint("BOTTOMLEFT", card.Icon, "BOTTOMRIGHT", 10, 0)
	card.Sub:SetPoint("RIGHT", card, "RIGHT", -10, 0)
	local hover = CreateFrame("Frame", nil, card)
	hover:SetAllPoints(card.Icon)
	hover:SetScript("OnEnter", function(self)
		local _, g = db()
		if GameTooltip and GetInventoryItemLink("player", g.slot) then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetInventoryItem("player", g.slot)
			GameTooltip:Show()
		end
	end)
	hover:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)

	tool = CreateFrame("Frame", nil, center)
	tool:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 0, -4)
	tool:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", 0, -4)
	tool:SetHeight(TOOL_H)
	tool.Start = W.Button(tool, "Gear guide", function() GV.Start() end, { height = 28, primary = true, icon = "icon-goto" })
	tool.Start:SetPoint("RIGHT", tool, "RIGHT", 0, 0)
	tool.Start.psTip = "One guide to every marked item: quest chains first, then dungeons, rares and vendors."
	tool.Start:HookScript("OnEnter", W.SimpleTip)
	tool.Start:HookScript("OnLeave", W.HideTip)
	tool.Reach = W.Text(tool, "small", "textDim")
	tool.Reach:SetPoint("LEFT", tool, "LEFT", 6, 0)
	tool.Reach:SetPoint("RIGHT", tool.Start, "LEFT", -10, 0)
	tool.Note = W.Text(center, "small", "warning")
	tool.Note:SetJustifyH("RIGHT")

	buildHeader()
	tool.Note:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -2)

	list = W.Scroll(center)
	list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
	list:SetPoint("BOTTOMRIGHT", center, "BOTTOMRIGHT", 0, 0)
	list:HookScript("OnSizeChanged", function(self, w)
		if w and w > 0 then self.Child:SetWidth(w - 10) end
	end)

	message = W.Text(center, "note", "textMuted")
	message:SetPoint("TOP", list, "TOP", 0, -30)
	message:SetWidth(300)
	message:SetWordWrap(true)
	message:SetJustifyH("CENTER")

	-- The item page, where the header and list are.
	if FQB.GearItem then
		GV.page = FQB.GearItem.Build(center, tool)
		GV.page:Hide()
	end

	-- Esc on the item page: back to the list; every other key goes on.
	if root.EnableKeyboard and root.SetPropagateKeyboardInput then
		local function propagate(on)
			if InCombatLockdown and InCombatLockdown() then return end
			pcall(root.SetPropagateKeyboardInput, root, on)
		end
		root:EnableKeyboard(true)
		propagate(true)
		root:SetScript("OnKeyDown", function(_, key)
			if key == "ESCAPE" and GV.item then
				propagate(false)
				GV.CloseItem()
				C_Timer.After(0, function() propagate(true) end)
			end
		end)
	end

	-- Off: everything under a veil that takes the clicks, the banner over it
	-- saying why, with the way to turn it on.
	shield = CreateFrame("Frame", nil, root)
	shield:SetAllPoints(root)
	shield:SetFrameLevel(root:GetFrameLevel() + 40)
	shield:EnableMouse(true)
	shield:Hide()
	banner = CreateFrame("Frame", nil, root)
	banner:SetPoint("TOPLEFT", center, "TOPLEFT", 0, 0)
	banner:SetPoint("TOPRIGHT", center, "TOPRIGHT", 0, 0)
	banner:SetHeight(112)
	banner:SetFrameLevel(root:GetFrameLevel() + 50)
	banner:EnableMouse(true)
	W.Fill(banner, "panel")
	local bar = banner:CreateTexture(nil, "ARTWORK")
	bar:SetTexture(Theme.Media("white"))
	bar:SetWidth(3)
	bar:SetPoint("TOPLEFT", banner, "TOPLEFT", 0, 0)
	bar:SetPoint("BOTTOMLEFT", banner, "BOTTOMLEFT", 0, 0)
	W.Color(bar, "warning")
	banner.Icon = W.Tex(banner, "ARTWORK", "info", "warning")
	banner.Icon:SetSize(16, 16)
	banner.Icon:SetPoint("TOPLEFT", banner, "TOPLEFT", 14, -14)
	banner.Title = W.Text(banner, "body", "warning")
	banner.Title:SetPoint("LEFT", banner.Icon, "RIGHT", 8, 0)
	banner.Title:SetText("The gear planner is off")
	banner.Text = W.Text(banner, "small", "text")
	banner.Text:SetWordWrap(true)
	banner.Text:SetJustifyH("LEFT")
	banner.Text:SetJustifyV("TOP")
	banner.Text:SetPoint("TOPLEFT", banner.Icon, "BOTTOMLEFT", 0, -8)
	banner.Text:SetPoint("RIGHT", banner, "RIGHT", -14, 0)
	banner.Fix = W.Button(banner, "Turn on", function()
		if banner.psAction then banner.psAction() end
		repaint()
	end, { height = 26, primary = true })
	banner.Fix:SetPoint("BOTTOMLEFT", banner, "BOTTOMLEFT", 14, 12)
	banner.Fix:HookScript("OnEnter", W.SimpleTip)
	banner.Fix:HookScript("OnLeave", W.HideTip)
	banner:Hide()
	return root
end

-- Greyed out and veiled while something stops the planner; the banner says what.
local function paintBlock(b)
	local off = b ~= nil
	local alpha = off and 0.35 or 1
	for _, s in pairs(slots) do s:SetAlpha(alpha) end
	center:SetAlpha(alpha)
	shield:SetShown(off)
	banner:SetShown(off)
	if not off then return end
	banner.Text:SetText(b.text)
	banner.psAction = b.action
	banner.Fix:SetShown(b.button ~= nil)
	if b.button then
		W.SetButtonText(banner.Fix, b.button)
		banner.Fix.psTip = b.tip
	end
end

function GV.Render()
	if not root then return end
	local plevel = FQB.PlayerLevel()
	if hub and W.ShellTitle then
		local cls = (UnitClass and UnitClass("player")) or ""
		W.ShellTitle(hub, "Gear", format("Level %d %s%sUpgrades from quests, dungeons and rares", plevel, cls, DOT))
	end
	local b = blocker()
	paintBlock(b)
	local st = FQG.State()
	-- Built on the next frame: never from inside the hub's own render, and
	-- never while something it needs is off.
	if b then
		GV.wasBlocked = true
	else
		if st == "idle" then
			C_Timer.After(0, function() FQG.Build() end)
		elseif st == "failed" and GV.wasBlocked then
			-- Turned on since: one more try (not on every repaint).
			C_Timer.After(0, function() FQG.Retry() end)
		end
		GV.wasBlocked = nil
	end
	GV.Paint()
	if b then
		-- The list's own note would only repeat the banner.
		message:Hide()
	end
end

-- The sidebar: the sources (ticked: listed), then Marked only.
function GV.Nav()
	local _, g = db()
	local items = {}
	local counts = {}
	for _, res in ipairs(FQG.Results(g.slot) or {}) do
		local kinds = {}
		for _, src in ipairs(res.sources or {}) do kinds[src.kind] = true end
		for k in pairs(kinds) do counts[k] = (counts[k] or 0) + 1 end
	end
	for _, s in ipairs(SOURCES) do
		local on = g.sources[s.key] and true or false
		items[#items + 1] = { key = s.key, label = (on and ON or OFF) .. s.label, icon = s.icon, count = counts[s.key] }
	end
	items[#items + 1] = { key = "marked", label = (g.markedOnly and ON or OFF) .. "Marked only", icon = "star", count = #markedIds() }
	return items, nil
end

function GV.OnNav(key)
	local _, g = db()
	if key == "marked" then
		g.markedOnly = not g.markedOnly
	else
		g.sources[key] = not g.sources[key]
	end
	repaint()
end

function GV.Show()
	if UI.ShowPicker then UI.ShowPicker() end
	local Pk = UI.Picker
	if Pk and Pk.ShowSection then Pk.ShowSection(KEY) end
end
FQ.ShowGear = GV.Show

FQB.Listen(function()
	if root and root:IsVisible() then repaint() end
end)

-- Gear advice turned on or off in Polestar's Options: the banner follows.
if P.On then
	P.On("SETTING_CHANGED", function(path)
		if path == "gear.enabled" or path == "gear" or path == "qol.questLevelWindow" or path == "" or path == nil then
			if root and root:IsVisible() then repaint() end
		end
	end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
events:SetScript("OnEvent", function()
	if root and root:IsVisible() then GV.Paint() end
end)

-- Item tooltips: a marked upgrade says so.
local Hooks = P.Hooks
if Hooks and Hooks.ItemLines then
	Hooks.ItemLines("Polestar_FreeQuest_Gear", function(tooltip, _, itemID)
		if not itemID then return end
		local _, g = db()
		if not g.marked[itemID] then return end
		local text = "|TInterface\\AddOns\\Polestar\\Media\\UI\\star:12|t Marked upgrade (Gear: Gear guide)"
		if Hooks.AddLine then Hooks.AddLine(tooltip, text, nil, 1, 0.82, 0) else tooltip:AddLine(text, 1, 0.82, 0) end
	end)
end

-- "Back to Gear" on the hub while another section shows what the Gear page
-- sent the player to (GV.Jump); gone once used, once back on Gear, or when
-- the hub closes.
local backBtn
function GV.UpdateBack()
	local Pk = UI.Picker
	local win = Pk and Pk.frame
	if not win then return end
	if Pk.Section and Pk.Section() == KEY then GV.returnTo = nil end
	local want = GV.returnTo ~= nil and win:IsShown()
	if want and not backBtn then
		backBtn = W.Button(win, "Back to Gear", function() GV.GoBack() end, { height = 28, icon = "chevron-left" })
		backBtn:SetPoint("BOTTOMRIGHT", win.Header or win, "BOTTOMRIGHT", -SH.pad, 14)
		backBtn:SetFrameLevel(win:GetFrameLevel() + 30)
		backBtn.psTip = "Back to the Gear page you came from."
		backBtn:HookScript("OnEnter", W.SimpleTip)
		backBtn:HookScript("OnLeave", W.HideTip)
		win:HookScript("OnHide", function()
			GV.returnTo = nil
			if backBtn then backBtn:Hide() end
		end)
	end
	if backBtn then backBtn:SetShown(want) end
end
if UI.Picker and type(UI.Picker.Render) == "function" and hooksecurefunc then
	hooksecurefunc(UI.Picker, "Render", function() pcall(GV.UpdateBack) end)
end

UI.RegisterSection({
	key = KEY, label = "Gear", icon = "icon-kill", order = 26,
	build = GV.Build, render = GV.Render,
	nav = GV.Nav, onNav = GV.OnNav,
})
