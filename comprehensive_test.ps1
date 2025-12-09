# Test both new and old script logic with the fix

Write-Output "=== Testing NEW Script Logic (Fixed) ==="
Write-Output ""

# Simulate the data structure
$feederDeviceDict = @{
    "TIGRIS" = @("device1", "device2")
    "POWDER" = @("device3", "device4")
    "WASH" = @("device5")
    "PECOS" = @("device6")
}

$feederSubDict = @{
    "TIGRIS" = "RIO HONDO"
    "POWDER" = "RIO HONDO"
    "WASH" = "RIO HONDO"
    "PECOS" = "RIO HONDO"
}

$csvLines = [System.Collections.Generic.List[string]]::new()

# NEW SCRIPT LOGIC - SCHEME section
$csvLines.Add("SCHEME,0,ID_SCHEME,NAME_SCHEME,DESCRIPTION_SCHEME,,,,")
foreach ($key in $feederDeviceDict.Keys) {
    $subNameUpper = [string]$feederSubDict[$key].ToUpper()
    $feederNameUpper = [string]$key.ToUpper()
    $csvLines.Add("SCHEME,1," + $feederNameUpper + "_SCHEME," + $feederNameUpper + "_SCHEME," + $feederNameUpper + " FISR,,,,")
}

# TEAM section
$csvLines.Add(",,,,,,,,")
$csvLines.Add("TEAM,0,ID_TEAM,SCHEME_TEAM,NAME_TEAM,DESCRIPTION_TEAM,,,")
foreach ($key in $feederDeviceDict.Keys) {
    $subNameUpper = [string]$feederSubDict[$key].ToUpper()
    $feederNameUpper = [string]$key.ToUpper()
    $csvLines.Add("TEAM,1," + $feederNameUpper + "_TEAM," + $feederNameUpper + "_SCHEME," + $feederNameUpper + " FISR," + $feederNameUpper + " FISR,,,")
}

Write-Output "NEW Script Output (first 15 lines):"
$csvLines | Select-Object -First 15 | ForEach-Object { Write-Output $_ }

# Validate uniqueness
Write-Output ""
Write-Output "NEW Script Validation:"
$schemeIds = $csvLines | Where-Object { $_ -match "^SCHEME,1," } | ForEach-Object {
    ($_ -split ",")[2]
}
$uniqueIds = $schemeIds | Select-Object -Unique
Write-Output "  Total SCHEME entries: $($schemeIds.Count)"
Write-Output "  Unique SCHEME IDs: $($uniqueIds.Count)"
if ($schemeIds.Count -eq $uniqueIds.Count) {
    Write-Output "  ✓ No duplicate SCHEME IDs found!"
} else {
    Write-Output "  ✗ Duplicate SCHEME IDs detected!"
}

# Validate TEAM references
$teamSchemeRefs = $csvLines | Where-Object { $_ -match "^TEAM,1," } | ForEach-Object {
    ($_ -split ",")[3]
}
$allTeamRefsValid = $true
foreach ($ref in $teamSchemeRefs) {
    if ($ref -notin $schemeIds) {
        Write-Output "  ✗ TEAM references non-existent SCHEME: $ref"
        $allTeamRefsValid = $false
    }
}
if ($allTeamRefsValid) {
    Write-Output "  ✓ All TEAM records reference valid SCHEME IDs"
}

Write-Output ""
Write-Output "=== Summary ==="
Write-Output "The fix changes SCHEME IDs from substation-based (RIO HONDO_SCHEME) to feeder-based (TIGRIS_SCHEME, POWDER_SCHEME, etc.)"
Write-Output "This ensures each SCHEME has a unique ID, eliminating the FWF210 warnings in the log files."
