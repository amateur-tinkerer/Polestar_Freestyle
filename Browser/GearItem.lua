-- Polestar Freestyle: the Gear section's item page.
--
-- Clicking an upgrade in the Gear list opens this page in the list's place
-- (Back, Esc or another slot returns): the item, what it changes against the
-- piece worn in the slot you picked, then where it comes from, as Lookup's
-- pages tell it:
--   quest    the quest's whole chain up to the reward, each quest's state,
--            level and giver; Guide this chain, Show in Quests, Lookup
--   dungeon  what it takes (level, attunements and keys, the dungeon's
--            quests for you, an entrance in enemy land); Polestar's own
--            attunement or quest pick-up guide, its dungeon page, Lookup
--   rare     who and where; Lookup's guide to it
--   vendor   who, where and the price; Lookup's guide to it
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
local FQB = FQ and FQ.Browser
local FQG = FQB and FQB.Gear
local GV = FQB and FQB.GearSection
local UI, W, Theme = P and P.UI, P and P.Widgets, P and P.Theme
if not (FQG and GV and UI and W and Theme) then return end

local C = P.Compat
local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local format, concat = string.format, table.concat

local GI = {}
FQB.GearItem = GI

local DOT = "  \194\183  "
local PAD = 10
local LINE = 18
local CHAIN_MAX = 10

local page, scroll, content
local note

---------------------------------------------------------------------------
-- Pooled pieces, laid out top to bottom each paint
---------------------------------------------------------------------------

local pools, used = {}, {}

local function take(kind, make)
	local list = pools[kind]
	if not list then
		list = {}
		pools[kind] = list
	end
	local n = (used[kind] or 0) + 1
	used[kind] = n
	local obj = list[n]
	if not obj then
		obj = make()
		list[n] = obj
	end
	obj:ClearAllPoints()
	obj:Show()
	return obj
end

local function reset()
	for kind, list in pairs(pools) do
		for i = 1, #list do list[i]:Hide() end
		used[kind] = 0
	end
end

local function text(role, color)
	local fs = take("text:" .. role, function()
		local t = W.Text(content, role, color)
		t:SetJustifyH("LEFT")
		return t
	end)
	-- A pooled line may come back right-aligned from its last use (the chain
	-- rows' level and giver columns): left unless the caller says otherwise.
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	fs:SetWidth(0)
	W.Color(fs, color or "text")
	return fs
end

local function glyph(name, color)
	local t = take("tex", function() return content:CreateTexture(nil, "ARTWORK") end)
	t:SetTexture(Theme.Media(name))
	t:SetSize(12, 12)
	W.Color(t, color or "text")
	return t
end

local function rule()
	return take("rule", function() return W.Divider(content) end)
end

local function button(label, fn, primary, icon)
	local kind = primary and "btn:primary" or "btn:ghost"
	local b = take(kind, function()
		local nb = W.Button(content, label, function(self) if self.psFn then self.psFn() end end,
			{ height = 26, primary = primary or nil, ghost = not primary or nil })
		return nb
	end)
	W.SetButtonText(b, label)
	b.psFn = fn
	return b
end

local function itemIcon()
	return take("item", function() return FQB.ItemButton(content, 40) end)
end

-- A row of buttons from x = PAD at y; -> the height it took.
local function buttons(y, list)
	local x = PAD
	for _, spec in ipairs(list) do
		if spec then
			local b = button(spec[1], spec[2], spec[3])
			b:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
			x = x + b:GetWidth() + 8
		end
	end
	return 34
end

local function setNote(msg, color)
	note:SetText(msg or "")
	W.Color(note, color or "warning")
end

-- After a guide opens: the hub steps aside, as Lookup's guides do.
local function opened(gid, reason)
	if gid then
		if P.Set then pcall(P.Set, "ui.shown", true) end
		local Pk = UI.Picker
		if Pk and Pk.frame and Pk.frame.Hide then Pk.frame:Hide() end
		if P.Fire then P.Fire("SHOW_FRAME") end
		return
	end
	local msgs = {
		tabs = "Six guide tabs is the limit. Close one, then try again.",
		disabled = "Polestar's Lookup is turned off (Options > Discovery > Lookup).",
		off = "Polestar's Dungeons is turned off (Options).",
		nothing = "Nothing left to do for it.",
		done = "Already done.",
		login = "Log in first.",
		combat = "Polestar's data loads after combat. Try again in a moment.",
	}
	setNote(msgs[reason] or format("No guide could be made (%s).", tostring(reason or "no source")))
end

-- To another hub section, with "Back to Gear" there (Gear.lua's GV.Jump).
local function showLookup(kind, id)
	if not (P.Lookup and P.Lookup.Show) then return end
	GV.Jump(function() P.Lookup.Show(nil, kind, id) end)
end

-- The quest in the Quests list, with the reward this page is about lit there.
local function showQuest(qid, item)
	local QS = FQB.Section
	if not (QS and QS.Reveal) then return end
	GV.Jump(function() QS.Reveal({ qid }, { item = item }) end)
end

-- Polestar's page for a dungeon. Its page forgets the dungeon when the hub's
-- search is cleared on the way in, so it is opened again on the next frame
-- when it did not stay.
local function showDungeon(key)
	local D = P.Dungeons
	if not (D and D.Open) then return end
	GV.Jump(function()
		if not D.Open(key) then
			setNote("Polestar's Dungeons is turned off (Options > Discovery > Lookup).")
			return
		end
		C_Timer.After(0, function()
			local DS = UI.DungeonsSection
			if DS and DS.Page and DS.Open and DS.Page() ~= key then DS.Open(key) end
		end)
	end)
end

---------------------------------------------------------------------------
-- What it changes
---------------------------------------------------------------------------

local STAT_FALLBACK = {
	str = "Strength", agi = "Agility", sta = "Stamina", int = "Intellect", spi = "Spirit", armor = "Armor",
	health = "Health", mana = "Mana", ap = "Attack power", rap = "Ranged attack power", sp = "Spell damage",
	heal = "Healing", mp5 = "Mana per 5 sec", hp5 = "Health per 5 sec", crit = "Crit (%)", hit = "Hit (%)",
	spellCrit = "Spell crit (%)", spellHit = "Spell hit (%)", defense = "Defense", dodge = "Dodge (%)",
	parry = "Parry (%)", block = "Block (%)", blockValue = "Block value",
	dps = "Weapon DPS", ohDps = "Off hand DPS", rdps = "Ranged DPS",
}
local DECIMAL = { dps = true, ohDps = true, rdps = true, crit = true, hit = true, spellCrit = true, spellHit = true,
	dodge = true, parry = true, block = true, haste = true, expertise = true, armorPen = true }

local paintSlot -- the slot the page compares in (GI.Paint)

local function statName(k)
	-- A wand or gun's damage is filed as weapon DPS; Polestar's name for it
	-- says "melee", which reads wrong in the ranged slot.
	if k == "dps" and paintSlot == 18 then return "Weapon DPS" end
	if UI.ScalesStatName then
		local ok, n = pcall(UI.ScalesStatName, k)
		if ok and n then return n end
	end
	return STAT_FALLBACK[k] or k
end

local function statsOf(link)
	local G = P.Gear
	if not (link and G and G.GetItemInfo) then return {} end
	local ok, info = pcall(G.GetItemInfo, link)
	return ok and info and info.stats or {}
end

-- -> { { key, diff }, ... }: weapon damage first, armour last, the rest in
-- Polestar's stat order.
local function statDiff(id, wornLink)
	local new, old = statsOf("item:" .. id), statsOf(wornLink)
	local keys, seen = {}, {}
	local order = (P.Gear and P.Gear.STAT_KEYS) or {}
	local rank = {}
	for i, k in ipairs(order) do rank[k] = i end
	for _, t in ipairs({ new, old }) do
		for k in pairs(t) do
			if not seen[k] then
				seen[k] = true
				local d = (tonumber(new[k]) or 0) - (tonumber(old[k]) or 0)
				if abs(d) >= 0.05 then keys[#keys + 1] = { key = k, diff = d } end
			end
		end
	end
	local function weight(k)
		if k == "dps" or k == "ohDps" or k == "rdps" then return -1 end
		if k == "armor" then return 1e6 end
		return rank[k] or 1000
	end
	table.sort(keys, function(a, b)
		local wa, wb = weight(a.key), weight(b.key)
		if wa ~= wb then return wa < wb end
		return a.key < b.key
	end)
	return keys
end

local function statLine(s)
	local v = DECIMAL[s.key] and format("%.1f", abs(s.diff)) or tostring(floor(abs(s.diff) + 0.5))
	local sign = s.diff > 0 and "+" or "-"
	return format("%s%s %s", sign, v, statName(s.key))
end

---------------------------------------------------------------------------
-- Where it comes from
---------------------------------------------------------------------------

local function sideCode()
	local p = P.Lookup and P.Lookup.PlayerInfo and P.Lookup.PlayerInfo()
	return p and p.code or nil, p
end

local function mapName(map)
	return map and C.MapName and C.MapName(map) or nil
end

-- One quest of the chain, on two lines: its state glyph, level and title,
-- then under the title its giver and zone (side by side they cut each other).
local function chainRow(y, qid, rewardQuest, isNext, plevel, player)
	local st = (FQB.STATUS or {})[FQB.Status(qid)] or { glyph = "circle", color = "quest" }
	local r = FQB.Quest(qid)
	local g = glyph(st.glyph, st.color)
	g:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 4, -(y + 3))
	local lvl = text("small", FQB.LevelColor and FQB.LevelColor(r and r.level, plevel) or "textDim")
	lvl:SetText(r and r.level and tostring(r.level) or "")
	lvl:SetWidth(22)
	lvl:SetJustifyH("RIGHT")
	lvl:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 18, -(y + 2))
	local title = text("body", isNext and "accent" or (FQB.Status(qid) == "done" and "textDim" or "text"))
	local name = (r and r.title) or ("Quest " .. qid)
	if qid == rewardQuest then name = name .. "  |cffffd100(reward)|r" end
	if isNext then name = name .. "  |cff999999next|r" end
	title:SetText(name)
	title:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 46, -y)
	title:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
	-- The giver, from the Codex's quest record.
	local giver = text("small", "textDim")
	local Cx, Lk = P.Codex, P.Lookup
	local cq = Cx and Cx.Quest and Cx.Quest(qid)
	local who
	if cq and Lk and Lk.QuestEnd then
		local ok, e = pcall(Lk.QuestEnd, cq.start, nil, player, true)
		if ok and e then
			local z = e.spawn and mapName(e.spawn.map)
			who = (e.name or "") .. (z and (DOT .. z) or "")
		end
	end
	if not who and cq and cq.start and cq.start.item and cq.start.item[1] then
		who = "Starts from an item"
	end
	if not who then
		giver:SetText("")
		return LINE + 4
	end
	giver:SetText("From " .. who)
	giver:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 46, -(y + LINE - 1))
	giver:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
	return LINE * 2 + 2
end

local function questBlock(y, item, src, plevel)
	local _, player = sideCode()
	local head = text("body", "quest")
	head:SetText(format("%s: %s", src.choice and "Quest reward choice" or "Quest reward", src.name or "?"))
	head:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	y = y + LINE + 2
	local sub = {}
	local zone = mapName(src.zone)
	if zone then sub[#sub + 1] = zone end
	if src.chainTotal then sub[#sub + 1] = format("chain %d of %d done", src.chainDone or 0, src.chainTotal) end
	if src.todo then sub[#sub + 1] = src.todo end
	local s = text("small", "textDim")
	s:SetText(concat(sub, DOT))
	s:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	y = y + LINE + 4
	-- The chain up to the reward quest; the earliest done ones folded.
	local ch = FQB.ChainOf(src.quest)
	local ids = {}
	for _, id in ipairs(ch and ch.quests or { src.quest }) do
		ids[#ids + 1] = id
		if id == src.quest then break end
	end
	local nextId
	for _, id in ipairs(ids) do
		if FQB.Status(id) ~= "done" then nextId = id break end
	end
	local first = 1
	if #ids > CHAIN_MAX then
		first = #ids - CHAIN_MAX + 1
		local folded = 0
		for i = 1, first - 1 do if FQB.Status(ids[i]) == "done" then folded = folded + 1 end end
		local f = text("small", "textMuted")
		f:SetText(format("%d earlier quests (%d done)", first - 1, folded))
		f:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 46, -y)
		y = y + LINE
	end
	for i = first, #ids do
		y = y + chainRow(y, ids[i], src.quest, ids[i] == nextId, plevel, player)
	end
	y = y + 6
	y = y + buttons(y, {
		{ "Guide this chain", function()
			-- StartGuide steps the hub aside itself; its message says why not.
			local gid, msg = FQB.StartGuide({ src.quest })
			if not gid then setNote(msg) end
		end, true },
		{ "Show in Quests", function() showQuest(src.quest, item) end },
		{ "Lookup", function() showLookup("quest", src.quest) end },
	})
	return y
end

-- A check: a glyph and a line.
local function check(y, ok, line, warn)
	local g
	if ok == true then
		g = glyph("check", "success")
	elseif ok == false then
		g = glyph("cross", "danger")
	else
		g = glyph("info", warn and "warning" or "textDim")
	end
	g:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 4, -(y + 3))
	local t = text("small", ok == false and "danger" or (warn and "warning" or "text"))
	t:SetText(line)
	t:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 22, -(y + 2))
	t:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
	return LINE
end

local SHUT = { faction = true, race = true, class = true }

local function dungeonBlock(y, item, src, plevel)
	local D = P.Dungeons
	local key = src.instance
	if D and D.Load then pcall(D.Load) end
	local d = D and D.Get and key and D.Get(key)
	local head = text("body", "quest")
	head:SetText(format("%s: %s", src.raid and "Raid" or "Dungeon", (d and d.name) or src.name or tostring(key)))
	head:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	y = y + LINE + 2
	local sub = {}
	if src.npcName then sub[#sub + 1] = "Dropped by " .. src.npcName end
	if src.chance and src.chance > 0 then sub[#sub + 1] = format("%s%% drop chance", src.chance < 1 and format("%.1f", src.chance) or tostring(floor(src.chance + 0.5))) end
	if d and d.zoneName then sub[#sub + 1] = d.zoneName end
	local s = text("small", "textDim")
	s:SetText(concat(sub, DOT))
	s:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	y = y + LINE + 4

	local side, player = sideCode()
	local attNeeded
	if not d then
		y = y + check(y, nil, "Polestar's Dungeons has no page for it (or Dungeons is turned off).", true)
	else
		-- Level.
		local lo, hi = d.floor or d.minLevel, d.maxLevel
		if lo then
			if plevel >= lo then
				local range = hi and format("Level %d-%d", lo, hi) or format("From level %d", lo)
				y = y + check(y, true, format("%s%syou are %d", range, DOT, plevel))
			else
				y = y + check(y, false, format("From level %d%syou are %d", lo, DOT, plevel))
			end
		end
		-- Attunements and keys.
		if D.Attunements and D.AttunementState then
			for _, a in ipairs(D.Attunements(key, side) or {}) do
				local ok, st = pcall(D.AttunementState, a)
				if ok and st then
					if st.done then
						y = y + check(y, true, format("%s: done", a.name or "Attunement"))
					else
						attNeeded = attNeeded or a
						y = y + check(y, nil, format("%s: %d step%s left", a.name or "Attunement", st.left or 0, (st.left or 0) == 1 and "" or "s"), true)
					end
				end
			end
		end
		-- The dungeon's quests open to this character.
		if D.Quests then
			local n = 0
			local Cx, Lk = P.Codex, P.Lookup
			for _, q in ipairs(D.Quests(key, side) or {}) do
				if not C.IsQuestCompleted(q.id) then
					local cq = Cx and Cx.Quest and Cx.Quest(q.id)
					local why = cq and Lk and Lk.QuestBlock and Lk.QuestBlock(cq, player)
					if not SHUT[why or ""] then n = n + 1 end
				end
			end
			y = y + check(y, nil, n > 0 and format("%d dungeon quest%s you can take for the run", n, n == 1 and "" or "s")
				or "No dungeon quests open to you")
		end
		-- An entrance in the other faction's land.
		local enemy = D.EnemyEntrance and D.EnemyEntrance(key)
		if enemy then y = y + check(y, nil, enemy, true) end
	end
	y = y + 8
	local main
	if attNeeded then
		main = { "Attunement guide", function() opened(D.Attune(key, attNeeded.id)) end, true }
	elseif d and D.PickUp then
		main = { "Dungeon quests guide", function()
			local gid, reason = D.PickUp(key)
			if not gid and (reason == "nothing" or reason == "missing") then
				-- No quests to take: our own guide to the drop.
				gid, reason = FQB.StartGuide({}, { item })
				if not gid then setNote(reason) return end
				return
			end
			opened(gid, reason)
		end, true }
	else
		main = { "Guide me", function()
			local gid, msg = FQB.StartGuide({}, { item })
			if not gid then setNote(msg) end
		end, true }
	end
	y = y + buttons(y, {
		main,
		(d and D.Open) and { "Open dungeon page", function() showDungeon(key) end } or false,
		{ "Lookup", function() showLookup("item", item) end },
	})
	return y
end

local function rareBlock(y, item, src, plevel)
	local Cx = P.Codex
	local npc = Cx and Cx.Npc and Cx.Npc(src.npc)
	local head = text("body", "quest")
	head:SetText(format("%s: %s%s", src.rare and "Rare" or "Elite", src.name or "?", src.level and format(" (%d)", src.level) or ""))
	head:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	y = y + LINE + 2
	local sub = {}
	local spawn = npc and npc.spawns and npc.spawns[1]
	local zone = spawn and mapName(spawn.map)
	if zone then sub[#sub + 1] = zone end
	if src.chance and src.chance > 0 then sub[#sub + 1] = format("%s%% drop chance", src.chance < 1 and format("%.1f", src.chance) or tostring(floor(src.chance + 0.5))) end
	if src.level and src.level > plevel + 2 then sub[#sub + 1] = "|cffff9a3cabove your level|r" end
	local s = text("small", "textDim")
	s:SetText(concat(sub, DOT))
	s:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	y = y + LINE + 8
	local kind = (npc and npc.rare) and "rare" or "npc"
	y = y + buttons(y, {
		{ "Guide me to it", function()
			if P.Lookup and P.Lookup.Guide then opened(P.Lookup.Guide(kind, src.npc)) end
		end, true },
		{ "Lookup", function() showLookup(kind, src.npc) end },
	})
	return y
end

local function vendorBlock(y, item, src)
	local Cx = P.Codex
	local npc = Cx and Cx.Npc and Cx.Npc(src.npc)
	local head = text("body", "quest")
	head:SetText(format("Vendor: %s", src.name or "?"))
	head:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	y = y + LINE + 2
	local sub = {}
	local spawn = npc and npc.spawns and npc.spawns[1]
	local zone = spawn and mapName(spawn.map)
	if zone then sub[#sub + 1] = zone end
	if src.cost and src.cost > 0 and P.MoneyText then sub[#sub + 1] = P.MoneyText(src.cost) end
	local s = text("small", "textDim")
	s:SetText(concat(sub, DOT))
	s:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	y = y + LINE + 8
	y = y + buttons(y, {
		{ "Guide me", function()
			if P.Lookup and P.Lookup.Guide then opened(P.Lookup.Guide("item", item)) end
		end, true },
		{ "Lookup", function() showLookup("item", item) end },
	})
	return y
end

local BLOCK = { quest = questBlock, dungeon = dungeonBlock, rare = rareBlock, vendor = vendorBlock }

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

local function resultFor(id, slot)
	for _, res in ipairs(FQG.Results(slot) or {}) do
		if res.id == id then return res end
	end
	return nil
end

function GI.Build(center, below)
	page = CreateFrame("Frame", nil, center)
	page:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -2)
	page:SetPoint("BOTTOMRIGHT", center, "BOTTOMRIGHT", 0, 0)
	local back = W.Button(page, "Back to list", function() GV.CloseItem() end, { height = 24, ghost = true, icon = "chevron-left" })
	back:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	note = W.Text(page, "small", "warning")
	note:SetPoint("LEFT", back, "RIGHT", 12, 0)
	note:SetPoint("RIGHT", page, "RIGHT", -6, 0)
	note:SetJustifyH("RIGHT")
	scroll = W.Scroll(page)
	scroll:SetPoint("TOPLEFT", back, "BOTTOMLEFT", 0, -6)
	scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	content = scroll.Child
	scroll:HookScript("OnSizeChanged", function(self, w)
		if w and w > 0 then content:SetWidth(w - 10) end
	end)
	return page
end

function GI.Paint(id, slot)
	if not page then return end
	paintSlot = slot
	reset()
	local w = scroll:GetWidth()
	if w and w > 0 then content:SetWidth(w - 10) end
	if page.psShown ~= id then
		setNote("")
		page.psShown = id
		W.ScrollTo(scroll, 0)
	end
	local _, g = GV.db()
	local plevel = FQB.PlayerLevel()
	local res = resultFor(id, slot)
	local y = 4

	-- The item.
	local icon = itemIcon()
	FQB.SetItem(icon, id)
	icon:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	local name = text("body", "text")
	name:SetText(FQB.ItemName(id) or ("Item " .. id))
	W.Uncolor(name)
	name:SetTextColor(GV.QualityColor(res and res.quality))
	name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -2)
	name:SetPoint("RIGHT", content, "RIGHT", -150, 0)
	local sub = {}
	if res and res.req and res.req > 0 then
		sub[#sub + 1] = (res.req > plevel and "|cffff9a3c" or "") .. "Requires level " .. res.req .. (res.req > plevel and "|r" or "")
	end
	if res and res.ilvl and res.ilvl > 0 then sub[#sub + 1] = "Item level " .. res.ilvl end
	local subText = text("small", "textDim")
	subText:SetText(concat(sub, DOT))
	subText:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)
	local gain = text("body", "success")
	gain:SetText(res and GV.GainText(res) or "")
	gain:SetJustifyH("RIGHT")
	gain:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -(y + 2))
	local mark = button(g.marked[id] and "Unmark" or "Mark", function() GV.ToggleMark(id) end)
	mark:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -(y + 22))
	y = y + 52

	-- What it changes.
	local r1 = rule()
	r1:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	r1:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -y)
	y = y + 8
	local wornLink = GetInventoryItemLink and GetInventoryItemLink("player", slot)
	local cmpHead = text("small", "textMuted")
	if wornLink then
		local wornName = GV.ItemInfo(wornLink)
		cmpHead:SetText(format("Compared with %s (%s)", wornName or "what you wear", GV.SlotName(slot)))
	else
		cmpHead:SetText(format("%s is empty: this fills it", GV.SlotName(slot)))
	end
	cmpHead:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
	y = y + LINE + 2
	local diffs = statDiff(id, wornLink)
	if #diffs == 0 then
		local t = text("small", "textDim")
		t:SetText("No stat it changes is known yet.")
		t:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
		y = y + LINE
	else
		local half = (content:GetWidth() - PAD * 2) / 2
		local shownN = min(#diffs, 10)
		for i = 1, shownN do
			local s = diffs[i]
			local t = text("small", s.diff > 0 and "success" or "danger")
			t:SetText(statLine(s))
			local col, rowN = (i - 1) % 2, floor((i - 1) / 2)
			t:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + col * half, -(y + rowN * LINE))
		end
		y = y + math.ceil(shownN / 2) * LINE
	end
	y = y + 8

	-- Where it comes from: the nearest sources first.
	local srcs = {}
	for _, src in ipairs(res and res.sources or {}) do
		if GV.KeepSource(src) then srcs[#srcs + 1] = src end
	end
	table.sort(srcs, function(a, b)
		if a.tier ~= b.tier then return a.tier < b.tier end
		return a.steps < b.steps
	end)
	if #srcs == 0 then
		local t = text("small", "textDim")
		t:SetText(res and "No source the sidebar keeps." or "Not an upgrade for this slot any more.")
		t:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
		y = y + LINE
	end
	for i = 1, min(#srcs, 3) do
		local src = srcs[i]
		local rr = rule()
		rr:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
		rr:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAD, -y)
		y = y + 10
		local fn = BLOCK[src.kind]
		if fn then
			local ok, ny = pcall(fn, y, id, src, plevel)
			if ok and ny then y = ny else y = y + LINE end
		end
		y = y + 6
	end
	if #srcs > 3 then
		local t = text("small", "textMuted")
		t:SetText(format("%d more sources: Lookup lists them all.", #srcs - 3))
		t:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -y)
		y = y + LINE
	end
	W.SetScrollContent(scroll, y + 12)
end
