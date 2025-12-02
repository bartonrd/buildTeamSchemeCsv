$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\Converter\input\"
#$processingDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ModelManagerFolders\Processing\"

$fisrFeedersFile = $processingDir + "fisrfeeders.txt"
$teamSchemeFile = $processingDir + "AutomationSchemes.tmp"
$teamSchemeFileCSV = $processingDir + "AutomationSchemes.csv"
$logFile = $processingDir + "fisrfeeders.log"
$etlDir = "E:\Eterra\distribution\sce\ToolsWorkspace\ETL\input\"

$feederDeviceDict = @{}
$feederSubDict = @{}

Set-Content -Path $logFile -Value "Starting Automation Schemes File Build for CL FISR Device Particpation"

#check to see if fisr feeders list file is found, if not write an error message to the log
if (Test-Path $fisrFeedersFile) {
    $feedersList = Get-Content $fisrFeedersFile

    #parse the ETL feeder file for each feeder and make a list of all the Recloser (RAR,RSR,VFI) and Switches
    foreach ($feeder in $feedersList) {
        if (Test-Path ($etlDir + $feeder + ".xml")) {
            "Parsing GCM feeder model for " + $feeder | out-file -Append -FilePath $logFile -Encoding UTF8
            $feederGC = (Get-Content ($etlDir + $feeder + ".xml"))
            $feederXML = [XML]$feederGC
            $sub = $feederXML.CircuitConnectivity.Substation.name
            $feederSubDict[$feeder] = $sub
            $mRIDValues = $feederXML.SelectNodes("//*[local-name()='Switch' or local-name()='Recloser']/*[local-name()='mRID']") | ForEach-Object { $_.'#text' }
            $mRIDValues += $feederXML.SelectNodes("//*[local-name()='CompositeSwitch']/*[local-name()='mRID']") | ForEach-Object { "$($_.'#text')_CS" }

            #check for the internals file for all switch status measurements. Create a list of all devices with this measurement type
            if (Test-Path ($processingDir + $sub + "_INTERNALS.xml")) {
                $sub = (Get-Content ($processingDir + $sub + "_INTERNALS.xml"))
                $subXML = [XML]$sub
                $statusList = $subXML.SelectNodes("//Status[./pMeas/MeasType = 'SwitchStatusMeasurementType']")
                $cbList = $subXML.SelectNodes("//Breaker[contains(Name,'$feeder')]")
                #check to see what automated devices are in the feeder file and create a list
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
                $processingDir + $sub + "_INTERNALS.xml substation file not found..." | out-file -Append -FilePath $logFile -Encoding UTF8
                
            }

           

        }
        else {
            $etlDir + $feeder + ".xml feeders file not found..." | out-file -Append -FilePath $logFile -Encoding UTF8
        }
    }

    #wrtie the temporary automation schemes csv file
    Set-Content -Path $teamSchemeFile -Value "SCHEME,0,ID_SCHEME,NAME_SCHEME,DESCRIPTION_SCHEME,,,,"

    foreach ($key in $feederDeviceDict.Keys) {
        "SCHEME,1," + $feederSubDict[$key].ToUpper() + "_SCHEME," + $feederSubDict[$key].ToUpper() + "_SCHEME," + $key.ToUpper() + " FISR,,,," | out-file -Append -FilePath $teamSchemeFile -Encoding UTF8
    }

    ",,,,,,,,"| out-file -Append -FilePath $teamSchemeFile -Encoding UTF8
    "TEAM,0,ID_TEAM,SCHEME_TEAM,NAME_TEAM,DESCRIPTION_TEAM,,," | out-file -Append -FilePath $teamSchemeFile -Encoding UTF8

    foreach ($key in $feederDeviceDict.Keys) {
        "TEAM,1," + $key.ToUpper() + "_TEAM," + $feederSubDict[$key].ToUpper() + "_SCHEME," + $key.ToUpper() + " FISR," + $key.ToUpper() + " FISR,,," | out-file -Append -FilePath $teamSchemeFile -Encoding UTF8
    }

    ",,,,,,,," | out-file -Append -FilePath $teamSchemeFile -Encoding UTF8
    "TEAMSWITCH,0,ID_TEAMSW,TEAM_TEAMSW,NAME_TEAMSW,SECONDID_TEAMSW,STATION1_TEAMSW,STATION2_TEAMSW,ROLE_TEAMSW" | out-file -Append -FilePath $teamSchemeFile -Encoding UTF8

    foreach ($key in $feederDeviceDict.Keys) {
        foreach ($value in $feederDeviceDict[$key]) {
            "TEAMSWITCH,1,"+ $value.ToUpper() + "," + $key.ToUpper() + "_TEAM,na,na," + $key.ToUpper() + ",,PRIMARY"  | out-file -Append -FilePath $teamSchemeFile -Encoding UTF8   
        }
    }

    #atomic copy the update to avoid dropping icons if model and csv are updating at the same time
    Move-Item -Path $teamSchemeFile -Destination $teamSchemeFileCSV -Force
}

else {
    "FISR feeders file not found..." | out-file -Append -FilePath $logFile -Encoding UTF8
}


