# Simulate the data structure that would be created
$feederDeviceDict = @{
    "TIGRIS" = @("device1", "device2")
    "POWDER" = @("device3", "device4")
    "WASH" = @("device5")
}

$feederSubDict = @{
    "TIGRIS" = "RIO HONDO"
    "POWDER" = "RIO HONDO"
    "WASH" = "RIO HONDO"
}

$csvLines = [System.Collections.Generic.List[string]]::new()

# SCHEME section - OLD LOGIC with substation-based IDs
$csvLines.Add("SCHEME,0,ID_SCHEME,NAME_SCHEME,DESCRIPTION_SCHEME,,,,")
foreach ($key in $feederDeviceDict.Keys) {
    $subNameUpper = [string]$feederSubDict[$key].ToUpper()
    $feederNameUpper = [string]$key.ToUpper()
    $csvLines.Add("SCHEME,1," + $subNameUpper + "_SCHEME," + $subNameUpper + "_SCHEME," + $feederNameUpper + " FISR,,,,")
}

# Output the CSV
$csvLines | ForEach-Object { Write-Output $_ }

# Check for duplicate SCHEME IDs
Write-Output ""
Write-Output "=== Uniqueness Check ==="
$schemeIds = $csvLines | Where-Object { $_ -match "^SCHEME,1," } | ForEach-Object {
    ($_ -split ",")[2]
}
$uniqueIds = $schemeIds | Select-Object -Unique
Write-Output "Total SCHEME entries: $($schemeIds.Count)"
Write-Output "Unique SCHEME IDs: $($uniqueIds.Count)"
if ($schemeIds.Count -eq $uniqueIds.Count) {
    Write-Output "✓ No duplicate SCHEME IDs found!"
} else {
    Write-Output "✗ Duplicate SCHEME IDs detected!"
    $schemeIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object {
        Write-Output "  Duplicate: $($_.Name) appears $($_.Count) times"
    }
}
