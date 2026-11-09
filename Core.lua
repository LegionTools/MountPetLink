-- MountPetLink: extends the normal dress-up gesture (Ctrl+click, or whatever
-- you've bound to the "Dressup" modified click) to mount-teaching items and
-- caged battle pets. Those items aren't equippable, so Blizzard's own
-- dress-up handler silently ignores them - this opens the matching
-- Collections Journal tab with the search box pre-filled instead.

local DEBUG = false

local function Debug(fmt, ...)
	if DEBUG then
		print("|cff33ccff[MountPetLink]|r " .. string.format(fmt, ...))
	end
end

-- "|cffffffff|Hitem:12345:...|h[Name]|h|r" -> "item:12345:..." (or
-- "battlepet:speciesID:..." for a caged pet link).
local function GetLinkPayload(link)
	return link and link:match("|H(.-)|h")
end

-- This client has no direct "which mount teaches this spell" lookup, so the
-- mapping is built once (lazily) by scanning the whole Mount Journal. Which
-- enumeration function actually exists varies by client/emulator, so try a
-- couple of known ones rather than assuming.
local spellIDToMountID

local function BuildMountSpellCache()
	spellIDToMountID = {}
	local CMJ = C_MountJournal

	if type(CMJ.GetMountIDs) == "function" then
		Debug("building mount cache via GetMountIDs")
		local ok, mountIDs = pcall(CMJ.GetMountIDs)
		if ok and mountIDs then
			for _, mountID in ipairs(mountIDs) do
				local _, spellID = CMJ.GetMountInfoByID(mountID)
				if spellID then
					spellIDToMountID[spellID] = mountID
				end
			end
			return
		end
	end

	if type(CMJ.GetMountInfo) == "function" and type(CMJ.GetNumMounts) == "function" then
		Debug("building mount cache via GetNumMounts/GetMountInfo")
		for i = 1, CMJ.GetNumMounts() do
			local ok, _, spellID, _, _, _, _, _, _, _, _, _, mountID = pcall(CMJ.GetMountInfo, i)
			if ok and spellID and mountID then
				spellIDToMountID[spellID] = mountID
			end
		end
		return
	end

	Debug("no known mount-enumeration API found on C_MountJournal - run /mpldebug to list what's there")
end

-- Setting an edit box's text via script doesn't fire its OnTextChanged, so
-- the journal's own filtering has to be kicked manually. Right after the
-- journal's first-ever open this frame may not exist yet for a tick
-- (Blizzard_Collections finishing its own setup), so retry briefly.
local function TrySetSearchBox(frameName, text, attemptsLeft)
	local box = _G[frameName]
	if box then
		box:SetText(text or "")
		local onTextChanged = box:GetScript("OnTextChanged")
		if onTextChanged then
			onTextChanged(box, true)
		end
		Debug("set %s to %q", frameName, tostring(text))
		return
	end
	if (attemptsLeft or 0) > 0 then
		C_Timer.After(0.1, function() TrySetSearchBox(frameName, text, attemptsLeft - 1) end)
	else
		Debug("could not find %s", frameName)
	end
end

local function OpenMountJournalFor(mountID)
	local ok, name = pcall(C_MountJournal.GetMountInfoByID, mountID)
	ToggleCollectionsJournal(1)
	TrySetSearchBox("MountJournalSearchBox", ok and name or "", 5)
end

local function OpenPetJournalFor(speciesID)
	local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
	ToggleCollectionsJournal(2)
	TrySetSearchBox("PetJournalSearchBox", ok and name or "", 5)
end

hooksecurefunc("HandleModifiedItemClick", function(link)
	if not IsModifiedClick("DRESSUP") then return end
	local payload = GetLinkPayload(link)
	if not payload then return end
	local linkType = payload:match("^(%a+):")

	if linkType == "battlepet" then
		local speciesID = tonumber(payload:match("^battlepet:(%d+)"))
		if speciesID then
			OpenPetJournalFor(speciesID)
		end
	elseif linkType == "item" then
		local itemID = tonumber(payload:match("^item:(%d+)"))
		if itemID then
			local _, spellID = GetItemSpell(itemID)
			if spellID then
				if not spellIDToMountID then
					BuildMountSpellCache()
				end
				local mountID = spellIDToMountID[spellID]
				if mountID then
					OpenMountJournalFor(mountID)
				end
			end
		end
	end
end)

-- Learning a new mount (trainer, quest, vendor...) after login would leave
-- the cache stale, so rebuild it next time it's needed.
do
	local cacheRefresher = CreateFrame("Frame")
	local registered = pcall(cacheRefresher.RegisterEvent, cacheRefresher, "NEW_MOUNT_ADDED")
	if registered then
		cacheRefresher:SetScript("OnEvent", function() spellIDToMountID = nil end)
	end
end

-- Lists every function this client's API table actually exposes, sorted -
-- lets us check what's really there instead of guessing from retail docs.
local function ListFunctions(tbl)
	local names = {}
	for key, value in pairs(tbl) do
		if type(value) == "function" then
			names[#names + 1] = key
		end
	end
	table.sort(names)
	return table.concat(names, ", ")
end

SLASH_MOUNTPETLINKDEBUG1 = "/mpldebug"
SlashCmdList["MOUNTPETLINKDEBUG"] = function()
	DEBUG = not DEBUG
	print("|cff33ccff[MountPetLink]|r debug " .. (DEBUG and "ON" or "OFF"))
	if DEBUG then
		print(string.format("CollectionsJournal=%s MountJournalSearchBox=%s PetJournalSearchBox=%s",
			tostring(CollectionsJournal), tostring(MountJournalSearchBox), tostring(PetJournalSearchBox)))
		print("C_MountJournal: " .. ListFunctions(C_MountJournal))
		print("C_PetJournal: " .. ListFunctions(C_PetJournal))
	end
end
