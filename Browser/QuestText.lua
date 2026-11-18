-- Polestar Freestyle: a quest's story text for the Quests section.
--
-- Polestar ships no quest text. This file keeps the text the game itself shows
-- the player, the quest giver's window (QUEST_DETAIL) and the quest log, in
-- the account-wide PolestarFreeQuestDB.text, so it is there for every
-- character afterwards. Quests never seen fall back to the bundled text in
-- Data/QuestText.lua (FQB.QuestText, from Efficient Games' EG Link dataset,
-- CC BY 4.0; the quest text itself is Blizzard's).
--
-- FQB.QuestStory(id) -> text, source | nil
--
-- License: GPL-3.0-only, as Polestar.

local P = Polestar
local FQ = P and P.FreeQuest
local FQB = FQ and FQ.Browser
if not FQB then return end

local type, tonumber = type, tonumber
local gsub = string.gsub

local function store()
	if type(PolestarFreeQuestDB) ~= "table" then PolestarFreeQuestDB = {} end
	local db = PolestarFreeQuestDB
	if type(db.text) ~= "table" then db.text = {} end
	return db.text
end

local function build()
	local _, b = GetBuildInfo and GetBuildInfo()
	return b
end

local function clean(s)
	if type(s) ~= "string" then return nil end
	s = s:gsub("\r", ""):match("^%s*(.-)%s*$")
	return s ~= "" and s or nil
end

local function save(id, desc, obj)
	id = tonumber(id)
	desc, obj = clean(desc), clean(obj)
	if not (id and id > 0 and (desc or obj)) then return end
	local t = store()
	local old = t[id]
	if old and old.d == desc and old.o == obj then return end
	t[id] = { d = desc or (old and old.d), o = obj or (old and old.o), b = build() }
end

-- The quest log's text for one quest, the player's selection kept.
local function fromLog(id)
	if not (GetQuestLogQuestText and SelectQuestLogEntry and GetQuestLogSelection) then return end
	local index = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)
	if not index and GetNumQuestLogEntries and GetQuestLogTitle then
		for i = 1, (GetNumQuestLogEntries()) do
			local _, _, _, header, _, _, _, qid = GetQuestLogTitle(i)
			if not header and qid == id then index = i break end
		end
	end
	if not index then return end
	local was = GetQuestLogSelection()
	SelectQuestLogEntry(index)
	local desc, obj = GetQuestLogQuestText()
	if was and was > 0 then SelectQuestLogEntry(was) end
	save(id, desc, obj)
end

-- $N name, $C class, $R race, $B a line break, $G male:female; (the game's
-- own tokens in quest text).
local function fill(s)
	local name = UnitName and UnitName("player") or "you"
	local class = UnitClass and UnitClass("player") or "adventurer"
	local race = UnitRace and UnitRace("player") or "adventurer"
	local female = UnitSex and UnitSex("player") == 3
	s = gsub(s, "%$[Gg]%s*([^:;]-)%s*:%s*([^;]-)%s*;", function(m, f) return female and f or m end)
	s = gsub(s, "%$[Nn]", name)
	s = gsub(s, "%$[Cc]", class)
	s = gsub(s, "%$[Rr]", race)
	s = gsub(s, "%$[Bb]", "\n")
	return s
end

-- Readable paragraphs: the text's own breaks ($B) become blank lines, and a
-- long paragraph is split after every third sentence. A sentence ends at
-- . ! or ? followed by spaces and a capital letter (so "Mr. Smith" or
-- "3.5 yards" stay whole).
local SENTENCES = 3
local LONG = 280
local function paragraphs(s)
	local out = {}
	for para in (s .. "\n"):gmatch("(.-)\n") do
		para = para:match("^%s*(.-)%s*$")
		if para ~= "" then
			if #para > LONG then
				local count, last, parts = 0, 1, {}
				for stop in para:gmatch("[%.!?]+[\"']?()%s+%u") do
					count = count + 1
					if count % SENTENCES == 0 then
						parts[#parts + 1] = para:sub(last, stop - 1)
						last = stop
					end
				end
				parts[#parts + 1] = para:sub(last)
				for _, p in ipairs(parts) do
					p = p:match("^%s*(.-)%s*$")
					if p ~= "" then out[#out + 1] = p end
				end
			else
				out[#out + 1] = para
			end
		end
	end
	return table.concat(out, "\n\n")
end

local tried = {} -- quests whose log text was read this session

function FQB.QuestStory(id)
	id = tonumber(id)
	if not id then return nil end
	local t = store()
	if not t[id] and not tried[id] and FQB.Status and FQB.Status(id) == "log" then
		tried[id] = true
		pcall(fromLog, id)
	end
	local seen = t[id]
	if seen and seen.d then return paragraphs(fill(seen.d)), "From the quest text the game showed you." end
	local bundled = FQB.QuestText and FQB.QuestText[id]
	local desc = type(bundled) == "table" and bundled[1] or bundled
	if type(desc) == "string" and desc ~= "" then
		return paragraphs(fill(desc)), "Quest text from Efficient Games' EG Link dataset (CC BY 4.0)."
	end
	return nil
end

-- How big a quest is and whether it needs a group:
--   size: 1 short, 2 medium, 3 long, from the quest's XP tier (Blizzard's own
--         0-7 measure of a quest's size, from the bundled EG Link data);
--   tag:  "dungeon" when an objective's mob lives in an instance, "group"
--         when one is elite, rare elite or a boss (Polestar's Codex).
-- FQB.QuestSize(id) -> size|nil, tag|nil
FQB.SIZE_WORDS = { "Short", "Medium", "Long" }
local sizes = {}
local function measure(id)
	local size
	local bundled = FQB.QuestText and FQB.QuestText[id]
	local x = type(bundled) == "table" and tonumber(bundled[3]) or nil
	if x then size = x <= 2 and 1 or (x <= 5 and 2 or 3) end
	local tag
	local Cx = P.Codex
	local cq = Cx and Cx.Quest and Cx.Quest(id)
	if cq and type(cq.objectives) == "table" then
		for _, o in ipairs(cq.objectives) do
			if (o.type == "kill" or o.type == "talk") and o.id and Cx.Npc then
				local n = Cx.Npc(o.id)
				if n and n.instance then tag = "dungeon" break end
				if n and (n.elite or n.boss) then tag = "group" end
			elseif type(o.elites) == "table" and next(o.elites) then
				tag = tag or "group"
			end
		end
	end
	return size, tag
end

function FQB.QuestSize(id)
	id = tonumber(id)
	if not id then return nil end
	local hit = sizes[id]
	if hit == nil then
		local size, tag = measure(id)
		hit = { size, tag }
		if P.Codex and P.Codex.IsLoaded and P.Codex.IsLoaded() then sizes[id] = hit end
	end
	return hit[1], hit[2]
end

local f = CreateFrame("Frame")
f:RegisterEvent("QUEST_DETAIL")
f:RegisterEvent("QUEST_ACCEPTED")
f:SetScript("OnEvent", function(_, event, a, b)
	if event == "QUEST_DETAIL" then
		local id = GetQuestID and GetQuestID()
		if id and id > 0 then
			save(id, GetQuestText and GetQuestText(), GetObjectiveText and GetObjectiveText())
		end
	elseif event == "QUEST_ACCEPTED" then
		-- (questLogIndex, questID) on Classic; (questID) on newer clients.
		local id = tonumber(b) or tonumber(a)
		if id and id > 0 and not store()[id] then
			C_Timer.After(0.5, function() pcall(fromLog, id) end)
		end
	end
end)
