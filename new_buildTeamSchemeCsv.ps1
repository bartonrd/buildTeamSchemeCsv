
$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\Converter\input\"
#$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\Processing\"
$fisrFeedersFile = $processingDir + "fisrfeeders.txt"
$teamSchemeFile = $processingDir + "AutomationSchemes.tmp"
$teamSchemeFileCSV = $processingDir + "AutomationSchemes.csv"
$logFile = $processingDir + "fisrfeeders.log"
$etlDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ETL\input\"

# Create temp directory for processing
$tempDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "AutomationSchemes_" + [System.Guid]::NewGuid().ToString())
New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

# feeder -> List[string] of devices
$feederDeviceDict = @{}
# feeder -> substation name
$feederSubDict = @{}

# cache of substation internals XML: substationName -> [xml]
$internalsCache = @{}

# Track processing state
$processingError = $null
$stationsProcessed = @{}

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
    
    # Check if the source file exists
    if (-not (Test-Path $internalsPath)) {
        $script:processingError = "Station file not found: $internalsPath"
        "[ERROR] $($script:processingError)" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
        return $null
    }
    
    # Copy to temp directory if not already cached
    if (-not $script:internalsCache.ContainsKey($SubstationName)) {
        try {
            # Copy the file to temp directory
            Copy-Item -Path $internalsPath -Destination $tempInternalsPath -Force -ErrorAction Stop
            "[LOG] Copied $internalsFileName to temp directory" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
            
            # Read from temp directory
            $xmlText = Get-Content -Path $tempInternalsPath -Raw -ErrorAction Stop
            $script:internalsCache[$SubstationName] = [xml]$xmlText
            
            # Track this station as processed
            $script:stationsProcessed[$SubstationName] = $tempInternalsPath
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

Set-Content -Path $logFile -Value "[LOG] Starting Automation Schemes File Build for CL FISR Device Particpation" -Encoding UTF8

if (Test-Path $fisrFeedersFile) {
    $feedersList = Get-Content $fisrFeedersFile
    foreach ($feeder in $feedersList) {
        if ([string]::IsNullOrWhiteSpace($feeder)) { continue }
        $feederXmlPath = $etlDir + $feeder + ".xml"
        if (Test-Path $feederXmlPath) {
            "[LOG] Parsing GCM feeder model for $feeder" | Out-File -Append -FilePath $logFile -Encoding UTF8
            try {
                $feederGC = Get-Content -Path $feederXmlPath -Raw
                $feederXML = [xml]$feederGC
            }
            catch {
                "[ERROR] Failed to parse feeder XML for $feeder at $feederXmlPath" | Out-File -Append -FilePath $logFile -Encoding UTF8
                continue
            }
            $sub = $feederXML.CircuitConnectivity.Substation.name
            $feederSubDict[$feeder] = $sub
            
            # Collect mRID values exactly like old script
            $mRIDValues = $feederXML.SelectNodes("//*[local-name()='Switch' or local-name()='Recloser']/*[local-name()='mRID']") | ForEach-Object { $_.'#text' }
            $mRIDValues += $feederXML.SelectNodes("//*[local-name()='CompositeSwitch']/*[local-name()='mRID']") | ForEach-Object { "$($_.'#text')_CS" }

            # Check for the internals file for all switch status measurements
            $subXML = Get-InternalsXml -SubstationName $sub -ProcessingDir $processingDir -TempDir $tempDir
            if ($subXML) {
                $statusList = $subXML.SelectNodes("//Status[./pMeas/MeasType = 'SwitchStatusMeasurementType']")
                $cbList = $subXML.SelectNodes("//Breaker[contains(Name,'$feeder')]")

                # Check to see what automated devices are in the feeder file and create a list
                foreach ($status in $statusList) {
                    if (($status.device -in $mRIDValues)) {
                        if (-not $feederDeviceDict.ContainsKey($feeder)) {
                            $feederDeviceDict[$feeder] = @()
                        }
                        $feederDeviceDict[$feeder] += $status.device
                    }
                }
                foreach ($cb in $cbList) {
                    if (-not $feederDeviceDict.ContainsKey($feeder)) {
                        $feederDeviceDict[$feeder] = @()
                    }
                    $feederDeviceDict[$feeder] += $cb.Id
                }
            }
            else {
                # If Get-InternalsXml returned null and set an error, stop processing
                if ($processingError) {
                    "[ERROR] Processing Terminated: $processingError" | Out-File -Append -FilePath $logFile -Encoding UTF8
                    Cleanup-TempFiles -TempDir $tempDir
                    exit 1
                }
                "[ERROR] $($processingDir + $sub + '_INTERNALS.xml') substation file not found" | Out-File -Append -FilePath $logFile -Encoding UTF8
                $processingError = "Station file not found: $($processingDir + $sub + '_INTERNALS.xml')"
                "[ERROR] Processing Terminated: $processingError" | Out-File -Append -FilePath $logFile -Encoding UTF8
                Cleanup-TempFiles -TempDir $tempDir
                exit 1
            }
        }
        else {
            "[ERROR] $($etlDir + $feeder + '.xml') feeders file not found" | Out-File -Append -FilePath $logFile -Encoding UTF8
        }
        
        # Check if we should stop processing due to errors
        if ($processingError) {
            "[ERROR] Processing Terminated: $processingError" | Out-File -Append -FilePath $logFile -Encoding UTF8
            Cleanup-TempFiles -TempDir $tempDir
            exit 1
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
            Set-Content -Path $teamSchemeFile -Value $csvLines -Encoding UTF8 -ErrorAction Stop
            Move-Item -Path $teamSchemeFile -Destination $teamSchemeFileCSV -Force -ErrorAction Stop
            
            $stationCount = $stationsProcessed.Count
            "[LOG] Processing complete - $stationCount stations processed" | Out-File -Append -FilePath $logFile -Encoding UTF8
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
}
