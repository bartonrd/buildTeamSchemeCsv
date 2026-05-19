#Requires -Version 7.0

$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\Converter\input\"
#$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\Processing\"
$fisrFeedersFile = $processingDir + "fisrfeeders.txt"
$teamSchemeFile = $processingDir + "AutomationSchemes.tmp"
$teamSchemeFileCSV = $processingDir + "AutomationSchemes.csv"
$logFile = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\History\fisrfeeders.log"
$etlDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ETL\input\"
$backupDir = "E:\Eterra\Distribution\sce\ToolsWorkspace\ModelManagerFolders\Backup\TeamSchemes"

# Throttle for parallel operations (one runspace per logical processor, minimum 2)
$maxParallel = [Math]::Max(2, [Environment]::ProcessorCount)

# Ensure History directory exists for log file
$historyDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\History"
try {
    if (-not (Test-Path $historyDir)) {
        New-Item -Path $historyDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
}
catch {
    Write-Error "Failed to create history directory: $_"
    exit 1
}

# Create temp directory for processing
$tempDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\AutomationSchemes_Temp"
try {
    New-Item -Path $tempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
}
catch {
    "[ERROR] Failed to create temp directory: $_" | Out-File -Append -FilePath $logFile -Encoding UTF8
    exit 1
}

# feeder -> List[string] of devices
$feederDeviceDict = @{}
# feeder -> substation name
$feederSubDict = @{}

# cache of substation internals XML: substationName -> [xml]
$internalsCache = @{}

# Track processing state
$processingError = $null
$stationsProcessed = @{}
$scriptStartTime = Get-Date

function Get-InternalsXml {
    param(
        [string] $SubstationName,
        [string] $ProcessingDir,
        [string] $TempDir
    )
    if ([string]::IsNullOrWhiteSpace($SubstationName)) {
        return $null
    }
    
    $internalsPath = $ProcessingDir + $SubstationName + "_INTERNALS.xml"
    $internalsFileName = $SubstationName + "_INTERNALS.xml"
    $tempInternalsPath = [System.IO.Path]::Combine($TempDir, $internalsFileName)
    
    # Check if the source file exists with retry logic
    $fileFound = $false
    $maxAttempts = 3
    $retryDelaySeconds = 15
    
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if (Test-Path $internalsPath) {
            $fileFound = $true
            break
        }
        
        if ($attempt -lt $maxAttempts) {
            "[LOG] Station file not found on attempt $attempt : $internalsPath - Waiting $retryDelaySeconds seconds before retry" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }
    
    if (-not $fileFound) {
        $script:processingError = "Station file not found after $maxAttempts attempts: $internalsPath"
        "[ERROR] $($script:processingError)" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
        return $null
    }
    
    # Copy to temp directory if not already cached
    if (-not $script:internalsCache.ContainsKey($SubstationName)) {
        try {
            # Start timing for this scheme
            $schemeStartTime = Get-Date
            
            # Copy the file to temp directory
            Copy-Item -Path $internalsPath -Destination $tempInternalsPath -Force -ErrorAction Stop
            "[LOG] Copied $internalsFileName to temp directory" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
            
            # Read from temp directory
            $xmlText = Get-Content -Path $tempInternalsPath -Raw -ErrorAction Stop
            $script:internalsCache[$SubstationName] = [xml]$xmlText
            
            # Track this station as processed with timing and temp file path
            $script:stationsProcessed[$SubstationName] = @{
                TempPath = $tempInternalsPath
                StartTime = $schemeStartTime
            }
        }
        catch {
            $script:processingError = "Failed to copy or parse $internalsFileName : $_"
            "[ERROR] $($script:processingError)" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
            return $null
        }
    }
    return $script:internalsCache[$SubstationName]
}

function Cleanup-TempFiles {
    param(
        [string] $TempDir
    )
    if ([string]::IsNullOrWhiteSpace($TempDir)) {
        return
    }
    try {
        if (Test-Path $TempDir) {
            Remove-Item -Path $TempDir -Recurse -Force -ErrorAction Stop
            "[LOG] Cleaned up temp directory: $TempDir" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
        }
    }
    catch {
        "[ERROR] Failed to cleanup temp directory: $_" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
    }
}

function Cleanup-SchemeFile {
    param(
        [string] $SchemeName
    )
    if ([string]::IsNullOrWhiteSpace($SchemeName)) {
        return
    }
    
    if (-not $script:stationsProcessed.ContainsKey($SchemeName)) {
        return
    }
    
    $schemeInfo = $script:stationsProcessed[$SchemeName]
    $tempFilePath = $schemeInfo.TempPath
    $schemeStartTime = $schemeInfo.StartTime
    
    # Calculate processing time
    $schemeEndTime = Get-Date
    $processingTime = ($schemeEndTime - $schemeStartTime).TotalSeconds
    
    "[LOG] Scheme $SchemeName processing completed in $([math]::Round($processingTime, 2)) seconds" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
    
    # Cleanup temp file for this scheme
    try {
        if (Test-Path $tempFilePath) {
            Remove-Item -Path $tempFilePath -Force -ErrorAction Stop
            "[LOG] Cleaned up temp file for scheme $SchemeName : $($SchemeName)_INTERNALS.xml" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
        }
    }
    catch {
        "[ERROR] Failed to cleanup temp file for scheme $SchemeName : $_" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
    }
}

Set-Content -Path $logFile -Value "[LOG] Starting Automation Schemes File Build for CL FISR Device Participation" -Encoding UTF8

if (Test-Path $fisrFeedersFile) {
    $feedersList = Get-Content $fisrFeedersFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $processedSchemes = @{}  # Track which schemes have been cleaned up

    # -----------------------------------------------------------------
    # Phase 1: Parse each feeder XML in parallel. Each runspace returns
    # a record with the substation name and the collected mRID values.
    # -----------------------------------------------------------------
    $feederResults = $feedersList | ForEach-Object -ThrottleLimit $maxParallel -Parallel {
        $feeder = $_
        $etlDirLocal = $using:etlDir
        $feederXmlPath = $etlDirLocal + $feeder + ".xml"
        $logs = [System.Collections.Generic.List[string]]::new()
        if (-not (Test-Path $feederXmlPath)) {
            $logs.Add("[ERROR] Feeders file not found: $feederXmlPath")
            return [pscustomobject]@{
                Feeder = $feeder; Sub = $null; MRIDs = @(); Fatal = $false; Logs = $logs.ToArray()
            }
        }
        $logs.Add("[LOG] Parsing GCM feeder model for $feeder")
        try {
            $feederGC = Get-Content -Path $feederXmlPath -Raw -ErrorAction Stop
            $feederXML = [xml]$feederGC
        }
        catch {
            $logs.Add("[ERROR] Failed to parse feeder XML for $feeder at $feederXmlPath")
            return [pscustomobject]@{
                Feeder = $feeder; Sub = $null; MRIDs = @(); Fatal = $false; Logs = $logs.ToArray()
            }
        }
        $sub = $feederXML.CircuitConnectivity.Substation.name
        $mRIDValues = @()
        $mRIDValues += $feederXML.SelectNodes("//*[local-name()='Switch' or local-name()='Recloser']/*[local-name()='mRID']") | ForEach-Object { $_.'#text' }
        $mRIDValues += $feederXML.SelectNodes("//*[local-name()='CompositeSwitch']/*[local-name()='mRID']") | ForEach-Object { "$($_.'#text')_CS" }
        return [pscustomobject]@{
            Feeder = $feeder; Sub = $sub; MRIDs = $mRIDValues; Fatal = $false; Logs = $logs.ToArray()
        }
    }

    foreach ($r in $feederResults) {
        foreach ($l in $r.Logs) { $l | Out-File -Append -FilePath $logFile -Encoding UTF8 }
        if ($r.Sub) { $feederSubDict[$r.Feeder] = $r.Sub }
    }

    # Preserve original feedersList ordering (ForEach-Object -Parallel does
    # not guarantee output order, but downstream CSV ordering should match
    # the input list as the sequential script produced).
    $feederOrder = @{}
    for ($i = 0; $i -lt $feedersList.Count; $i++) { $feederOrder[$feedersList[$i]] = $i }
    $feederResults = $feederResults | Sort-Object { $feederOrder[$_.Feeder] }

    # -----------------------------------------------------------------
    # Phase 2: Determine the unique set of substations to load.
    # -----------------------------------------------------------------
    $uniqueSubs = @($feederResults | Where-Object { $_.Sub } | ForEach-Object { $_.Sub } | Sort-Object -Unique)

    # -----------------------------------------------------------------
    # Phase 3: Copy and parse each substation internals XML in parallel.
    # The expensive XML parsing and the per-substation node extraction
    # happen inside the runspaces so that they run concurrently. Each
    # runspace returns plain data (string arrays / pscustomobjects),
    # which is safe to marshal back across runspaces.
    # -----------------------------------------------------------------
    $internalsResults = $uniqueSubs | ForEach-Object -ThrottleLimit $maxParallel -Parallel {
        $sub = $_
        $procDir = $using:processingDir
        $tempD = $using:tempDir
        $internalsFileName = $sub + "_INTERNALS.xml"
        $internalsPath = $procDir + $internalsFileName
        $tempInternalsPath = [System.IO.Path]::Combine($tempD, $internalsFileName)
        $maxAttempts = 3
        $retryDelaySeconds = 15
        $fileFound = $false
        $logs = [System.Collections.Generic.List[string]]::new()

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            if (Test-Path $internalsPath) { $fileFound = $true; break }
            if ($attempt -lt $maxAttempts) {
                $logs.Add("[LOG] Station file not found on attempt $attempt : $internalsPath - Waiting $retryDelaySeconds seconds before retry")
                Start-Sleep -Seconds $retryDelaySeconds
            }
        }

        if (-not $fileFound) {
            return [pscustomobject]@{
                Sub = $sub
                Error = "Station file not found after $maxAttempts attempts: $internalsPath"
                DeviceIds = @()
                Breakers = @()
                TempPath = $tempInternalsPath
                StartTime = $null
                Logs = $logs.ToArray()
            }
        }

        $start = Get-Date
        try {
            Copy-Item -Path $internalsPath -Destination $tempInternalsPath -Force -ErrorAction Stop
            $logs.Add("[LOG] Copied $internalsFileName to temp directory")
            $xmlText = Get-Content -Path $tempInternalsPath -Raw -ErrorAction Stop
            $subXML = [xml]$xmlText

            # Pre-extract just the data we need so callers do not need to
            # touch the XmlDocument across threads.
            $deviceIds = @($subXML.SelectNodes("//Status[./pMeas/MeasType = 'SwitchStatusMeasurementType']") |
                ForEach-Object { [string]$_.device })
            $breakers = @($subXML.SelectNodes("//Breaker") | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Name; Id = [string]$_.Id }
            })

            return [pscustomobject]@{
                Sub = $sub
                Error = $null
                DeviceIds = $deviceIds
                Breakers = $breakers
                TempPath = $tempInternalsPath
                StartTime = $start
                Logs = $logs.ToArray()
            }
        }
        catch {
            return [pscustomobject]@{
                Sub = $sub
                Error = "Failed to copy or parse $internalsFileName : $_"
                DeviceIds = @()
                Breakers = @()
                TempPath = $tempInternalsPath
                StartTime = $start
                Logs = $logs.ToArray()
            }
        }
    }

    # Aggregate parallel internals results into per-substation lookup tables.
    $subData = @{}
    foreach ($r in $internalsResults) {
        foreach ($l in $r.Logs) { $l | Out-File -Append -FilePath $logFile -Encoding UTF8 }
        if ($r.Error) {
            $processingError = $r.Error
            "[ERROR] $processingError" | Out-File -Append -FilePath $logFile -Encoding UTF8
            break
        }
        $subData[$r.Sub] = @{ DeviceIds = $r.DeviceIds; Breakers = $r.Breakers }
        $stationsProcessed[$r.Sub] = @{ TempPath = $r.TempPath; StartTime = $r.StartTime }
        # Clean up the temp file now - all needed data has already been extracted.
        Cleanup-SchemeFile -SchemeName $r.Sub
        $processedSchemes[$r.Sub] = $true
    }

    if ($processingError) {
        "[ERROR] Processing Terminated: $processingError" | Out-File -Append -FilePath $logFile -Encoding UTF8
        Cleanup-TempFiles -TempDir $tempDir
        exit 1
    }

    # -----------------------------------------------------------------
    # Phase 4: Build the per-feeder device list from the pre-extracted
    # substation data. Uses a HashSet for O(1) mRID membership checks.
    # -----------------------------------------------------------------
    foreach ($r in $feederResults) {
        if (-not $r.Sub) { continue }
        $feeder = $r.Feeder
        $sub = $r.Sub
        if (-not $subData.ContainsKey($sub)) { continue }

        $mRIDset = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($m in $r.MRIDs) {
            if (-not [string]::IsNullOrEmpty($m)) { [void]$mRIDset.Add([string]$m) }
        }

        $devices = [System.Collections.Generic.List[string]]::new()
        foreach ($d in $subData[$sub].DeviceIds) {
            if ($mRIDset.Contains($d)) { $devices.Add($d) }
        }
        foreach ($cb in $subData[$sub].Breakers) {
            if ($cb.Name -and $cb.Name.Contains($feeder)) { $devices.Add($cb.Id) }
        }

        if ($devices.Count -gt 0) {
            $feederDeviceDict[$feeder] = $devices.ToArray()
        }
    }

    # Only write CSV if no errors occurred
    if (-not $processingError) {
        $csvLines = [System.Collections.Generic.List[string]]::new()

        # SCHEME section - deduplicate by substation name
        $csvLines.Add("SCHEME,0,ID_SCHEME,NAME_SCHEME,DESCRIPTION_SCHEME,,,,")
        $uniqueSubstations = @{}
        foreach ($key in $feederDeviceDict.Keys) {
            $subNameUpper = [string]$feederSubDict[$key].ToUpper()
            if (-not $uniqueSubstations.ContainsKey($subNameUpper)) {
                $uniqueSubstations[$subNameUpper] = $true
                $csvLines.Add("SCHEME,1," + $subNameUpper + "_SCHEME," + $subNameUpper + "_SCHEME,Automation Scheme,,,,")
            }
        }

        # TEAM section
        $csvLines.Add(",,,,,,,,")
        $csvLines.Add("TEAM,0,ID_TEAM,SCHEME_TEAM,NAME_TEAM,DESCRIPTION_TEAM,,,")
        foreach ($key in $feederDeviceDict.Keys) {
            $subNameUpper = [string]$feederSubDict[$key].ToUpper()
            $feederNameUpper = [string]$key.ToUpper()
            $csvLines.Add("TEAM,1," + $feederNameUpper + "_TEAM," + $subNameUpper + "_SCHEME," + $feederNameUpper + " FISR," + $feederNameUpper + " FISR,,,")
        }

        # TEAMSWITCH section
        $csvLines.Add(",,,,,,,,")
        $csvLines.Add("TEAMSWITCH,0,ID_TEAMSW,TEAM_TEAMSW,NAME_TEAMSW,SECONDID_TEAMSW,STATION1_TEAMSW,STATION2_TEAMSW,ROLE_TEAMSW")
        foreach ($key in $feederDeviceDict.Keys) {
            $subNameUpper = [string]$feederSubDict[$key].ToUpper()
            $feederNameUpper = [string]$key.ToUpper()
            foreach ($value in $feederDeviceDict[$key]) {
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $deviceUpper = [string]$value.ToUpper()
                    $csvLines.Add("TEAMSWITCH,1," + $deviceUpper + "," + $feederNameUpper + "_TEAM,na,na," + $subNameUpper + ",,PRIMARY")
                }
            }
        }

        try {
            # If a CSV already exists in the output directory, move it to the
            # backup location and append a date/time stamp before writing the
            # new one.
            if (Test-Path $teamSchemeFileCSV) {
                try {
                    if (-not (Test-Path $backupDir)) {
                        New-Item -Path $backupDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    }
                    $stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
                    $origName = [System.IO.Path]::GetFileNameWithoutExtension($teamSchemeFileCSV)
                    $ext = [System.IO.Path]::GetExtension($teamSchemeFileCSV)
                    $backupName = "{0}_{1}{2}" -f $origName, $stamp, $ext
                    $backupPath = [System.IO.Path]::Combine($backupDir, $backupName)
                    Move-Item -Path $teamSchemeFileCSV -Destination $backupPath -Force -ErrorAction Stop
                    "[LOG] Existing CSV backed up to $backupPath" | Out-File -Append -FilePath $logFile -Encoding UTF8
                }
                catch {
                    "[ERROR] Failed to backup existing CSV to $backupDir : $_" | Out-File -Append -FilePath $logFile -Encoding UTF8
                }
            }

            Set-Content -Path $teamSchemeFile -Value $csvLines -Encoding UTF8 -ErrorAction Stop
            Move-Item -Path $teamSchemeFile -Destination $teamSchemeFileCSV -Force -ErrorAction Stop
            
            $stationCount = $stationsProcessed.Count
            "[LOG] Processing complete - $stationCount stations processed" | Out-File -Append -FilePath $logFile -Encoding UTF8
            
            # Calculate and log total processing time
            $scriptEndTime = Get-Date
            $totalProcessingTime = ($scriptEndTime - $scriptStartTime).TotalSeconds
            "[LOG] Total processing time: $([math]::Round($totalProcessingTime, 2)) seconds" | Out-File -Append -FilePath $logFile -Encoding UTF8
        }
        catch {
            "[ERROR] Unable to write to AutomationSchemes.csv: $_" | Out-File -Append -FilePath $logFile -Encoding UTF8
            Cleanup-TempFiles -TempDir $tempDir
            exit 1
        }
    }
    
    # Cleanup temp files after successful processing
    Cleanup-TempFiles -TempDir $tempDir
}
else {
    "[ERROR] FISR feeders file not found" | Out-File -Append -FilePath $logFile -Encoding UTF8
    Cleanup-TempFiles -TempDir $tempDir
    exit 1
}
