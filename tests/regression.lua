-- Run from the repository root with Lua 5.1+.
local errors, purchases, resets = {}, 0, 0
StaticPopupDialogs = {}
OKAY = "OK"
LOADOUT_ERROR_IMPORT_FAILED = "failed"
LOADOUT_ERROR_BAD_STRING = "bad string"
C_ClassTalents = { GetActiveConfigID = function() return 1 end }
C_Traits = {
    GetConfigInfo = function() return { treeIDs = { 2 } } end,
    CanEditConfig = function() return true end,
    ResetTree = function() resets = resets + 1; return true end,
}
StaticPopup_Show = function(_, message) errors[#errors + 1] = message end
CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end
C_AddOns = { IsAddOnLoaded = function() return false end }
InCombatLockdown = function() return false end
PlayerSpellsFrame = { TalentsFrame = { IsInspecting = function() return false end } }
Enum = { TraitNodeType = { Selection = 2, SubTreeSelection = 3 } }

local file = assert(io.open("EasyTalentImport.lua", "r"))
local source = file:read("*a")
file:close()
local compile = loadstring or load
local api = assert(compile(source .. [[
return {
    purchase = PurchaseEntries,
    apply = ApplyEntriesToCurrentLoadout,
    convert = ConvertLoadoutContent,
    import = ImportIntoCurrentLoadout,
    updateDialog = UpdateDialogMode,
    setControls = function(checkbox, button) importCheckbox = checkbox; importButton = button end,
    setup = SetupTalentImportDialog,
}
]]))("EasyTalentImport")

-- A failed reset must not purchase any nodes.
C_Traits.ResetTree = function() resets = resets + 1; return false end
C_Traits.PurchaseRank = function() purchases = purchases + 1; return true end
assert(api.apply({ { nodeID = 3, ranksPurchased = 1 } }) == false)
assert(purchases == 0)

-- Config edit restrictions must be checked before resetting.
C_Traits.CanEditConfig = function() return false, "restricted" end
local before = resets
assert(api.apply({}) == false and resets == before and errors[#errors] == "restricted")
C_Traits.CanEditConfig = function() return true end
C_Traits.ResetTree = function() resets = resets + 1; return true end

-- Partial progress survives retries; already purchased ranks are not purchased twice.
local calls = 0
C_Traits.PurchaseRank = function()
    calls = calls + 1
    return calls ~= 2
end
local entries = { { nodeID = 3, ranksPurchased = 2 } }
assert(api.purchase(1, entries) > 0 and entries[1].ranksPurchased == 1)
assert(api.purchase(1, entries) > 0 and next(entries) == nil and calls == 3)

-- An unpurchasable node must not report a successful import.
C_Traits.PurchaseRank = function() return false end
assert(api.apply({ { nodeID = 3, ranksPurchased = 1 } }) == false)
assert(api.apply({}) == true)

-- Granted talents are restored by ResetTree and must not be bought again.
C_Traits.GetTreeNodes = function() return { 3, 4 } end
C_Traits.GetNodeInfo = function(_, id) return { ID = id, type = 1, maxRanks = 1 } end
entries = api.convert(2, {
    { isNodeSelected = true, isNodeGranted = true },
    { isNodeSelected = true, isNodeGranted = false, isChoiceNode = false },
})
assert(#entries == 1 and entries[1].nodeID == 4)

-- Combat and inspecting must fail before touching the parser or talent tree.
InCombatLockdown = function() return true end
assert(api.import("A") == false)
InCombatLockdown = function() return false end
PlayerSpellsFrame.TalentsFrame.IsInspecting = function() return true end
assert(api.import("A") == false)
PlayerSpellsFrame.TalentsFrame.IsInspecting = function() return false end
assert(api.import("invalid!") == false and errors[#errors] == "bad string")

-- A truncated stream must fail before resetting, even if Blizzard's reader
-- would otherwise treat missing bits as unselected nodes.
ClassTalentImportExportMixin = {
    bitWidthHeaderVersion = 8, bitWidthSpecID = 16,
    ReadLoadoutHeader = function() return true, nil, 1, {} end,
    IsHashEmpty = function() return true end,
    ReadLoadoutContent = function(_, stream)
        stream:ExtractValue(1)
        stream:ExtractValue(6)
        return {}
    end,
}
PlayerUtil = { GetCurrentSpecID = function() return 1 end }
ExportUtil = { MakeImportDataStream = function()
    return { GetNumberOfBits = function() return 156 end, ExtractValue = function() return 0 end }
end }
before = resets
assert(api.import("AAAA") == false and resets == before and errors[#errors] == "bad string")

-- In current-loadout mode, Enter's hidden standard button stays disabled.
local checked = true
local accept = { SetShown = function() end, SetEnabled = function(self, enabled) self.enabled = enabled end }
local dialog = {
    NameControl = { SetShown = function() end },
    ImportControl = { HasText = function() return true end },
    AcceptButton = accept,
    UpdateAcceptButtonEnabledState = function() accept:SetEnabled(true) end,
}
api.setControls({ GetChecked = function() return checked end }, {
    SetShown = function() end, SetEnabled = function() end,
})
api.updateDialog(dialog)
assert(accept.enabled == false)
checked = false
api.updateDialog(dialog)
assert(accept.enabled == true)

-- Exercise the installed post-hook as Blizzard updates its accept state.
local function control()
    return setmetatable({}, { __index = function(_, key)
        if key == "CreateFontString" then return control end
        if key == "GetStringWidth" then return function() return 10 end end
        if key == "GetChecked" then return function(self) return self.checked end end
        if key == "SetChecked" then return function(self, value) self.checked = value end end
        return function() end
    end })
end
CreateFrame = control
hooksecurefunc = function(object, name, hook)
    local original = object[name]
    object[name] = function(...) original(...); hook(...) end
end
ClassTalentLoadoutImportDialog = dialog
TALENT_FRAME_APPLY_BUTTON_TEXT = "Apply Changes"
api.setup()
accept:SetEnabled(true)
dialog:UpdateAcceptButtonEnabledState()
assert(accept.enabled == false)
print("All regression checks passed")
