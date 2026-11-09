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

-- This server's GetItemSpell doesn't return a usable spellID for
-- mount-teaching items (confirmed via /mpltest - it comes back as "", not a
-- real number, even for a mount already in the collection), so matching by
-- spell isn't viable here. Instead, cache icon texture -> mountID list: a
-- mount item's icon is normally the same texture as the mount's own icon in
-- the Journal, which is a language-independent match (unlike matching by
-- name, which breaks on Russian noun declension between the item name and
-- the mount's own name). Several mounts (recolors/variants) can share one
-- icon, so this maps to a LIST of candidates, not a single mountID.
local iconToMountIDs
local spellIDToMountID -- kept as a fallback in case this ever works after all

local function BuildMountCaches()
	iconToMountIDs, spellIDToMountID = {}, {}
	local CMJ = C_MountJournal
	local mountIDs

	if type(CMJ.GetMountIDs) == "function" then
		local ok, ids = pcall(CMJ.GetMountIDs)
		if ok then mountIDs = ids end
	end

	if mountIDs then
		Debug("building mount caches via GetMountIDs (%d mounts)", #mountIDs)
		for _, mountID in ipairs(mountIDs) do
			local ok, _, spellID, icon = pcall(CMJ.GetMountInfoByID, mountID)
			if ok then
				if icon then
					iconToMountIDs[icon] = iconToMountIDs[icon] or {}
					tinsert(iconToMountIDs[icon], mountID)
				end
				if spellID and tonumber(spellID) and tonumber(spellID) ~= 0 then
					spellIDToMountID[tonumber(spellID)] = mountID
				end
			end
		end
	elseif type(CMJ.GetMountInfo) == "function" and type(CMJ.GetNumMounts) == "function" then
		Debug("building mount caches via GetNumMounts/GetMountInfo")
		for i = 1, CMJ.GetNumMounts() do
			local ok, _, spellID, icon, _, _, _, _, _, _, _, mountID = pcall(CMJ.GetMountInfo, i)
			if ok and mountID then
				if icon then
					iconToMountIDs[icon] = iconToMountIDs[icon] or {}
					tinsert(iconToMountIDs[icon], mountID)
				end
				if spellID and tonumber(spellID) and tonumber(spellID) ~= 0 then
					spellIDToMountID[tonumber(spellID)] = mountID
				end
			end
		end
	else
		Debug("no known mount-enumeration API found on C_MountJournal - run /mpldebug to list what's there")
	end
end

-- Mirrors the search text into the journal's visible edit box (cosmetic
-- only - the actual filtering below goes through C_MountJournal.SetSearch /
-- C_PetJournal.SetSearchFilter directly). Right after the journal's
-- first-ever open the box may not exist yet for a tick (Blizzard_Collections
-- finishing its own setup), so retry briefly; if the frame name's wrong on
-- this client it just never updates, which isn't fatal since filtering
-- already happened.
local function TryMirrorSearchBoxText(frameName, text, attemptsLeft)
	local box = _G[frameName]
	if box then
		box:SetText(text or "")
		Debug("mirrored %q into %s", tostring(text), frameName)
		return
	end
	if (attemptsLeft or 0) > 0 then
		C_Timer.After(0.1, function() TryMirrorSearchBoxText(frameName, text, attemptsLeft - 1) end)
	else
		Debug("could not find %s to mirror text into (non-fatal)", frameName)
	end
end

local function OpenMountJournalFor(mountID)
	ToggleCollectionsJournal(1)
	local ok, name = pcall(C_MountJournal.GetMountInfoByID, mountID)
	if ok and name then
		if type(C_MountJournal.SetSearch) == "function" then
			C_MountJournal.SetSearch(name)
			Debug("C_MountJournal.SetSearch(%q)", name)
		end
		TryMirrorSearchBoxText("MountJournalSearchBox", name, 5)
	end
end

local function OpenPetJournalFor(speciesID)
	ToggleCollectionsJournal(2)
	local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
	if ok and name then
		if type(C_PetJournal.SetSearchFilter) == "function" then
			C_PetJournal.SetSearchFilter(name)
			Debug("C_PetJournal.SetSearchFilter(%q)", name)
		end
		TryMirrorSearchBoxText("PetJournalSearchBox", name, 5)
	end
end

-- ============================================================================
-- Ambiguous-icon picker: several mounts can share one icon (recolors,
-- variants), so when a clicked item's icon matches more than one, let the
-- player pick which one instead of guessing and opening the wrong one.
-- ============================================================================

local ROW_HEIGHT = 36
local pickerFrame
local pickerRows = {}

local function GetOrCreateRow(index)
	if pickerRows[index] then return pickerRows[index] end
	local row = CreateFrame("Button", nil, pickerFrame)
	row:SetSize(230, ROW_HEIGHT - 4)
	row:SetPoint("TOP", 0, -30 - (index - 1) * ROW_HEIGHT)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(28, 28)
	row.icon:SetPoint("LEFT", 2, 0)

	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.text:SetPoint("RIGHT", -2, 0)
	row.text:SetJustifyH("LEFT")

	pickerRows[index] = row
	return row
end

local function GetOrCreatePickerFrame()
	if pickerFrame then return pickerFrame end

	local ok, frame = pcall(CreateFrame, "Frame", "MountPetLinkPickerFrame", UIParent, "BasicFrameTemplateWithInset")
	if not ok or not frame then
		Debug("BasicFrameTemplateWithInset unavailable, falling back to a plain backdrop frame")
		frame = CreateFrame("Frame", "MountPetLinkPickerFrame", UIParent)
		frame:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true, tileSize = 32, edgeSize = 32,
			insets = {left = 11, right = 12, top = 12, bottom = 11},
		})
		local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -2, -2)
	end

	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("TOP", 0, -8)
	frame.title:SetText("Несколько маунтов с такой иконкой:")

	tinsert(UISpecialFrames, "MountPetLinkPickerFrame")
	frame:Hide()
	pickerFrame = frame
	return frame
end

local function ShowMountPicker(mountIDs)
	GetOrCreatePickerFrame()
	local numRows = #mountIDs
	pickerFrame:SetSize(260, 40 + numRows * ROW_HEIGHT)

	for i, mountID in ipairs(mountIDs) do
		local row = GetOrCreateRow(i)
		local ok, name, _, icon = pcall(C_MountJournal.GetMountInfoByID, mountID)
		row.icon:SetTexture(ok and icon or nil)
		row.text:SetText(ok and name or ("mountID " .. mountID))
		row:SetScript("OnClick", function()
			pickerFrame:Hide()
			OpenMountJournalFor(mountID)
		end)
		row:Show()
	end
	for i = numRows + 1, #pickerRows do
		pickerRows[i]:Hide()
	end

	pickerFrame:Show()
end

hooksecurefunc("HandleModifiedItemClick", function(link)
	Debug("HandleModifiedItemClick link=%s", tostring(link))
	if not IsModifiedClick("DRESSUP") then
		Debug("not a Dressup-modified click, ignoring")
		return
	end
	local payload = GetLinkPayload(link)
	if not payload then
		Debug("could not extract a |H...|h payload from the link")
		return
	end
	local linkType = payload:match("^(%a+):")
	Debug("payload=%s linkType=%s", payload, tostring(linkType))

	if linkType == "battlepet" then
		local speciesID = tonumber(payload:match("^battlepet:(%d+)"))
		Debug("speciesID=%s", tostring(speciesID))
		if speciesID then
			OpenPetJournalFor(speciesID)
		end
	elseif linkType == "item" then
		local itemID = tonumber(payload:match("^item:(%d+)"))
		Debug("itemID=%s", tostring(itemID))
		if itemID then
			if not iconToMountIDs then
				BuildMountCaches()
			end

			local itemIcon = select(10, GetItemInfo(itemID))
			local candidates = itemIcon and iconToMountIDs[itemIcon]
			Debug("itemIcon=%s -> %d candidate(s)", tostring(itemIcon), candidates and #candidates or 0)

			if candidates and #candidates == 1 then
				OpenMountJournalFor(candidates[1])
			elseif candidates and #candidates > 1 then
				ShowMountPicker(candidates)
			else
				-- fall back to the spell-based match in case the icon one
				-- missed (e.g. a custom item icon that doesn't match its mount)
				local _, spellID = GetItemSpell(itemID)
				if spellID == "" then spellID = nil end -- this server returns "" rather than nil for no-spell items
				spellID = tonumber(spellID)
				local mountID = spellID and spellIDToMountID[spellID]
				Debug("fallback GetItemSpell -> spellID=%s -> mountID=%s", tostring(spellID), tostring(mountID))
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
		cacheRefresher:SetScript("OnEvent", function() iconToMountIDs, spellIDToMountID = nil, nil end)
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

-- /mpltest <itemID> - dumps everything both matching strategies (icon and
-- spell) can see for a known itemID, instead of inferring it only from a
-- click that might not even be on a mount item.
SLASH_MOUNTPETLINKTEST1 = "/mpltest"
SlashCmdList["MOUNTPETLINKTEST"] = function(msg)
	local itemID = tonumber(msg)
	if not itemID then
		print("|cff33ccff[MountPetLink]|r usage: /mpltest <itemID>")
		return
	end
	if not iconToMountIDs then BuildMountCaches() end

	local name, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
	local spellName, spellID = GetItemSpell(itemID)
	if spellID == "" then spellID = nil end
	spellID = tonumber(spellID)

	local candidates = icon and iconToMountIDs[icon]
	local candidateNames = {}
	if candidates then
		for _, mountID in ipairs(candidates) do
			local ok, mountName = pcall(C_MountJournal.GetMountInfoByID, mountID)
			tinsert(candidateNames, string.format("%d=%s", mountID, ok and mountName or "?"))
		end
	end

	print(string.format("|cff33ccff[MountPetLink]|r itemID=%d name=%s icon=%s", itemID, tostring(name), tostring(icon)))
	print(string.format("  icon match: %d candidate(s): %s", candidates and #candidates or 0, table.concat(candidateNames, ", ")))
	print(string.format("  spell match: GetItemSpell -> spellName=%s spellID=%s | spellIDToMountID[...] = %s",
		tostring(spellName), tostring(spellID), tostring(spellID and spellIDToMountID[spellID])))
end
