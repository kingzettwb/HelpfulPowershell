#Author: Bill Kingzett
#Date: 2026-07-01
#Description: Gets a list of any installed .NET applications (.NET Runtime, .NET Core and ASP.NET Core), uninstalls the old versions, then downloads and installs the latest version (within the current major version unless it's EoL)
#
#Error codes:
#0: Success or not installed
#1: General Error
#82: Failed to download new version
#
#Resources:
#Downloading files: https://www.powershellgallery.com/packages/Evergreen/2505.2104/Content/Apps%5CGet-Microsoft.NET.ps1
#Download strings: https://www.powershellgallery.com/packages/Evergreen/2505.2104/Content/Manifests%5CMicrosoft.NET.json
#Thanks to Aaron Parker for the Evergreen module
#Creating Regex to match on multiple items: https://stackoverflow.com/questions/77748195/powershell-wildcard-array-in-the-where-clause

$ForceLTS = $true
$UpgradeBeforeEoL = $false
$LogLocation = "C:\Temp\Logs"

function Uninstall-App
{
    param (
    [Parameter(Mandatory)] [string]$UninstallString = ""
    )
    if ($UninstallString -match "msiexec") {  
        write-debug "uninstall string matches MSIEXEC"
	    # when the command calls for MSIEXEC, build the command and msiexec command arguments - perform a specified MSIEXEC function such as /f for repair
        $commandArgs = @();
        $commandArgs += "/x"
        $commandArgs += $UninstallString -replace "msiexec\.exe\s/[IX]{1}", ""
        $commandArgs += "/quiet"        
        $commandArgs += "/norestart"
        $commandArgs += "IGNOREDEPENDENCIES=ALL"
        $commandArgs += "/l*v"
        $commandArgs += "C:\ProgramData\Genome\Logs\doNET-RemovalMSI.log"
        Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Running uninstall: msiexec.exe $CommandArgs"
        $proc = start-process "msiexec.exe" -ArgumentList $CommandArgs -Wait -PassThru
        return $proc.ExitCode
    } 
    else { 
        write-debug "uninstall string matches EXE or something else"
	    # the command associated to Uninstall is an EXE.  Assume (while coding at this time), that the correct silent removal argument is "/S";
	    # in the future, this may make a good place for the script to provide an argument instead of making this assumption.  It may pass we wish to use other or additional arguments.
        if ( ($UninstallString -replace '"', '') -match '^(.*exe)\s*(.*)' ) { 
            $RemovalCommand = $Matches[1]
            $commandArgs = $Matches[2] -split ' '
            if ($commandArgs -eq $null)
            {
                $commandArgs += "/S"
                $commandArgs += "/noreboot" 
            }  
        }
        Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Running uninstall: $RemovalCommand $CommandArgs"
        $proc = start-process $RemovalCommand -ArgumentList $CommandArgs -PassThru -wait
        return $proc.ExitCode
    }
}
function Wildcard-toRegex($WildcardString) #Takes a string or array of strings, escapes them and translates * to the regex wildcard equivalent
{ #Also allows you to match on multiple strings
    $Result = @()
    $WildcardString | ForEach-Object {
    $_ = $_.Trim('*')
    $_ = [regex]::Escape($_)
    $_ = $_.Insert(0,'(')
    $_ += ')'
    $_ = $_.Replace('\*','.*?')
    $Result += $_
    }
    $Result = $Result -join '|'
    if ($Result -eq '|'){$Result = $null}  #Fixes error condition where it may return only | if $WildcardString is empty, which is everything
    return $Result
}

if (!(Get-Item -Path $LogLocation -ErrorAction SilentlyContinue))
{
  if (!(Get-Item -Path $LogLocation.substring(0, $LogLocation.LastIndexOf('\'))))
  {New-Item -Path $LogLocation.substring(0, $LogLocation.LastIndexOf('\'))}
  New-Item -Path $LogLocation -ItemType Directory
}

#Clear large logs
if ((Get-Item -Path "$LogLocation\dotNETupdate.log" -ErrorAction SilentlyContinue).Length -ge "1000000")
{
    Start-Transcript -Path "$LogLocation\dotNETupdate.log" #If log is already bigger than 1 MB, overwrite it
}else { Start-Transcript -Path "$LogLocation\dotNETupdate.log" -Append }

$Architecture = ""
$ProgramName = ""
$Type = ""
$MarkedforAddition = @()
[int]$Exitcode = 0
$Programs = "*.NET Runtime*","*ASP.NET Core * Shared Framework*","*Windows Desktop Runtime*"

$regpath = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
            'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')

$ContentType = "application/json; charset=utf-8"
$Method = "Default"
$SslProtocol = "Tls12"
$ReleasesURI = "https://dotnetcli.blob.core.windows.net/dotnet/release-metadata/#version/releases.json" #Release Dates, Files, EoL Dates, etc
$LatestURI = "https://dotnetcli.blob.core.windows.net/dotnet/Runtime/LTS/latest.version" #Version of latest LTS
$params = @{
        Uri                = $LatestUri
        ContentType        = $ContentType
        DisableKeepAlive   = $true
        MaximumRedirection = 2
        Method             = $Method
        UseBasicParsing    = $true
    }

$Regex = Wildcard-toRegex $Programs
$Installed = Get-ItemProperty $regpath | .{process{if($_.DisplayName -and $_.UninstallString) { $_ } }} | Where-Object { $_.displayname -match $Regex } | Select DisplayName, VersionMajor, VersionMinor, UninstallString, QuietUninstallString

if ($Installed -ne $null) #If no .NET installed, skip web checks
{
    $LatestVersionResponse = Invoke-RestMethod @params
    $LatestVersion = [System.Version] $LatestVersionResponse #Version of latest LTS
    $LatestVersionMajorMinor = "$($LatestVersion.Major).$($LatestVersion.Minor)"
    $params.Uri = $ReleasesUri -replace "#version", $LatestVersionMajorMinor
    $LatestReleases = Invoke-RestMethod @params #Release information for latest LTS
} else
{
    Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] No .NET installed"
}

foreach ($app in $Installed)
{
    Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Found $($app.DisplayName)"
    $AppName = $App.DisplayName -replace "\s", ""
    if ($AppName.Contains("("))
    {
        $AppName = $AppName.Substring(0,$AppName.IndexOf("("))
    }
    $AppVersion = $AppName -replace "[^0-9.]" , ''
    $AppVersion = $AppVersion.TrimStart(".")
    $AppVersion = New-Object System.Version $AppVersion #.NET version number parsed from display name

    $Architecture = $App.DisplayName.Substring($App.Displayname.IndexOf('('))
    if ($Architecture -eq "(x86)")
    {
        $Architecture = "win-x86" #The architecture of the program so we can download the correct version
    } elseif ($Architecture -eq "(x64)")
    { #If for some reason we fail to get the architecture, assume 64-bit
        $Architecture = "win-x64"
    } else
    {
        Write-Host "Unable to determine Architecture. Assuming 64-bit."
        $Architecture = "win-x64"
    }
    $MajorMinor = "$($AppVersion.Major).$($AppVersion.Minor)"
    $params.Uri = $ReleasesUri -replace "#version", $MajorMinor
    $Releases = Invoke-RestMethod @params #Get information about installed version

    if (($ForceLTS -eq $true -and $Releases.'release-type' -ne 'lts') -or ([version]$AppVersion -lt [version]$Releases.'latest-release' -and $Releases.'support-phase' -ne 'eol'))
    { #If not long-term service (8, 10) and not exempted or if it's EoL, remove. Also continue if there's a newer LTS available
        $AppNameOnly = ($App.DisplayName -split "[-0-9]")[0] #Removes version info to get name only
        $type = switch -Wildcard ($AppNameOnly)
        {
            "*.NET Runtime*" {'runtime'} #Program type names from website
            "*ASP.NET Core*" {'aspnetcore-runtime'}
            "*Windows Desktop Runtime*" {'windowsdesktop'}
        }
        
        #Update within major version if not EoL
        if ([version]$AppVersion -lt [version]$Releases.'latest-release' -and $Releases.'support-phase' -ne 'eol' -and $UpgradeBeforeEoL -eq $false -and $Releases.'release-type' -eq 'lts')
        {#Update within current version
            $DownloadURL = $Releases.releases[0]."$Type".files | where {$_.name -match "\.exe$" -and $_.rid -eq $Architecture} | Select -Property "url" -ExpandProperty "url"
            $LatestAppName = $App.DisplayName -replace "$($AppVersion.ToString())", "$($Releases.'latest-release')"
        } else {#Update to latest version
            $DownloadURL = $LatestReleases.releases[0]."$Type".files | where {$_.name -match "\.exe$" -and $_.rid -eq $Architecture} | Select -Property "url" -ExpandProperty "url"
            $LatestAppName = $App.DisplayName -replace "$($AppVersion.ToString())", "$($LatestVersion.ToString())"
            }
        $MarkedforAddition += [pscustomobject]@{Application="$LatestAppName";Architechture="$Architecture";URL="$DownloadURL";AppVersion="$AppVersion"}
        Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Uninstalling $($App.DisplayName) ..."
        if ($app.QuietUninstallString -ne $null) {$app.UninstallString = $app.QuietUninstallString}
        $ExitResult = Uninstall-App $app.UninstallString
        if ($ExitResult -ne 0)
        {
            Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Uninstall of $($app.DisplayName) failed with error $ExitResult"
            Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Attempting to download installer, then reattempt removal."
            $RepairdownloadURL = ($Releases.releases | Where release-version -EQ $AppVersion)."$Type".files | where {$_.name -match "\.exe$" -and $_.rid -eq $Architecture} | Select -Property "url" -ExpandProperty "url"
            $params.Uri = $RepairdownloadURL
            $SaveName = $RepairdownloadURL.Substring($RepairdownloadURL.LastIndexOf('/') + 1)
            Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Starting download of $($App.DisplayName) to C:\temp\$SaveName"
            Invoke-RestMethod @params -OutFile "C:\temp\$SaveName" #Download the installer for the old version and try to uninstall that way

            if (Get-Item -Path "C:\temp\$SaveName")
            {
                Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Download saved to C:\temp\$SaveName"
                Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Running C:\temp\$SaveName /uninstall /quiet"
                $ExitResult = Uninstall-App "C:\temp\$SaveName /uninstall /quiet"
                if ($ExitResult -ne 0)
                {
                    Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Removal failed. Running repair of $($App.DisplayName)"
                    $Repairargs = @("/repair", "/quiet", "/norestart")
                    $proc = start-process "C:\temp\$SaveName" -ArgumentList $RepairArgs -Wait -PassThru
                    if ($proc.ExitCode -eq 0)
                    {
                       Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Repair successful, reattempting uninstall."
                       $ExitResult = Uninstall-App $app.UninstallString
                       if ($ExitResult -ne 0) {Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Second uninstall attempt failed."}
                       else {Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Second uninstall attempt successful!"}
                    } else {Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Repair failed."}
                }
                Remove-Item "C:\temp\$SaveName" -Force
                $Exitcode = $ExitResult 
             } else {Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Repair download failed."}
          } else {Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Uninstall successful."}
        } else
        {
            Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] $($App.DisplayName) is the latest version or exempt. Skipping..."
        }
}

#Run installs
$MarkedforAddition = $MarkedforAddition | Sort-Object -Property * -Unique
Write-Host "Found for addition: $($MarkedforAddition | Select Application -expandproperty Application)"

#Microsoft Windows Desktop Runtime includes Microsoft .NET Runtime. If a Desktop Runtime of the same architecture is installed, skip .NET Runtime install
$Runtime = $MarkedforAddition | Where Application -Like "Microsoft .NET Runtime*"
$WithoutRuntime = $MarkedforAddition | Where Application -NotLike "Microsoft .NET Runtime*"

if ($Runtime -ne $null)
{
    $NewMarkedforAddition = @()
    foreach ($NETRuntime in $Runtime)
    {
        if (($WithoutRuntime | Where {$_.Application -like "Microsoft Windows Desktop Runtime*" -and $_.Architecture -eq $NETRuntime.Architecture}) -eq $null)
        {
            $NewMarkedforAddition += $NETRuntime
        } else {Write-Host "$($NetRuntime.Application) not needed as associated Windows Desktop Runtime includes it. Skipping..."}
    }
    $NewMarkedforAddition += $WithoutRuntime
    $MarkedforAddition = $NewMarkedforAddition
}


$InstallArgs = @("/silent", "/quiet", "/norestart")
foreach ($install in $MarkedforAddition)
{
    if ($install.Application -notin ($Installed | Select DisplayName -ExpandProperty DisplayName)) #Check if newest version is already installed
    {
        $params.Uri = $install.URL
        $SaveName = $install.URL.Substring($Install.URL.LastIndexOf('/') + 1)
        Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Starting download to C:\temp\$SaveName"
        Invoke-RestMethod @params -OutFile "C:\temp\$SaveName"
        if (Get-Item -Path "C:\temp\$SaveName")
        {
            Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Download saved to C:\temp\$SaveName"
            Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Installing $($install.Application) ..."
            $proc = start-process "C:\temp\$SaveName" -ArgumentList $InstallArgs -Wait -PassThru
            if ($proc.exitcode -ne 0)
            {
                Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] File $SaveName failed to install with error code $($proc.exitcode)."
                $Exitcode = $proc.ExitCode
            }
            Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Install finished, cleaning up file..."
            Remove-Item "C:\temp\$SaveName" -Force
        } else
        {
            Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] File $SaveName failed to download, marking ExitCode as 82. Skipping install..."
            $Exitcode = 82
        }
    } else
    {
        $NewAppName = $install.Application.Replace("$($install.AppVersion)","$LatestVersion")
        Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] $NewAppName is already installed. Skipping install..."
    }

}
if ($MarkedforAddition -eq $null)
{
    Write-Host "[$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")] Nothing marked for update"
}

Write-Host "Completed .NET update script. Exiting..."
Stop-Transcript
exit $Exitcode
