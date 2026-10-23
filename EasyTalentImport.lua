local ADDON_NAME = ...
local PLAYER_SPELLS_ADDON = "Blizzard_PlayerSpells"

local importCheckbox
local importButton
local isSetup = false
local serializationVersion

StaticPopupDialogs.EASY_TALENT_IMPORT_ERROR = {
    text = "%s",
    button1 = OKAY,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

local function ShowImportError(message)
    StaticPopup_Show("EASY_TALENT_IMPORT_ERROR", message)
end

local function GetActiveTreeID()
    local configID = C_ClassTalents.GetActiveConfigID()
    local configInfo = configID and C_Traits.GetConfigInfo(configID)
    return configInfo and configInfo.treeIDs and configInfo.treeIDs[1]
end

local function PurchaseEntries(configID, entries)
    local completed = 0

    for index, entry in pairs(entries) do
        local success = false

        if entry.selectionEntryID then
            success = C_Traits.SetSelection(configID, entry.nodeID, entry.selectionEntryID)
        elseif entry.ranksPurchased then
            while entry.ranksPurchased > 0 do
                success = C_Traits.PurchaseRank(configID, entry.nodeID)
                if not success then
                    break
                end
                entry.ranksPurchased = entry.ranksPurchased - 1
                completed = completed + 1
            end
            success = entry.ranksPurchased == 0
        end

        if success then
            entries[index] = nil
            completed = completed + 1
        end
    end

    return completed
end

local function ApplyEntriesToCurrentLoadout(entries)
    local configID = C_ClassTalents.GetActiveConfigID()
    local treeID = GetActiveTreeID()
    if not configID or not treeID then
        return false
    end

    local canEdit, errorMessage = C_Traits.CanEditConfig(configID)
    if not canEdit then
        ShowImportError(errorMessage or LOADOUT_ERROR_IMPORT_FAILED)
        return false
    end

    if not C_Traits.ResetTree(configID, treeID) then
        ShowImportError(LOADOUT_ERROR_IMPORT_FAILED)
        return false
    end

    -- Some nodes only become purchasable after their prerequisites. Keep making
    -- passes until no additional node can be purchased.
    while PurchaseEntries(configID, entries) > 0 do
    end

    if next(entries) then
        ShowImportError("Some talents could not be imported. Review the staged talents or undo the changes before applying.")
        return false
    end

    -- Deliberately do not call CommitConfig here. The normal Apply button is
    -- secure; letting the player click it avoids taint in Blizzard's talent UI.
    return true
end

local function ConvertLoadoutContent(treeID, loadoutContent)
    local entries = {}
    local treeNodes = C_Traits.GetTreeNodes(treeID)
    local configID = C_ClassTalents.GetActiveConfigID()

    for index, nodeID in ipairs(treeNodes) do
        local importedNode = loadoutContent[index]

        if importedNode and importedNode.isNodeSelected and not importedNode.isNodeGranted then
            local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
            if nodeInfo then
                local isChoiceNode = nodeInfo.type == Enum.TraitNodeType.Selection
                    or nodeInfo.type == Enum.TraitNodeType.SubTreeSelection
                local choiceIndex = importedNode.isChoiceNode and importedNode.choiceNodeSelection or nil

                if isChoiceNode ~= importedNode.isChoiceNode then
                    print(string.format(
                        "|cffffd200%s:|r The import string contains an invalid talent at node %d; the first option will be used.",
                        ADDON_NAME,
                        nodeID
                    ))
                    choiceIndex = 1
                end

                entries[#entries + 1] = {
                    nodeID = nodeInfo.ID,
                    ranksPurchased = importedNode.isPartiallyRanked
                        and importedNode.partialRanksPurchased
                        or nodeInfo.maxRanks,
                    selectionEntryID = isChoiceNode and nodeInfo.entryIDs[choiceIndex] or nil,
                }
            end
        end
    end

    return entries
end

local function ImportIntoCurrentLoadout(importText)
    -- The dialog can remain open while combat starts. Check again at click time.
    if InCombatLockdown() then
        ShowImportError("Talents cannot be imported during combat.")
        return false
    end

    if PlayerSpellsFrame.TalentsFrame:IsInspecting() then
        ShowImportError(LOADOUT_ERROR_IMPORT_FAILED)
        return false
    end

    if not importText:match("^[A-Za-z0-9+/]+$") then
        ShowImportError(LOADOUT_ERROR_BAD_STRING)
        return false
    end

    local importExportMixin = ClassTalentImportExportMixin
    local importStream = ExportUtil.MakeImportDataStream(importText)
    local headerValid, version, specID, treeHash = importExportMixin:ReadLoadoutHeader(importStream)

    if not headerValid then
        ShowImportError(LOADOUT_ERROR_BAD_STRING)
        return false
    end

    if version ~= serializationVersion then
        ShowImportError(LOADOUT_ERROR_SERIALIZATION_VERSION_MISMATCH)
        return false
    end

    if specID ~= PlayerUtil.GetCurrentSpecID() then
        ShowImportError(LOADOUT_ERROR_WRONG_SPEC)
        return false
    end

    local treeID = GetActiveTreeID()
    if not treeID then
        ShowImportError(LOADOUT_ERROR_BAD_STRING)
        return false
    end

    if not importExportMixin:IsHashEmpty(treeHash)
        and not importExportMixin:HashEquals(treeHash, C_Traits.GetTreeHash(treeID)) then
        ShowImportError(LOADOUT_ERROR_TREE_CHANGED)
        return false
    end

    -- Blizzard's reader treats an exhausted one-bit read as an unselected node.
    -- Bound every read so truncated input cannot silently reset missing talents.
    local remainingBits = importStream:GetNumberOfBits()
        - importExportMixin.bitWidthHeaderVersion - importExportMixin.bitWidthSpecID - 128
    local checkedStream = {
        ExtractValue = function(_, bitWidth)
            if bitWidth > remainingBits then
                error("Incomplete talent import string")
            end
            remainingBits = remainingBits - bitWidth
            return importStream:ExtractValue(bitWidth)
        end,
    }
    local contentValid, loadoutContent = pcall(
        importExportMixin.ReadLoadoutContent, importExportMixin, checkedStream, treeID
    )
    if not contentValid or not loadoutContent then
        ShowImportError(LOADOUT_ERROR_BAD_STRING)
        return false
    end

    local entries = ConvertLoadoutContent(treeID, loadoutContent)
    return ApplyEntriesToCurrentLoadout(entries)
end

local function UpdateDialogMode(dialog)
    local importCurrent = importCheckbox:GetChecked()

    dialog.NameControl:SetShown(not importCurrent)
    importButton:SetShown(importCurrent)
    dialog.AcceptButton:SetShown(not importCurrent)

    if importCurrent then
        importButton:SetEnabled(dialog.ImportControl:HasText())
    else
        dialog:UpdateAcceptButtonEnabledState()
    end
    -- Enter invokes Blizzard's OnAccept even when AcceptButton is hidden.
    -- Keep that path disabled rather than replacing a Blizzard handler.
    if importCurrent then
        dialog.AcceptButton:SetEnabled(false)
    end
end

local function SetupTalentImportDialog()
    if isSetup or not ClassTalentLoadoutImportDialog then
        return
    end
    isSetup = true

    serializationVersion = C_Traits.GetLoadoutSerializationVersion
        and C_Traits.GetLoadoutSerializationVersion()
        or 1

    local dialog = ClassTalentLoadoutImportDialog

    importCheckbox = CreateFrame("CheckButton", nil, dialog, "UICheckButtonTemplate")
    importCheckbox:SetPoint("TOPLEFT", dialog.NameControl, "BOTTOMLEFT", 0, 20)
    importCheckbox:SetSize(24, 24)
    importCheckbox:SetChecked(true)

    importCheckbox.label = importCheckbox:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    importCheckbox.label:SetPoint("LEFT", importCheckbox, "RIGHT", 0, 1)
    importCheckbox.label:SetText(string.format(
        "Import into current loadout (click \"%s\" afterwards)",
        TALENT_FRAME_APPLY_BUTTON_TEXT
    ))
    importCheckbox:SetHitRectInsets(-10, -importCheckbox.label:GetStringWidth(), -5, 0)

    importButton = CreateFrame("Button", nil, dialog, "ClassTalentLoadoutDialogButtonTemplate")
    importButton:SetPoint("BOTTOMRIGHT", dialog.ContentArea, "BOTTOM", -5, 0)
    importButton:SetText(HUD_CLASS_TALENTS_IMPORT_LOADOUT_ACCEPT_BUTTON)
    importButton.disabledTooltip = HUD_CLASS_TALENTS_IMPORT_ERROR_IMPORT_STRING_AND_NAME
    importButton:SetScript("OnClick", function()
        if ImportIntoCurrentLoadout(dialog.ImportControl:GetText()) then
            dialog:OnCancel()
        end
    end)

    importCheckbox:SetScript("OnClick", function()
        UpdateDialogMode(dialog)
    end)
    importCheckbox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Easy Talent Import")
        GameTooltip:AddLine(
            "Replaces the talents in the selected loadout. Click Apply Changes afterwards.",
            1,
            1,
            1,
            true
        )
        GameTooltip:Show()
    end)
    importCheckbox:SetScript("OnLeave", GameTooltip_Hide)

    hooksecurefunc(dialog, "UpdateAcceptButtonEnabledState", function()
        if importCheckbox:GetChecked() then
            dialog.AcceptButton:SetEnabled(false)
            importButton:SetEnabled(dialog.ImportControl:HasText())
        end
    end)

    UpdateDialogMode(dialog)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(_, _, loadedAddon)
    if loadedAddon == PLAYER_SPELLS_ADDON then
        SetupTalentImportDialog()
    end
end)

if C_AddOns.IsAddOnLoaded(PLAYER_SPELLS_ADDON) then
    SetupTalentImportDialog()
end
