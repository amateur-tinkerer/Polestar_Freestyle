-- Polestar Freestyle: its own page in Polestar's Options.
--
-- The settings live in Polestar's settings (P.Get / P.Set, section
-- "freestyle"), so they follow the player's Polestar profile, and the page is
-- registered through Polestar's options registry (ns.RegisterOptions). The
-- Quests section's "Quests above your level" and "Low-level quests" stay
-- Polestar's own settings, on the Quests page as before.
--
-- FQB.Opt(name) -> the setting's value; FQB.ShowOptions() opens the page.
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
local FQB = FQ and FQ.Browser
if not FQB then return end

local SECTION = "freestyle"
local DEFAULTS = {
	nearUnit = "time",   -- "time" | "yards": how Near and Near you measure the way
	nearMinutes = 2.5,   -- Near you reaches this far (minutes on foot)
	nearMax = 10,        -- and lists at most this many
	nearPickups = true,  -- Near you suggests quests to pick up close by
	nearTurnins = true,  -- and quests ready to hand in
}
local RUN_SPEED = 7 -- yards per second on foot (Polestar's own figure)
FQB.RUN_SPEED = RUN_SPEED

if P.RegisterDefaults then P.RegisterDefaults(SECTION, DEFAULTS) end

function FQB.Opt(name)
	local v = P.Get and P.Get(SECTION .. "." .. name)
	if v == nil then v = DEFAULTS[name] end
	return v
end

function FQB.SetOpt(name, value)
	if P.Set then P.Set(SECTION .. "." .. name, value) end
end

function FQB.ShowOptions()
	local UI = P.UI
	if UI and UI.ShowOptions then
		local ok = pcall(UI.ShowOptions, SECTION)
		if ok then return true end
	end
	return false
end

if P.RegisterOptions then
	local ok, err = P.RegisterOptions({
		page = "Polestar Freestyle", key = SECTION, icon = "icon-accept", order = 90,
		tab = "Quests", section = "Near you",
		controls = {
			{ kind = "dropdown", key = SECTION .. ".nearUnit", label = "Measure the way in",
				choices = { { value = "time", label = "Time on foot" }, { value = "yards", label = "Yards" } },
				help = "How the Near column and Near you show how far a quest is: minutes on foot, or yards in a straight line.",
				search = "distance, yards, time, minutes, near" },
			{ kind = "slider", key = SECTION .. ".nearMinutes", label = "Near you reaches", min = 0.5, max = 10, step = 0.5,
				format = "%.1f min",
				help = "How far Near you looks, in minutes on foot (one minute is about 420 yards).",
				search = "near you, range, radius, distance" },
			{ kind = "slider", key = SECTION .. ".nearMax", label = "Near you lists at most", min = 3, max = 25, step = 1,
				format = "%d", help = "The most quests Near you lists at once.", search = "near you, count, limit" },
			{ kind = "toggle", key = SECTION .. ".nearTurnins", label = "Quests to hand in",
				help = "Near you lists your finished quests whose quest giver is close by.", search = "turn in, hand in" },
			{ kind = "toggle", key = SECTION .. ".nearPickups", label = "Quests to pick up",
				help = "Near you suggests quests whose giver is close by in your zone.", search = "pick up, accept, suggest" },
		},
	})
	if not ok and geterrorhandler then geterrorhandler()(err) end
end
