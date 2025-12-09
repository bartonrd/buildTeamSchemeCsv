# Analysis of Automation Schemes Duplicate ID Issue

## Problem Statement

The system build tool generates warnings in `TELEGRAPH.log` and `PIXLEY.log` indicating duplicate SCHEME records in the `AutomationSchemes.csv` file. These warnings have the format:

```
-W-,FWF210,,Data record field is not unique. This record will not be loaded.,
StationName:TELEGRAPH,Automation Scheme record ID: RIO HONDO_SCHEME is duplicated in AutomationSchemes.csv file.
```

## Root Cause Analysis

### The Issue
The PowerShell scripts (`new_buildTeamSchemeCsv.ps1` and `old_buildTeamSchemeCsv.ps1`) generate SCHEME records in the CSV file using the following pattern:

**Before Fix:**
```powershell
$subNameUpper = [string]$feederSubDict[$key].ToUpper()
$feederNameUpper = [string]$key.ToUpper()
$csvLines.Add("SCHEME,1," + $subNameUpper + "_SCHEME," + $subNameUpper + "_SCHEME," + $feederNameUpper + " FISR,,,,")
```

This creates entries like:
```csv
SCHEME,1,RIO HONDO_SCHEME,RIO HONDO_SCHEME,TIGRIS FISR,,,,
SCHEME,1,RIO HONDO_SCHEME,RIO HONDO_SCHEME,POWDER FISR,,,,
SCHEME,1,RIO HONDO_SCHEME,RIO HONDO_SCHEME,WASH FISR,,,,
```

**Problem:** Multiple feeders (TIGRIS, POWDER, WASH) belong to the same substation (RIO HONDO), causing the same SCHEME ID ("RIO HONDO_SCHEME") to appear multiple times with different descriptions.

### CSV Structure
```
Column 3 (ID_SCHEME): Must be unique - this is the primary key
Column 4 (NAME_SCHEME): Display name
Column 5 (DESCRIPTION_SCHEME): Descriptive text including feeder name
```

## Solution

Change the SCHEME ID generation to use **feeder names** instead of **substation names** to ensure uniqueness:

**After Fix:**
```powershell
$subNameUpper = [string]$feederSubDict[$key].ToUpper()
$feederNameUpper = [string]$key.ToUpper()
$csvLines.Add("SCHEME,1," + $feederNameUpper + "_SCHEME," + $feederNameUpper + "_SCHEME," + $feederNameUpper + " FISR,,,,")
```

This creates unique entries:
```csv
SCHEME,1,TIGRIS_SCHEME,TIGRIS_SCHEME,TIGRIS FISR,,,,
SCHEME,1,POWDER_SCHEME,POWDER_SCHEME,POWDER FISR,,,,
SCHEME,1,WASH_SCHEME,WASH_SCHEME,WASH FISR,,,,
```

### Additional Change Required
The TEAM section references SCHEME IDs via the `SCHEME_TEAM` column, so it must also be updated:

**Before:**
```powershell
$csvLines.Add("TEAM,1," + $feederNameUpper + "_TEAM," + $subNameUpper + "_SCHEME," + ...)
```

**After:**
```powershell
$csvLines.Add("TEAM,1," + $feederNameUpper + "_TEAM," + $feederNameUpper + "_SCHEME," + ...)
```

## Test Results

### Before Fix
- Total SCHEME entries: 4 (for RIO HONDO substation with 4 feeders)
- Unique SCHEME IDs: 1 (all entries use "RIO HONDO_SCHEME")
- Result: ✗ Duplicate SCHEME IDs detected

### After Fix
- Total SCHEME entries: 4
- Unique SCHEME IDs: 4 (TIGRIS_SCHEME, POWDER_SCHEME, WASH_SCHEME, PECOS_SCHEME)
- All TEAM records reference valid SCHEME IDs
- Result: ✓ No duplicate SCHEME IDs found

## Impact

This fix will:
1. ✅ Eliminate all FWF210 warnings in TELEGRAPH.log and PIXLEY.log
2. ✅ Ensure all SCHEME records are loaded by the build tool
3. ✅ Maintain referential integrity between TEAM and SCHEME records
4. ✅ Make SCHEME IDs more intuitive (feeder-based vs substation-based)

## Files Modified

1. `new_buildTeamSchemeCsv.ps1` - Lines 104 and 113
2. `old_buildTeamSchemeCsv.ps1` - Lines 69 and 76

## Verification

To verify the fix works correctly:
1. Run the updated script with actual input data
2. Check the generated `AutomationSchemes.csv` for duplicate ID_SCHEME values
3. Run the system build tool and verify no FWF210 warnings appear in the log files
