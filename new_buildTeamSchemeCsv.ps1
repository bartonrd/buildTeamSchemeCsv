
$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\Converter\input\"
#$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\Processing\"
$fisrFeedersFile = $processingDir + "fisrfeeders.txt"
$teamSchemeFile = $processingDir + "AutomationSchemes.tmp"
$teamSchemeFileCSV = $processingDir + "AutomationSchemes.csv"
$logFile = $processingDir + "fisrfeeders.log"
$etlDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ETL\input\"

# feeder -> List[string] of devices
$feederDeviceDict = @{}
# feeder -> substation name
$feederSubDict = @{}

# cache of substation internals XML: substationName -> [xml]
$internalsCache = @{}

function Get-InternalsXml {
    param(
        [string] $SubstationName,
        [string] $ProcessingDir
    )
    if ([string]::IsNullOrWhiteSpace($SubstationName)) {
        return $null
    }
    $internalsPath = $ProcessingDir + $SubstationName + "_INTERNALS.xml"
    if (-not (Test-Path $internalsPath)) {
        return $null
    }
    if (-not $script:internalsCache.ContainsKey($SubstationName)) {
        try {
            $xmlText = Get-Content -Path $internalsPath -Raw
            $script:internalsCache[$SubstationName] = [xml]$xmlText
        }
        catch {
            return $null
        }
    }
    return $script:internalsCache[$SubstationName]
}

function Get-OrCreate-DeviceList {
    param(
        [hashtable] $Dict,
        [string] $Feeder
    )
    if ([string]::IsNullOrWhiteSpace($Feeder)) {
        return $null
    }
    if (-not $Dict.ContainsKey($Feeder)) {
        $Dict[$Feeder] = [System.Collections.Generic.List[string]]::new()
    }
    return $Dict[$Feeder]
}

Set-Content -Path $logFile -Value "Starting Automation Schemes File Build for CL FISR Device Particpation" -Encoding UTF8

if (Test-Path $fisrFeedersFile) {
    $feedersList = Get-Content $fisrFeedersFile
    foreach ($feeder in $feedersList) {
        if ([string]::IsNullOrWhiteSpace($feeder)) { continue }
        $feederXmlPath = $etlDir + $feeder + ".xml"
        if (Test-Path $feederXmlPath) {
            "Parsing GCM feeder model for $feeder" | Out-File -Append -FilePath $logFile -Encoding UTF8
            try {
                $feederGC = Get-Content -Path $feederXmlPath -Raw
                $feederXML = [xml]$feederGC
            }
            catch {
                "Failed to parse feeder XML for $feeder at $feederXmlPath" | Out-File -Append -FilePath $logFile -Encoding UTF8
                continue
            }
            $sub = $feederXML.CircuitConnectivity.Substation.name
            $feederSubDict[$feeder] = $sub

            # Collect all mRID values (Switches, Reclosers, CompositeSwitches)
            $mRIDSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            # Reclosers
            $recloserNodes = $feederXML.SelectNodes("//*[local-name()='Recloser']/*[local-name()='mRID']")
            if ($recloserNodes) {
                foreach ($node in $recloserNodes) {
                    $text = $node.'#text'
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        [void]$mRIDSet.Add($text)
                    }
                }
            }
            # Switches
            $switchNodes = $feederXML.SelectNodes("//*[local-name()='Switch']/*[local-name()='mRID']")
            if ($switchNodes) {
                foreach ($node in $switchNodes) {
                    $text = $node.'#text'
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        [void]$mRIDSet.Add($text)
                    }
                }
            }
            # CompositeSwitches (with _CS suffix)
            $compositeNodes = $feederXML.SelectNodes("//*[local-name()='CompositeSwitch']/*[local-name()='mRID']")
            if ($compositeNodes) {
                foreach ($node in $compositeNodes) {
                    $text = $node.'#text'
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        [void]$mRIDSet.Add($text + "_CS")
                    }
                }
            }

            # Internals: add devices to feederDeviceDict (original logic preserved)
            $subXML = Get-InternalsXml -SubstationName $sub -ProcessingDir $processingDir
            if ($subXML) {
                $statusList = $subXML.SelectNodes("//Status[./pMeas/MeasType = 'SwitchStatusMeasurementType']")
                $cbList = $subXML.SelectNodes("//Breaker[contains(Name,'$feeder')]")

                if ($statusList) {
                    foreach ($status in $statusList) {
                        $deviceId = $status.device
                        if (-not [string]::IsNullOrWhiteSpace($deviceId) -and $mRIDSet.Contains($deviceId)) {
                            $deviceList = Get-OrCreate-DeviceList -Dict $feederDeviceDict -Feeder $feeder
                            if ($deviceList) { $deviceList.Add($deviceId) }
                        }
                    }
                }
                if ($cbList) {
                    foreach ($cb in $cbList) {
                        $cbId = $cb.Id
                        if (-not [string]::IsNullOrWhiteSpace($cbId)) {
                            $deviceList = Get-OrCreate-DeviceList -Dict $feederDeviceDict -Feeder $feeder
                            if ($deviceList) { $deviceList.Add($cbId) }
                        }
                    }
                }
            }
            else {
                ($processingDir + $sub + "_INTERNALS.xml substation file not found...") | Out-File -Append -FilePath $logFile -Encoding UTF8
            }
        }
        else {
            ($etlDir + $feeder + ".xml feeders file not found...") | Out-File -Append -FilePath $logFile -Encoding UTF8
        }
    }

    $csvLines = [System.Collections.Generic.List[string]]::new()

    # SCHEME section
    $csvLines.Add("SCHEME,0,ID_SCHEME,NAME_SCHEME,DESCRIPTION_SCHEME,,,,")
    foreach ($key in $feederDeviceDict.Keys) {
        $subNameUpper = [string]$feederSubDict[$key].ToUpper()
        $feederNameUpper = [string]$key.ToUpper()
        $csvLines.Add("SCHEME,1," + $subNameUpper + "_SCHEME," + $subNameUpper + "_SCHEME," + $feederNameUpper + " FISR,,,,")
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
        $feederNameUpper = [string]$key.ToUpper()
        foreach ($value in $feederDeviceDict[$key]) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $deviceUpper = [string]$value.ToUpper()
                $csvLines.Add("TEAMSWITCH,1," + $deviceUpper + "," + $feederNameUpper + "_TEAM,na,na," + $feederNameUpper + ",,PRIMARY")
            }
        }
    }

    Set-Content -Path $teamSchemeFile -Value $csvLines -Encoding UTF8
    Move-Item -Path $teamSchemeFile -Destination $teamSchemeFileCSV -Force
}
else {
    "FISR feeders file not found..." | Out-File -Append -FilePath $logFile -Encoding UTF8
}
