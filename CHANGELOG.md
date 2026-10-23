# Changelog

## 1.0.3 - 2026-10-23

- Prevented Enter in current-loadout mode from invoking Blizzard's new-loadout import.
- Removed the synthetic loadout name written into Blizzard's import dialog.
- Blocked current-loadout imports during combat, while inspecting, or when the config cannot be edited.
- Stop on reset failure and report incomplete purchases instead of silently succeeding.
- Preserve partial rank-purchase progress and skip automatically granted talents.
- Reject invalid characters and truncated talent strings before resetting talents.

## 1.0.2 - 2026-10-15

- Updated the Retail interface version to 120105 for World of Warcraft 12.1.5.

## 1.0.1 - 2026-08-12

- Updated the Retail interface version to 120100 for World of Warcraft 12.1.0.

## 1.0.0 - 2026-08-03

- Initial release.
- Adds an option to import a talent string into the currently selected loadout.
- Keeps Blizzard's Apply Changes step manual to avoid tainting the talent UI.
- Validates the specialization, serialization version, and talent tree hash before importing.
