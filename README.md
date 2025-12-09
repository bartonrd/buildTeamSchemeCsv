# Build Team Scheme CSV Tool

## Overview
This repository contains PowerShell scripts that generate `AutomationSchemes.csv` files for the system build tool. The CSV files define automation schemes, teams, and team switches for distribution automation systems.

## Scripts

### `new_buildTeamSchemeCsv.ps1`
The current version of the script that:
- Reads feeder information from `fisrfeeders.txt`
- Parses GCM feeder models from ETL XML files
- Extracts switch and recloser device information
- Generates a properly formatted `AutomationSchemes.csv` file

### `old_buildTeamSchemeCsv.ps1`
The legacy version maintained for reference and backwards compatibility.

## Input Files

### Required Files
1. **fisrfeeders.txt** - List of feeder names to process
2. **Feeder XML files** - Located in ETL input directory (e.g., `TIGRIS.xml`)
3. **Substation Internals XML** - Located in processing directory (e.g., `TELEGRAPH_INTERNALS.xml`)

## Output Format

The generated `AutomationSchemes.csv` has three sections:

### 1. SCHEME Section
Defines automation schemes with unique IDs based on feeder names:
```csv
SCHEME,0,ID_SCHEME,NAME_SCHEME,DESCRIPTION_SCHEME,,,,
SCHEME,1,TIGRIS_SCHEME,TIGRIS_SCHEME,TIGRIS FISR,,,,
```

### 2. TEAM Section
Defines teams that belong to schemes:
```csv
TEAM,0,ID_TEAM,SCHEME_TEAM,NAME_TEAM,DESCRIPTION_TEAM,,,
TEAM,1,TIGRIS_TEAM,TIGRIS_SCHEME,TIGRIS FISR,TIGRIS FISR,,,
```

### 3. TEAMSWITCH Section
Maps devices to teams:
```csv
TEAMSWITCH,0,ID_TEAMSW,TEAM_TEAMSW,NAME_TEAMSW,SECONDID_TEAMSW,STATION1_TEAMSW,STATION2_TEAMSW,ROLE_TEAMSW
TEAMSWITCH,1,DEVICE_ID,TIGRIS_TEAM,na,na,TIGRIS,,PRIMARY
```

## Recent Fixes

### Duplicate SCHEME ID Issue (December 2025)
**Problem:** Multiple feeders from the same substation created duplicate SCHEME IDs, causing FWF210 warnings.

**Solution:** Changed SCHEME IDs from substation-based (e.g., "RIO HONDO_SCHEME") to feeder-based (e.g., "TIGRIS_SCHEME") to ensure uniqueness.

**Files Changed:**
- `new_buildTeamSchemeCsv.ps1` - Lines 104, 113
- `old_buildTeamSchemeCsv.ps1` - Lines 69, 76

See [ISSUE_ANALYSIS.md](ISSUE_ANALYSIS.md) for detailed analysis.

## Usage

Run the script from PowerShell:
```powershell
.\new_buildTeamSchemeCsv.ps1
```

The script will:
1. Read the feeder list from `fisrfeeders.txt`
2. Process each feeder's XML files
3. Generate `AutomationSchemes.tmp`
4. Atomically move it to `AutomationSchemes.csv`
5. Log progress to `fisrfeeders.log`

## Validation

After running the script:
1. Check `fisrfeeders.log` for any errors
2. Verify `AutomationSchemes.csv` has no duplicate SCHEME IDs
3. Run the system build tool
4. Confirm no FWF210 warnings appear in log files

## Directory Structure
```
E:\Eterra\distribution\sce\ToolsWorkspace\
├── Converter\input\           # Processing directory
│   ├── fisrfeeders.txt        # Input: Feeder list
│   ├── *_INTERNALS.xml        # Input: Substation data
│   ├── AutomationSchemes.csv  # Output: Generated CSV
│   └── fisrfeeders.log        # Output: Processing log
└── ETL\input\                 # ETL directory
    └── *.xml                  # Input: Feeder models
```

## Testing

Test scripts are available to validate the fix:
- `test_fix.ps1` - Tests the corrected logic
- `test_old_logic.ps1` - Demonstrates the original issue
- `comprehensive_test.ps1` - Full validation suite

Run with:
```powershell
pwsh -File test_fix.ps1
```

## Support

For issues or questions about this tool, please open an issue in the repository.
