-- Polestar Freestyle: marking quests from Polestar's item search.
--
-- On Lookup's page for an item (an item, mount, pet, recipe or tabard), each
-- quest that gives it ("Quest reward" source rows) gets a star: click it to
-- mark that quest. Marked quests are what the Quests section's Start guide
-- takes when nothing is ticked, and what its Marked filter lists. A
-- right-click on the star marks it and opens the Quests section on it.
--
-- Item tooltips name the marked quests that give the item (Polestar.Hooks,
-- the supported tooltip hook).
--
-- Lookup's page is Polestar's own (UI/Lookup.lua): the star goes on its
-- source rows after it draws them (LK.Render), each step checked, so a
-- Polestar that draws them otherwise just shows no stars.
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
local FQB = FQ and FQ.Browser
local W = P and P.Widgets
if not (FQB and W) then return end

local type, pairs, ipairs = type, pairs, ipairs

local ITEM_KINDS = { item = true, mount = true, pet = true, recipe = true, tabard = true }
local TIP = "Mark this quest for the Quests section (/freequest browse): Start guide takes the marked quests. Right-click: mark and show it there."

local LK = P.UI and P.UI.Lookup
local stars = {} -- source row -> its star

local function marked() return FQ.CharDB().marked end

-- The item on Lookup's page: its quests by title -> quest id.
local function questsByTitle()
	local sel = LK.Selected and LK.Selected()
	if not (type(sel) == "table" and ITEM_KINDS[sel.kind] and sel.id) then return nil end
	local Cx = P.Codex
	if not (Cx and Cx.IsLoaded and Cx.IsLoaded()) then return nil end
	local out, any = {}, false
	for _, s in ipairs(FQB.QuestsForItem(sel.id)) do
		local q = Cx.Quest(s.quest)
		if q and q.title then
			out[q.title] = s.quest
			any = true
		end
	end
	return any and out or nil
end

local function onStar(self, button)
	local id = self.psQuest
	if not id then return end
	local m = marked()
	if button == "RightButton" then
		m[id] = true
		FQB.Changed()
		if FQB.Section and FQB.Section.Reveal then FQB.Section.Reveal({ id }) end
		return
	end
	m[id] = (not m[id]) and true or nil
	W.SetIconState(self, m[id] and true or false)
	FQB.Changed()
end

local function starFor(r)
	local s = stars[r]
	if s then return s end
	s = W.IconButton(r, "star", 22, TIP, onStar)
	s:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	stars[r] = s
	return s
end

local function decorate()
	local d = LK.details
	local rowsList = d and d.Rows
	if type(rowsList) ~= "table" then return end
	local byTitle = questsByTitle()
	local m = marked()
	for _, r in ipairs(rowsList) do
		local id = byTitle and r:IsShown() and r.Label and byTitle[r.Label:GetText() or ""]
		if id then
			local s = starFor(r)
			s.psQuest = id
			s:ClearAllPoints()
			if r.Guide and r.Guide:IsShown() then
				s:SetPoint("RIGHT", r.Guide, "LEFT", -6, 0)
			else
				s:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -8, 6)
			end
			W.SetIconState(s, m[id] and true or false)
			s:Show()
		elseif stars[r] then
			stars[r]:Hide()
			stars[r].psQuest = nil
		end
	end
end

if LK and type(LK.Render) == "function" and hooksecurefunc then
	hooksecurefunc(LK, "Render", function() pcall(decorate) end)
	FQB.Listen(function()
		if LK.root and LK.root.IsVisible and LK.root:IsVisible() then pcall(decorate) end
	end)
end

-- Item tooltips: the marked quests that give it.
local Hooks = P.Hooks
if Hooks and Hooks.ItemLines then
	Hooks.ItemLines("Polestar_FreeQuest", function(tooltip, _, itemID)
		if not itemID then return end
		local m = marked()
		if not next(m) then return end
		local Cx = P.Codex
		if not (Cx and Cx.IsLoaded and Cx.IsLoaded()) then return end
		for _, s in ipairs(FQB.QuestsForItem(itemID)) do
			if m[s.quest] then
				local q = Cx.Quest(s.quest)
				local text = "|TInterface\\AddOns\\Polestar\\Media\\UI\\star:12|t Marked quest: " .. ((q and q.title) or ("Quest " .. s.quest))
				if Hooks.AddLine then
					Hooks.AddLine(tooltip, text, nil, 1, 0.82, 0)
				else
					tooltip:AddLine(text, 1, 0.82, 0)
				end
			end
		end
	end)
end
