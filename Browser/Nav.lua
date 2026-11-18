-- Polestar Freestyle: the way back after a jump between hub sections.
--
-- The Quests and Gear sections send the player elsewhere: Gear's "Show in
-- Quests", "Open dungeon page" and "Lookup"; Quests' "Show in Lookup". Each
-- such jump goes through Nav.Jump(origin, fn), which keeps where the player
-- came from on a stack and shows "‹ Back to <origin>" in the hub header until
-- it is used, the player returns to that section another way, or the hub
-- closes. Jumps chain: Gear > Quests > Lookup unwinds one step per click.
--
-- The button sits in the header's top row, left of "Special thanks to" (or
-- "Menu scale"): that row never holds a section's own buttons. The Dungeons
-- page paints its art over the header, so the button's level is raised.
--
-- Polestar's hub renders before it switches section (UI.ShowPicker, then
-- ShowSection), so a render during the jump still reports the old section:
-- nothing is dropped while a jump runs, and the section the jump landed on is
-- read a frame later.
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
local FQB = FQ and FQ.Browser
local UI = P and P.UI
local W = P and P.Widgets
if not (FQB and UI and W) then return end

local Nav = {}
FQB.Nav = Nav

local stack = {}      -- { key, label, restore, at }: the newest last
local busy = false    -- a jump or a way back is running
local btn, hooked

local function picker() return UI.Picker end
local function hub() local Pk = picker(); return Pk and Pk.frame end
local function current()
	local Pk = picker()
	return Pk and Pk.Section and Pk.Section() or nil
end

-- Back in a section the stack came from (by the rail or a link): every jump
-- from it, and after it, is done with.
local function settle()
	if busy then return end
	local cur = current()
	if not cur then return end
	for i = 1, #stack do
		if stack[i].key == cur and stack[i].at then
			for j = #stack, i, -1 do stack[j] = nil end
			return
		end
	end
end

-- Top left of the header, above the page title (and above the Dungeons
-- page's own "‹" arrow), the same spot on every section.
local function place()
	local win = hub()
	if not (btn and win) then return end
	btn:ClearAllPoints()
	btn:SetPoint("TOPLEFT", win.Header or win, "TOPLEFT", 6, -6)
end

local function goBack()
	local top = stack[#stack]
	if not top then return end
	stack[#stack] = nil
	busy = true
	local ok, err = pcall(top.restore)
	busy = false
	Nav.Update()
	if not ok and geterrorhandler then geterrorhandler()(err) end
end

-- Closing the hub ends every way back.
local function hookHub(win)
	if hooked or not win then return end
	hooked = true
	win:HookScript("OnHide", function()
		for i = #stack, 1, -1 do stack[i] = nil end
		if btn then btn:Hide() end
	end)
	if type(win.PlaceThanks) == "function" and hooksecurefunc then
		hooksecurefunc(win, "PlaceThanks", function() pcall(place) end)
	end
end

local function ensure(win)
	hookHub(win)
	if btn then return end
	btn = W.Button(win, "Back", goBack, { height = 22, ghost = true, icon = "chevron-left" })
	btn:SetFrameStrata(win:GetFrameStrata())
	btn:SetFrameLevel(win:GetFrameLevel() + 60)
	-- A dim backing so it reads over the Dungeons page's map art.
	local bg = W.Fill(btn, "panel", "BACKGROUND", -8)
	W.Color(bg, "panel", 0.8)
	btn:Hide()
end

function Nav.Update()
	local win = hub()
	if not win then return end
	hookHub(win)
	if not win:IsShown() then
		for i = #stack, 1, -1 do stack[i] = nil end
	end
	settle()
	local top = stack[#stack]
	local want = top ~= nil and top.at ~= nil and win:IsShown() and current() ~= top.key
	if want then
		ensure(win)
		W.SetButtonText(btn, "Back to " .. (top.label or top.key))
		place()
	end
	if btn then btn:SetShown(want and true or false) end
end

-- origin = { key = section key, label = shown name, restore = function }
function Nav.Jump(origin, fn)
	if not origin then return fn() end
	stack[#stack + 1] = origin
	busy = true
	local ok, err = pcall(fn)
	busy = false
	-- Lookup and Dungeons may switch on the next frame: record where it landed then.
	C_Timer.After(0, function()
		if stack[#stack] == origin then
			origin.at = current() or "?"
		end
		pcall(Nav.Update)
	end)
	if not ok and geterrorhandler then geterrorhandler()(err) end
end

function Nav.Clear()
	for i = #stack, 1, -1 do stack[i] = nil end
	Nav.Update()
end

if UI.Picker and type(UI.Picker.Render) == "function" and hooksecurefunc then
	hooksecurefunc(UI.Picker, "Render", function() pcall(Nav.Update) end)
end
