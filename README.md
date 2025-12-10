# new_buildTeamSchemeCsv.ps1 - Script Documentation

## Overview

`new_buildTeamSchemeCsv.ps1` is a PowerShell script that generates an **Automation Schemes CSV file** for FISR (Fault Isolation and Service Restoration) device participation in electrical distribution systems. The script processes feeder data and device information from XML files to create a hierarchical CSV structure containing automation schemes, teams, and team switches.

## Purpose

This script builds a CSV file (`AutomationSchemes.csv`) that defines:
- **Automation schemes** organized by electrical substations
- **Teams** representing individual feeders with FISR capabilities
- **Team switches** listing all automated devices (switches, reclosers, breakers) associated with each feeder

This data is used to configure automation systems for managing electrical grid operations.

## Input Files

The script reads from several input sources:

1. **`fisrfeeders.txt`** - A text file containing a list of feeder names to process
2. **Feeder XML files** - Located in the ETL directory (`{feeder}.xml`), containing:
   - Circuit connectivity information
   - Substation associations
   - Device identifiers (mRIDs) for switches, reclosers, and composite switches
3. **Substation INTERNALS XML files** - Located in the processing directory (`{substation}_INTERNALS.xml`), containing:
   - Switch status measurements
   - Breaker information
   - Device details

## Processing Logic

### 1. Feeder Processing
For each feeder listed in `fisrfeeders.txt`:
- Loads the corresponding feeder XML file from the ETL directory
- Extracts the substation name associated with the feeder
- Collects device mRIDs for:
  - Switches and Reclosers (using their mRID values)
  - Composite Switches (appending "_CS" suffix to their mRIDs)

### 2. Device Matching
- Loads the substation's INTERNALS XML file (with caching for performance)
- Identifies automated devices by matching:
  - Status measurements with `SwitchStatusMeasurementType`
  - Breakers associated with the feeder name
- Stores matched device IDs in a dictionary organized by feeder

### 3. CSV Generation
The script generates a three-section CSV file with a specific structure:

#### Section 1: SCHEME (Substations)
```
SCHEME,0,ID_SCHEME,NAME_SCHEME,DESCRIPTION_SCHEME,,,,
SCHEME,1,{SUBSTATION}_SCHEME,{SUBSTATION}_SCHEME,Automation Scheme,,,,
```
- Creates one entry per unique substation
- **Deduplicates** substations to avoid duplicate ID_SCHEME values
- Uses uppercase substation names

#### Section 2: TEAM (Feeders)
```
TEAM,0,ID_TEAM,SCHEME_TEAM,NAME_TEAM,DESCRIPTION_TEAM,,,
TEAM,1,{FEEDER}_TEAM,{SUBSTATION}_SCHEME,{FEEDER} FISR,{FEEDER} FISR,,,
```
- Creates one entry per feeder
- Links each team to its parent scheme (substation)
- Uses uppercase feeder names

#### Section 3: TEAMSWITCH (Devices)
```
TEAMSWITCH,0,ID_TEAMSW,TEAM_TEAMSW,NAME_TEAMSW,SECONDID_TEAMSW,STATION1_TEAMSW,STATION2_TEAMSW,ROLE_TEAMSW
TEAMSWITCH,1,{DEVICE_ID},{FEEDER}_TEAM,na,na,{SUBSTATION},,PRIMARY
```
- Creates one entry per device in each feeder
- Links each device to its parent team (feeder)
- All devices are assigned the "PRIMARY" role

## Output

### Output File
- **Location**: `{processingDir}/AutomationSchemes.csv`
- **Encoding**: UTF-8
- **Format**: CSV with comma-separated values

### Log File
- **Location**: `{processingDir}/fisrfeeders.log`
- **Contains**: Processing status, errors, and missing file warnings

## Key Features

### 1. Caching
- Substation INTERNALS XML files are cached in memory to improve performance when multiple feeders reference the same substation

### 2. Deduplication
- The SCHEME section deduplicates substations by name to prevent duplicate entries in the CSV output
- This addresses an issue where multiple feeders from the same substation could create duplicate scheme records

### 3. Error Handling
- Logs missing feeder XML files
- Logs missing substation INTERNALS files
- Handles XML parsing errors gracefully
- Continues processing remaining feeders if individual feeders fail

### 4. Data Transformation
- Converts all names to uppercase for consistency
- Appends "_SCHEME" suffix to scheme identifiers
- Appends "_TEAM" suffix to team identifiers
- Appends "_CS" suffix to composite switch mRIDs

## Directory Structure

The script uses the following default directory structure (paths are configurable in the script):

```
{workspace_root}\ToolsWorkspace\
├── Converter\input\              # Processing directory (configurable: $processingDir)
│   ├── fisrfeeders.txt          # Input: List of feeders
│   ├── {SUB}_INTERNALS.xml      # Input: Substation device data
│   ├── AutomationSchemes.tmp    # Temporary output file
│   ├── AutomationSchemes.csv    # Final output file
│   └── fisrfeeders.log          # Processing log
└── ETL\input\                    # ETL directory (configurable: $etlDir)
    └── {FEEDER}.xml             # Input: Feeder XML files
```

**Note**: The default paths in the script are:
- Processing directory: `E:\Eterra\distribution\sce\ToolsWorkspace\Converter\input\`
- ETL directory: `E:\Eterra\distribution\sce\ToolsWorkspace\ETL\input\`

These can be modified at the top of the script to match your environment.

## Example Output Structure

```csv
SCHEME,0,ID_SCHEME,NAME_SCHEME,DESCRIPTION_SCHEME,,,,
SCHEME,1,RIO HONDO_SCHEME,RIO HONDO_SCHEME,Automation Scheme,,,,
SCHEME,1,CITRUS_SCHEME,CITRUS_SCHEME,Automation Scheme,,,,
,,,,,,,,
TEAM,0,ID_TEAM,SCHEME_TEAM,NAME_TEAM,DESCRIPTION_TEAM,,,
TEAM,1,TIGRIS_TEAM,RIO HONDO_SCHEME,TIGRIS FISR,TIGRIS FISR,,,
TEAM,1,PINEAPPLE_TEAM,CITRUS_SCHEME,PINEAPPLE FISR,PINEAPPLE FISR,,,
,,,,,,,,
TEAMSWITCH,0,ID_TEAMSW,TEAM_TEAMSW,NAME_TEAMSW,SECONDID_TEAMSW,STATION1_TEAMSW,STATION2_TEAMSW,ROLE_TEAMSW
TEAMSWITCH,1,4735672E:RCS1570,TIGRIS_TEAM,na,na,RIO HONDO,,PRIMARY
TEAMSWITCH,1,E20438Y:RCS0268,PINEAPPLE_TEAM,na,na,CITRUS,,PRIMARY
```

## Usage

Run the script from PowerShell:

```powershell
.\new_buildTeamSchemeCsv.ps1
```

The script will:
1. Read the list of feeders from `fisrfeeders.txt`
2. Process each feeder's XML data
3. Generate the AutomationSchemes.csv file
4. Create a log file with processing details

## Dependencies

- PowerShell (Windows PowerShell or PowerShell Core)
- Access to the specified input directories
- Well-formed XML files for feeders and substations
- Appropriate file system permissions

## Error Messages

The script logs various error conditions:
- `"Failed to parse feeder XML for {feeder} at {path}"` - XML parsing failed
- `"{substation}_INTERNALS.xml substation file not found..."` - Missing substation data
- `"{feeder}.xml feeders file not found..."` - Missing feeder XML
- `"FISR feeders file not found..."` - Missing fisrfeeders.txt input file

## Version History

This is the "new" version of the script, which includes improvements over `old_buildTeamSchemeCsv.ps1`, particularly in the area of substation deduplication in the SCHEME section.
