#Requires -Version 7.0

param(
    [ValidateRange(1, 64)]
    [int] $MaxParallel = 4
)

#$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\Converter\input\"
$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\Processing\"
$fisrFeedersFile = $processingDir + "fisrfeeders.txt"
$teamSchemeFile = $processingDir + "AutomationSchemes.tmp"
$teamSchemeFileCSV = $processingDir + "AutomationSchemes.csv"
$logFile = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\History\fisrfeeders.log"
$etlDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ETL\input\"

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

function Write-Log {
    param(
        [string] $Message,
        [switch] $Reset
    )

    if ($Reset) {
        Set-Content -Path $script:logFile -Value $Message -Encoding UTF8
    }
    else {
        $Message | Out-File -Append -FilePath $script:logFile -Encoding UTF8
    }
    Write-Host $Message
}

# Create temp directory for processing
$tempDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\AutomationSchemes_Temp"
try {
    New-Item -Path $tempDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
}
catch {
    Write-Log "[ERROR] Failed to create temp directory: $_"
    exit 1
}

# feeder -> List[string] of devices
$feederDeviceDict = @{}
# feeder -> substation name
$feederSubDict = @{}

# Track processing state
$processingError = $null
$stationsProcessed = @{}
$scriptStartTime = Get-Date

function Normalize-SubstationName {
    param(
        [string] $SubstationName
    )
    if ([string]::IsNullOrWhiteSpace($SubstationName)) {
        return $SubstationName
    }

    $normalizedName = $SubstationName -replace '(?i)(?<![A-Z0-9])P\.T\.(?![A-Z0-9])', 'PT'
    $normalizedName = $normalizedName -replace '(?i)(?<![A-Z0-9])U\.G\.S\.(?![A-Z0-9])', 'UGS'
    $normalizedName = $normalizedName -replace '(?i)(?<![A-Z0-9])P\.M\.(?![A-Z0-9])', 'PM'
    return $normalizedName -replace '\.', ''
}

function Resolve-FeederModelName {
    param(
        [string] $FeederName
    )
    if ([string]::IsNullOrWhiteSpace($FeederName)) {
        return $FeederName
    }

    $feederModelAliases = @{
        "FORTY EIGHT ST" = "FORTY EIGHT ST PT"
        "SIXTEENTH ST" = "SIXTEENTH STREET"
    }

    if ($feederModelAliases.ContainsKey($FeederName)) {
        return $feederModelAliases[$FeederName]
    }

    return $FeederName
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
            Write-Log "[LOG] Cleaned up temp directory: $TempDir"
        }
    }
    catch {
        Write-Log "[ERROR] Failed to cleanup temp directory: $_"
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
    
    Write-Log "[LOG] Scheme $SchemeName processing completed in $([math]::Round($processingTime, 2)) seconds"
    
    # Cleanup temp file for this scheme
    try {
        if (Test-Path $tempFilePath) {
            Remove-Item -Path $tempFilePath -Force -ErrorAction Stop
            Write-Log "[LOG] Cleaned up temp file for scheme $SchemeName : $($SchemeName)_INTERNALS.xml"
        }
    }
    catch {
        Write-Log "[ERROR] Failed to cleanup temp file for scheme $SchemeName : $_"
    }
}

Write-Log "[LOG] Starting Automation Schemes File Build for CL FISR Device Participation" -Reset

if (Test-Path $fisrFeedersFile) {
    $feedersList = @(Get-Content $fisrFeedersFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Write-Log "[LOG] Parallel worker limit: $MaxParallel"

    $feederInputs = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $feedersList.Count; $index++) {
        $feeder = [string]$feedersList[$index]
        $feederModelName = Resolve-FeederModelName -FeederName $feeder
        $feederInputs.Add([pscustomobject]@{
            Index = $index
            Feeder = $feeder
            ModelName = $feederModelName
            Path = $etlDir + $feederModelName + ".xml"
        })
    }

    $feederPhase = [System.Diagnostics.Stopwatch]::StartNew()
    $feederResults = @($feederInputs | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
        $inputRecord = $_
        $logs = [System.Collections.Generic.List[string]]::new()
        if (-not (Test-Path $inputRecord.Path)) {
            if ($inputRecord.ModelName -ne $inputRecord.Feeder) {
                $logs.Add("[ERROR] Feeders file not found for $($inputRecord.Feeder) using alias $($inputRecord.ModelName) : $($inputRecord.Path)")
            }
            else {
                $logs.Add("[ERROR] Feeders file not found: $($inputRecord.Path)")
            }
            return [pscustomobject]@{
                Index = $inputRecord.Index; Feeder = $inputRecord.Feeder; Sub = $null
                MRIDs = @(); Logs = $logs.ToArray(); ParseSeconds = 0; XPathSeconds = 0
            }
        }

        if ($inputRecord.ModelName -ne $inputRecord.Feeder) {
            $logs.Add("[LOG] Parsing GCM feeder model for $($inputRecord.Feeder) using alias $($inputRecord.ModelName)")
        }
        else {
            $logs.Add("[LOG] Parsing GCM feeder model for $($inputRecord.Feeder)")
        }

        try {
            $parseTimer = [System.Diagnostics.Stopwatch]::StartNew()
            $feederXML = [xml](Get-Content -Path $inputRecord.Path -Raw -ErrorAction Stop)
            $parseTimer.Stop()

            $sub = [string]$feederXML.CircuitConnectivity.Substation.name

            $xpathTimer = [System.Diagnostics.Stopwatch]::StartNew()
            $mRIDValues = @($feederXML.SelectNodes("//*[local-name()='Switch' or local-name()='Recloser']/*[local-name()='mRID']") |
                ForEach-Object { [string]$_.'#text' })
            $mRIDValues += @($feederXML.SelectNodes("//*[local-name()='CompositeSwitch']/*[local-name()='mRID']") |
                ForEach-Object { "$($_.'#text')_CS" })
            $xpathTimer.Stop()

            return [pscustomobject]@{
                Index = $inputRecord.Index; Feeder = $inputRecord.Feeder; Sub = $sub
                MRIDs = $mRIDValues; Logs = $logs.ToArray()
                ParseSeconds = $parseTimer.Elapsed.TotalSeconds
                XPathSeconds = $xpathTimer.Elapsed.TotalSeconds
            }
        }
        catch {
            $logs.Add("[ERROR] Failed to parse feeder XML for $($inputRecord.Feeder) at $($inputRecord.Path)")
            return [pscustomobject]@{
                Index = $inputRecord.Index; Feeder = $inputRecord.Feeder; Sub = $null
                MRIDs = @(); Logs = $logs.ToArray(); ParseSeconds = 0; XPathSeconds = 0
            }
        }
    } | Sort-Object Index)
    $feederPhase.Stop()

    foreach ($result in $feederResults) {
        foreach ($message in $result.Logs) { Write-Log $message }
        if (-not [string]::IsNullOrWhiteSpace($result.Sub)) {
            $result.Sub = Normalize-SubstationName -SubstationName ([string]$result.Sub)
            $feederSubDict[$result.Feeder] = $result.Sub
        }
    }
    $feederParseWork = ($feederResults | Measure-Object -Property ParseSeconds -Sum).Sum
    $feederXPathWork = ($feederResults | Measure-Object -Property XPathSeconds -Sum).Sum
    Write-Log "[LOG] Feeder XML phase: $([math]::Round($feederPhase.Elapsed.TotalSeconds, 2)) seconds (parse work $([math]::Round($feederParseWork, 2))s, XPath work $([math]::Round($feederXPathWork, 2))s)"

    $uniqueSubs = [System.Collections.Generic.List[string]]::new()
    $seenSubs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($result in $feederResults) {
        if (-not [string]::IsNullOrWhiteSpace($result.Sub) -and $seenSubs.Add([string]$result.Sub)) {
            $uniqueSubs.Add([string]$result.Sub)
        }
    }

    $internalsInputs = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $uniqueSubs.Count; $index++) {
        $sub = $uniqueSubs[$index]
        $internalsFileName = $sub + "_INTERNALS.xml"
        $internalsInputs.Add([pscustomobject]@{
            Index = $index
            Sub = $sub
            FileName = $internalsFileName
            SourcePath = $processingDir + $internalsFileName
            TempPath = [System.IO.Path]::Combine($tempDir, $internalsFileName)
        })
    }

    $internalsPhase = [System.Diagnostics.Stopwatch]::StartNew()
    $internalsResults = @($internalsInputs | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
        $inputRecord = $_
        $logs = [System.Collections.Generic.List[string]]::new()
        $maxAttempts = 3
        $retryDelaySeconds = 15
        $fileFound = $false

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            if (Test-Path $inputRecord.SourcePath) {
                $fileFound = $true
                break
            }
            if ($attempt -lt $maxAttempts) {
                $logs.Add("[LOG] Station file not found on attempt $attempt : $($inputRecord.SourcePath) - Waiting $retryDelaySeconds seconds before retry")
                Start-Sleep -Seconds $retryDelaySeconds
            }
        }

        if (-not $fileFound) {
            return [pscustomobject]@{
                Index = $inputRecord.Index; Sub = $inputRecord.Sub
                Error = "Station file not found after $maxAttempts attempts: $($inputRecord.SourcePath)"
                DeviceIds = @(); Breakers = @(); TempPath = $inputRecord.TempPath
                Logs = $logs.ToArray(); IoSeconds = 0; ParseSeconds = 0; XPathSeconds = 0
            }
        }

        $startTime = Get-Date
        try {
            $ioTimer = [System.Diagnostics.Stopwatch]::StartNew()
            Copy-Item -Path $inputRecord.SourcePath -Destination $inputRecord.TempPath -Force -ErrorAction Stop
            $logs.Add("[LOG] Copied $($inputRecord.FileName) to temp directory")
            $xmlText = Get-Content -Path $inputRecord.TempPath -Raw -ErrorAction Stop
            $ioTimer.Stop()

            $parseTimer = [System.Diagnostics.Stopwatch]::StartNew()
            $subXML = [xml]$xmlText
            $parseTimer.Stop()

            $xpathTimer = [System.Diagnostics.Stopwatch]::StartNew()
            $deviceIds = @($subXML.SelectNodes("//Status[./pMeas/MeasType = 'SwitchStatusMeasurementType']") |
                ForEach-Object { [string]$_.device })
            $breakers = @($subXML.SelectNodes("//Breaker") | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.Name; Id = [string]$_.Id }
            })
            $xpathTimer.Stop()

            return [pscustomobject]@{
                Index = $inputRecord.Index; Sub = $inputRecord.Sub; Error = $null
                DeviceIds = $deviceIds; Breakers = $breakers; TempPath = $inputRecord.TempPath
                StartTime = $startTime; Logs = $logs.ToArray()
                IoSeconds = $ioTimer.Elapsed.TotalSeconds
                ParseSeconds = $parseTimer.Elapsed.TotalSeconds
                XPathSeconds = $xpathTimer.Elapsed.TotalSeconds
            }
        }
        catch {
            return [pscustomobject]@{
                Index = $inputRecord.Index; Sub = $inputRecord.Sub
                Error = "Failed to copy or parse $($inputRecord.FileName) : $_"
                DeviceIds = @(); Breakers = @(); TempPath = $inputRecord.TempPath
                StartTime = $startTime; Logs = $logs.ToArray()
                IoSeconds = 0; ParseSeconds = 0; XPathSeconds = 0
            }
        }
    } | Sort-Object Index)
    $internalsPhase.Stop()

    $subData = @{}
    foreach ($result in $internalsResults) {
        foreach ($message in $result.Logs) { Write-Log $message }
        if ($result.Error) {
            if (-not $processingError) {
                $processingError = $result.Error
                Write-Log "[ERROR] $processingError"
            }
            continue
        }

        $subData[$result.Sub] = @{
            DeviceIds = $result.DeviceIds
            Breakers = $result.Breakers
        }
        $stationsProcessed[$result.Sub] = @{
            TempPath = $result.TempPath
            StartTime = $result.StartTime
        }
        Cleanup-SchemeFile -SchemeName $result.Sub
    }
    $internalsIoWork = ($internalsResults | Measure-Object -Property IoSeconds -Sum).Sum
    $internalsParseWork = ($internalsResults | Measure-Object -Property ParseSeconds -Sum).Sum
    $internalsXPathWork = ($internalsResults | Measure-Object -Property XPathSeconds -Sum).Sum
    Write-Log "[LOG] Internals XML phase: $([math]::Round($internalsPhase.Elapsed.TotalSeconds, 2)) seconds (file I/O work $([math]::Round($internalsIoWork, 2))s, parse work $([math]::Round($internalsParseWork, 2))s, XPath work $([math]::Round($internalsXPathWork, 2))s)"

    if ($processingError) {
        Write-Log "[ERROR] Processing Terminated: $processingError"
        Cleanup-TempFiles -TempDir $tempDir
        exit 1
    }

    $matchingPhase = [System.Diagnostics.Stopwatch]::StartNew()
    $feedersWithDevices = [System.Collections.Generic.List[string]]::new()
    $seenOutputFeeders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($result in $feederResults) {
        if ([string]::IsNullOrWhiteSpace($result.Sub) -or -not $subData.ContainsKey($result.Sub)) {
            continue
        }

        $mRIDSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($mRID in $result.MRIDs) {
            if (-not [string]::IsNullOrWhiteSpace($mRID)) {
                [void]$mRIDSet.Add([string]$mRID)
            }
        }

        $devices = [System.Collections.Generic.List[string]]::new()
        foreach ($deviceId in $subData[$result.Sub].DeviceIds) {
            if ($mRIDSet.Contains([string]$deviceId)) {
                $devices.Add([string]$deviceId)
            }
        }
        foreach ($breaker in $subData[$result.Sub].Breakers) {
            if ($breaker.Name -and $breaker.Name.Contains($result.Feeder)) {
                $devices.Add([string]$breaker.Id)
            }
        }

        if ($devices.Count -gt 0) {
            $feederDeviceDict[$result.Feeder] = $devices.ToArray()
            if ($seenOutputFeeders.Add([string]$result.Feeder)) {
                $feedersWithDevices.Add([string]$result.Feeder)
            }
        }
    }
    $matchingPhase.Stop()
    Write-Log "[LOG] Device matching phase: $([math]::Round($matchingPhase.Elapsed.TotalSeconds, 2)) seconds"

    $csvBuildPhase = [System.Diagnostics.Stopwatch]::StartNew()
    $csvLines = [System.Collections.Generic.List[string]]::new()

    $csvLines.Add("SCHEME,0,ID_SCHEME,NAME_SCHEME,DESCRIPTION_SCHEME,,,,")
    $uniqueSubstations = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $feedersWithDevices) {
        $subNameUpper = [string]$feederSubDict[$key].ToUpper()
        if ($uniqueSubstations.Add($subNameUpper)) {
            $csvLines.Add("SCHEME,1," + $subNameUpper + "_SCHEME," + $subNameUpper + "_SCHEME,Automation Scheme,,,,")
        }
    }

    $csvLines.Add(",,,,,,,,")
    $csvLines.Add("TEAM,0,ID_TEAM,SCHEME_TEAM,NAME_TEAM,DESCRIPTION_TEAM,,,")
    foreach ($key in $feedersWithDevices) {
        $subNameUpper = [string]$feederSubDict[$key].ToUpper()
        $feederNameUpper = [string]$key.ToUpper()
        $csvLines.Add("TEAM,1," + $feederNameUpper + "_TEAM," + $subNameUpper + "_SCHEME," + $feederNameUpper + " FISR," + $feederNameUpper + " FISR,,,")
    }

    $csvLines.Add(",,,,,,,,")
    $csvLines.Add("TEAMSWITCH,0,ID_TEAMSW,TEAM_TEAMSW,NAME_TEAMSW,SECONDID_TEAMSW,STATION1_TEAMSW,STATION2_TEAMSW,ROLE_TEAMSW")
    foreach ($key in $feedersWithDevices) {
        $subNameUpper = [string]$feederSubDict[$key].ToUpper()
        $feederNameUpper = [string]$key.ToUpper()
        foreach ($value in $feederDeviceDict[$key]) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $deviceUpper = [string]$value.ToUpper()
                $csvLines.Add("TEAMSWITCH,1," + $deviceUpper + "," + $feederNameUpper + "_TEAM,na,na," + $subNameUpper + ",,PRIMARY")
            }
        }
    }
    $csvBuildPhase.Stop()
    Write-Log "[LOG] CSV build phase: $([math]::Round($csvBuildPhase.Elapsed.TotalSeconds, 2)) seconds"

    try {
        $csvIoPhase = [System.Diagnostics.Stopwatch]::StartNew()
        Set-Content -Path $teamSchemeFile -Value $csvLines -Encoding UTF8 -ErrorAction Stop
        Move-Item -Path $teamSchemeFile -Destination $teamSchemeFileCSV -Force -ErrorAction Stop
        $csvIoPhase.Stop()
        Write-Log "[LOG] CSV file I/O phase: $([math]::Round($csvIoPhase.Elapsed.TotalSeconds, 2)) seconds"

        $stationCount = $stationsProcessed.Count
        Write-Log "[LOG] Processing complete - $stationCount stations processed"

        $scriptEndTime = Get-Date
        $totalProcessingTime = ($scriptEndTime - $scriptStartTime).TotalSeconds
        Write-Log "[LOG] Total processing time: $([math]::Round($totalProcessingTime, 2)) seconds"
    }
    catch {
        Write-Log "[ERROR] Unable to write to AutomationSchemes.csv: $_"
        Cleanup-TempFiles -TempDir $tempDir
        exit 1
    }

    # Cleanup temp files after successful processing
    Cleanup-TempFiles -TempDir $tempDir
}
else {
    Write-Log "[ERROR] FISR feeders file not found"
    Cleanup-TempFiles -TempDir $tempDir
    exit 1
}
