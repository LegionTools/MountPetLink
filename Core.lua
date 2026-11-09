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

-- By default, opening the Collections Journal closes every other open UI
-- panel (trade window included) because UIPanelWindows["CollectionsJournal"]
-- has allowOtherPanels = false - that's Blizzard's own panel-management
-- flag, not something specific to this addon's hook. Flip it once at load
-- so a Ctrl+click mid-trade doesn't close the trade window out from under
-- the player.
if UIPanelWindows and UIPanelWindows["CollectionsJournal"] then
	UIPanelWindows["CollectionsJournal"].allowOtherPanels = true
end

-- allowOtherPanels alone isn't closing the trade window in practice. The
-- first round of diagnostics (hooking the global CloseTrade/HideUIPanel
-- functions) found neither was being called - so whatever hides TradeFrame
-- does it some other way (a direct :Hide() call, an animation, or a
-- TRADE_CLOSED event from the server itself). Hooking TradeFrame's own
-- OnHide script catches it regardless of mechanism; registering TRADE_CLOSED
-- separately tells us whether the server is the one ending the trade in the
-- first place, rather than the client UI closing it on its own.
--
-- All of this runs once at file-load time, long before the player could
-- ever type /mpldebug to turn DEBUG on - so failures here were being
-- swallowed by Debug() silently no-opping. Recorded into tradeHookStatus
-- instead and reported unconditionally by /mpldebug.
local tradeHookStatus = {}
do
	tradeHookStatus.CloseTrade = pcall(hooksecurefunc, "CloseTrade", function()
		Debug("CloseTrade() called:\n%s", debugstack(2))
	end)

	tradeHookStatus.HideUIPanel = pcall(hooksecurefunc, "HideUIPanel", function(frame)
		if frame and frame.GetName and frame:GetName() == "TradeFrame" then
			Debug("HideUIPanel(TradeFrame) called:\n%s", debugstack(2))
		end
	end)

	if TradeFrame then
		tradeHookStatus.TradeFrameOnHide = pcall(TradeFrame.HookScript, TradeFrame, "OnHide", function()
			Debug("TradeFrame OnHide fired:\n%s", debugstack(2))
		end)
	else
		tradeHookStatus.TradeFrameOnHide = "TradeFrame is nil"
	end

	local tradeCloseWatcher = CreateFrame("Frame")
	tradeHookStatus.TRADE_CLOSED = pcall(tradeCloseWatcher.RegisterEvent, tradeCloseWatcher, "TRADE_CLOSED")
	if tradeHookStatus.TRADE_CLOSED then
		tradeCloseWatcher:SetScript("OnEvent", function()
			Debug("TRADE_CLOSED event fired (server ended the trade)")
		end)
	end
end

-- This server's GetItemSpell doesn't return a usable spellID for
-- mount-teaching items (confirmed via /mpltest - it comes back as "", not a
-- real number, even for a mount already in the collection), so matching by
-- spell isn't viable here. Icon matching (item icon == mount's Journal icon)
-- works most of the time, but isn't exact either - confirmed live, a mount
-- item's icon can differ by a texture ID from its own mount's icon even for
-- visually-identical recolors (e.g. the Traveler's Tundra Mammoth item vs
-- mount). So candidates come from THREE signals unioned together: exact
-- icon match, exact spell match (kept in case it ever works), and a
-- name-word-stem match (shares a meaningful word root with the item's name,
-- case-folded and stripped of grammatical endings) - the last one is lossy
-- on purpose, to widen the net rather than silently miss the right mount;
-- the picker lets the player sort out the real one from the shortlist.

-- Lua's string.lower only folds ASCII - this does the same for the basic
-- Cyrillic block (А-Я, Ё) so word-stem comparisons aren't case-sensitive.
local function CyrillicToLower(text)
	text = text:gsub("\208([\144-\159])", function(b) return "\208" .. string.char(b:byte() + 32) end)
	text = text:gsub("\208([\160-\175])", function(b) return "\209" .. string.char(b:byte() - 32) end)
	text = text:gsub("\208\129", "\209\145") -- Ё -> ё
	return text
end

-- Russian adjectives/nouns decline (e.g. item "тундрового мамонта" vs mount
-- "Тундровый мамонт"), so comparing whole words fails; this takes each
-- word's first few characters as a rough stem instead. Cyrillic characters
-- are 2 bytes each in UTF-8, hence the *2 on the byte count.
local STEM_CHARS = 5
local MIN_WORD_CHARS = 5 -- skip short connector words ("для", "и", ...)

local function GetWordStems(text)
	local stems = {}
	if not text then return stems end
	text = CyrillicToLower(text:lower())
	for word in text:gmatch("%S+") do
		word = word:gsub("^%p+", ""):gsub("%p+$", "")
		if #word >= MIN_WORD_CHARS * 2 then
			stems[word:sub(1, STEM_CHARS * 2)] = true
		end
	end
	return stems
end

local iconToMountIDs
local spellIDToMountID -- kept as a fallback in case this ever works after all
local stemToMountIDs

local function AddToIndex(index, key, mountID)
	if not key then return end
	index[key] = index[key] or {}
	tinsert(index[key], mountID)
end

local function IndexMount(mountID, name, spellID, icon)
	if icon then
		AddToIndex(iconToMountIDs, icon, mountID)
	end
	spellID = tonumber(spellID)
	if spellID and spellID ~= 0 then
		spellIDToMountID[spellID] = mountID
	end
	for stem in pairs(GetWordStems(name)) do
		AddToIndex(stemToMountIDs, stem, mountID)
	end
end

local function BuildMountCaches()
	iconToMountIDs, spellIDToMountID, stemToMountIDs = {}, {}, {}
	local CMJ = C_MountJournal
	local mountIDs

	if type(CMJ.GetMountIDs) == "function" then
		local ok, ids = pcall(CMJ.GetMountIDs)
		if ok then mountIDs = ids end
	end

	if mountIDs then
		Debug("building mount caches via GetMountIDs (%d mounts)", #mountIDs)
		for _, mountID in ipairs(mountIDs) do
			local ok, name, spellID, icon = pcall(CMJ.GetMountInfoByID, mountID)
			if ok then
				IndexMount(mountID, name, spellID, icon)
			end
		end
	elseif type(CMJ.GetMountInfo) == "function" and type(CMJ.GetNumMounts) == "function" then
		Debug("building mount caches via GetNumMounts/GetMountInfo")
		for i = 1, CMJ.GetNumMounts() do
			local ok, name, spellID, icon, _, _, _, _, _, _, _, mountID = pcall(CMJ.GetMountInfo, i)
			if ok and mountID then
				IndexMount(mountID, name, spellID, icon)
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

-- Clicks the first row of the journal's result list so its 3D model shows
-- right away instead of leaving the player to click it themselves. This is
-- the same "/click ...ScrollFrameButton1" trick players already use in
-- macros for this - the button only reflects the current filtered results
-- after SetSearch/SetSearchFilter has run and the list has had a moment to
-- refresh, hence the retry.
local function TryClickFirstResult(buttonName, attemptsLeft)
	local button = _G[buttonName]
	if button and button:IsVisible() then
		button:Click()
		Debug("clicked %s to preview the first result", buttonName)
		return
	end
	if (attemptsLeft or 0) > 0 then
		C_Timer.After(0.1, function() TryClickFirstResult(buttonName, attemptsLeft - 1) end)
	else
		Debug("could not find a visible %s to auto-preview (non-fatal)", buttonName)
	end
end

local function OpenMountJournalFor(mountID)
	ToggleCollectionsJournal(1)
	Debug("TradeFrame IsShown=%s IsVisible=%s (checked right after opening the journal)",
		tostring(TradeFrame and TradeFrame:IsShown()), tostring(TradeFrame and TradeFrame:IsVisible()))
	local ok, name = pcall(C_MountJournal.GetMountInfoByID, mountID)
	if ok and name then
		if type(C_MountJournal.SetSearch) == "function" then
			C_MountJournal.SetSearch(name)
			Debug("C_MountJournal.SetSearch(%q)", name)
		end
		TryMirrorSearchBoxText("MountJournalSearchBox", name, 5)
		TryClickFirstResult("MountJournalListScrollFrameButton1", 5)
	end
end

local function OpenPetJournalFor(speciesID)
	ToggleCollectionsJournal(2)
	Debug("TradeFrame IsShown=%s IsVisible=%s (checked right after opening the journal)",
		tostring(TradeFrame and TradeFrame:IsShown()), tostring(TradeFrame and TradeFrame:IsVisible()))
	local ok, name = pcall(C_PetJournal.GetPetInfoBySpeciesID, speciesID)
	if ok and name then
		if type(C_PetJournal.SetSearchFilter) == "function" then
			C_PetJournal.SetSearchFilter(name)
			Debug("C_PetJournal.SetSearchFilter(%q)", name)
		end
		TryMirrorSearchBoxText("PetJournalSearchBox", name, 5)
		TryClickFirstResult("PetJournalListScrollFrameButton1", 5)
	end
end

-- ============================================================================
-- Ambiguous-icon picker: several mounts can share one icon (recolors,
-- variants), so when a clicked item's icon matches more than one, let the
-- player pick which one instead of guessing and opening the wrong one.
-- ============================================================================

local ROW_HEIGHT = 18
local FRAME_WIDTH = 240
local MAX_VISIBLE_ROWS = 8 -- beyond this many candidates, the list scrolls

-- Collected mounts are shown in normal (white) text, not-yet-collected ones
-- dimmed - same white/grey convention Blizzard's own Mount Journal uses to
-- show ownership (mounts have no quality/rarity of their own to color by).
local COLLECTED_COLOR = { 1, 1, 1 }
local UNCOLLECTED_COLOR = { 0.5, 0.5, 0.5 }

local pickerFrame, pickerScrollChild
local pickerRows = {}

local function GetOrCreateRow(index)
	if pickerRows[index] then return pickerRows[index] end
	local row = CreateFrame("Button", nil, pickerScrollChild)
	row:SetSize(FRAME_WIDTH - 16, ROW_HEIGHT)
	row:SetPoint("TOP", 0, -(index - 1) * ROW_HEIGHT)
	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", 2, 0)
	row.text:SetPoint("RIGHT", -2, 0)
	row.text:SetJustifyH("LEFT")

	pickerRows[index] = row
	return row
end

-- Entirely inert if ElvUI isn't installed. Only skins the window chrome
-- (backdrop/border, scrollbar, close button) - the rows stay plain text so
-- the list stays compact, rather than getting ElvUI's usual per-button
-- backdrop treatment. There's no generic S:HandleFrame in ElvUI's Skins
-- module (confirmed by reading its source: only HandleButton, HandleScrollBar,
-- HandleCloseButton, etc. exist there) - the actual mechanism for a plain
-- frame's border/background is :SetTemplate(), which ElvUI's core toolkit
-- patches onto every frame's metatable once it loads (so it works on a
-- frame from any addon, not just ElvUI's own).
local function SkinPickerForElvUI(frame, scrollFrame, closeButton)
	if not _G.ElvUI then return end
	local ok, E = pcall(unpack, _G.ElvUI)
	if not ok or not E then return end
	local S = E:GetModule("Skins")
	if not S then return end

	if type(frame.StripTextures) == "function" then
		pcall(frame.StripTextures, frame)
	end
	if type(frame.SetTemplate) == "function" then
		pcall(frame.SetTemplate, frame, "Default")
	end
	if scrollFrame then
		local scrollBar = _G[scrollFrame:GetName() .. "ScrollBar"]
		if scrollBar then
			pcall(S.HandleScrollBar, S, scrollBar)
		end
	end
	if closeButton then
		pcall(S.HandleCloseButton, S, closeButton)
	end
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
		frame.CloseButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
		frame.CloseButton:SetPoint("TOPRIGHT", -2, -2)
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

	local scrollFrame = CreateFrame("ScrollFrame", "MountPetLinkPickerScrollFrame", frame, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", 10, -28)
	scrollFrame:SetPoint("BOTTOMRIGHT", -28, 8)

	pickerScrollChild = CreateFrame("Frame", nil, scrollFrame)
	pickerScrollChild:SetSize(FRAME_WIDTH - 16, ROW_HEIGHT)
	scrollFrame:SetScrollChild(pickerScrollChild)

	tinsert(UISpecialFrames, "MountPetLinkPickerFrame")
	frame:Hide()
	pickerFrame = frame

	SkinPickerForElvUI(frame, scrollFrame, frame.CloseButton)
	return frame
end

local function ShowMountPicker(mountIDs)
	GetOrCreatePickerFrame()
	local numRows = #mountIDs
	local visibleRows = math.min(numRows, MAX_VISIBLE_ROWS)

	pickerFrame:SetSize(FRAME_WIDTH, 36 + visibleRows * ROW_HEIGHT)
	pickerScrollChild:SetHeight(numRows * ROW_HEIGHT)

	for i, mountID in ipairs(mountIDs) do
		local row = GetOrCreateRow(i)
		local ok, name, _, _, _, _, _, _, _, _, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
		row.text:SetText(ok and name or ("mountID " .. mountID))
		local color = isCollected and COLLECTED_COLOR or UNCOLLECTED_COLOR
		row.text:SetTextColor(color[1], color[2], color[3])
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
	Debug("TradeFrame IsShown=%s IsVisible=%s (checked BEFORE this addon does anything else)",
		tostring(TradeFrame and TradeFrame:IsShown()), tostring(TradeFrame and TradeFrame:IsVisible()))
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

			local itemName, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemID)
			local iconCandidates = itemIcon and iconToMountIDs[itemIcon]

			local seen, candidates = {}, {}
			local function AddCandidate(mountID)
				if mountID and not seen[mountID] then
					seen[mountID] = true
					tinsert(candidates, mountID)
				end
			end

			if iconCandidates and #iconCandidates == 1 then
				-- unambiguous icon match - trust it outright, skip the
				-- wider (and noisier) spell/name-stem search entirely
				Debug("itemIcon=%s -> exact single icon match, skipping widening", tostring(itemIcon))
				AddCandidate(iconCandidates[1])
			else
				if iconCandidates then
					for _, mountID in ipairs(iconCandidates) do AddCandidate(mountID) end
				end

				local _, spellID = GetItemSpell(itemID)
				if spellID == "" then spellID = nil end -- this server returns "" rather than nil for no-spell items
				spellID = tonumber(spellID)
				if spellID then AddCandidate(spellIDToMountID[spellID]) end

				if itemName then
					for stem in pairs(GetWordStems(itemName)) do
						local matches = stemToMountIDs[stem]
						if matches then
							for _, mountID in ipairs(matches) do AddCandidate(mountID) end
						end
					end
				end

				Debug("itemName=%s itemIcon=%s spellID=%s -> %d total candidate(s) (widened)",
					tostring(itemName), tostring(itemIcon), tostring(spellID), #candidates)
			end

			if #candidates == 1 then
				OpenMountJournalFor(candidates[1])
			elseif #candidates > 1 then
				ShowMountPicker(candidates)
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
		print(string.format("MountJournalListScrollFrameButton1=%s PetJournalListScrollFrameButton1=%s",
			tostring(MountJournalListScrollFrameButton1), tostring(PetJournalListScrollFrameButton1)))
		print(string.format("UIPanelWindows[CollectionsJournal].allowOtherPanels=%s",
			tostring(UIPanelWindows and UIPanelWindows["CollectionsJournal"] and UIPanelWindows["CollectionsJournal"].allowOtherPanels)))
		print(string.format("trade-close hook status: CloseTrade=%s HideUIPanel=%s TradeFrameOnHide=%s TRADE_CLOSED=%s",
			tostring(tradeHookStatus.CloseTrade), tostring(tradeHookStatus.HideUIPanel),
			tostring(tradeHookStatus.TradeFrameOnHide), tostring(tradeHookStatus.TRADE_CLOSED)))
		print("C_MountJournal: " .. ListFunctions(C_MountJournal))
		print("C_PetJournal: " .. ListFunctions(C_PetJournal))
	end
end

-- /mpltest <itemID> - dumps what each of the three matching signals (icon,
-- spell, name-stem) sees for a known itemID, instead of inferring it only
-- from a click that might not even be on a mount item.
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

	local function NamesOf(mountIDs)
		local out = {}
		if mountIDs then
			for _, mountID in ipairs(mountIDs) do
				local ok, mountName = pcall(C_MountJournal.GetMountInfoByID, mountID)
				tinsert(out, string.format("%d=%s", mountID, ok and mountName or "?"))
			end
		end
		return table.concat(out, ", ")
	end

	local iconCandidates = icon and iconToMountIDs[icon]
	local spellMountID = spellID and spellIDToMountID[spellID]

	local stemCandidates, stems = {}, {}
	if name then
		for stem in pairs(GetWordStems(name)) do
			tinsert(stems, stem)
			local matches = stemToMountIDs[stem]
			if matches then
				for _, mountID in ipairs(matches) do tinsert(stemCandidates, mountID) end
			end
		end
	end

	print(string.format("|cff33ccff[MountPetLink]|r itemID=%d name=%s icon=%s (%s)", itemID, tostring(name), tostring(icon), type(icon)))
	print(string.format("  icon match: %d candidate(s): %s", iconCandidates and #iconCandidates or 0, NamesOf(iconCandidates)))
	print(string.format("  spell match: spellName=%s spellID=%s -> %s",
		tostring(spellName), tostring(spellID), spellMountID and NamesOf({spellMountID}) or "none"))
	print(string.format("  name-stem match: stems=%s -> %d candidate(s): %s",
		table.concat(stems, ","), #stemCandidates, NamesOf(stemCandidates)))
end

-- /mplfind <substring> - lists every mount whose name contains the given
-- text (case-insensitive), with its mountID and icon (+ type). Lets us
-- check a specific mount's real icon value directly against an item's,
-- instead of inferring why an icon match missed it.
SLASH_MOUNTPETLINKFIND1 = "/mplfind"
SlashCmdList["MOUNTPETLINKFIND"] = function(msg)
	if not msg or msg == "" then
		print("|cff33ccff[MountPetLink]|r usage: /mplfind <substring>")
		return
	end
	local needle = msg:lower()
	local CMJ = C_MountJournal
	local mountIDs

	if type(CMJ.GetMountIDs) == "function" then
		local ok, ids = pcall(CMJ.GetMountIDs)
		if ok then mountIDs = ids end
	end

	local found = 0
	if mountIDs then
		for _, mountID in ipairs(mountIDs) do
			local ok, name, spellID, icon = pcall(CMJ.GetMountInfoByID, mountID)
			if ok and name and name:lower():find(needle, 1, true) then
				found = found + 1
				print(string.format("|cff33ccff[MountPetLink]|r mountID=%d name=%s icon=%s (%s) spellID=%s",
					mountID, name, tostring(icon), type(icon), tostring(spellID)))
			end
		end
	end
	if found == 0 then
		print("|cff33ccff[MountPetLink]|r no mount name matched, or GetMountIDs isn't available")
	end
end
