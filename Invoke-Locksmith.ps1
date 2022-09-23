<#
.SYNOPSIS
Finds the most common malconfigurations of Active Directory Certificate Services (AD CS).

.DESCRIPTION
Locksmith uses the Active Directory (DA) Powershell (PS) module to identify 6 misconfigurations
commonly found in Enterprise mode AD CS installations.

.COMPONENT
Locksmith requires the AD PS module to be installed in the scope of the Current User.
If Locksmith does not identify the AD PS module as installed, it will attempt to 
install the module. If module installation does not complete successfully, 
Locksmith will fail.

.PARAMETER Forest
Specifies a single forest to be scanned by Invoke-Locksmith.ps1. Useful in large environments that may
take a while to enumerate.

.PARAMETER InputPath
Specifies an input file containing a list of forests to be checked. Input file should consist of
a forest per line of the input file. If this parameter is not defined at runtime,
Invoke-Locksmith.ps1 will attempt to scan every AD CS installation it can find in the forest.

.PARAMETER Mode
Specifies sets of common configurations.
-Mode 0
Finds and displays any malconfiguration in the console.
Outputs a custom PS object for further processing.
No attempt is made to fix identified issues.

-Mode 1
Finds any malconfigurations and writes them to a series of CSV files.
No attempt is made to fix identified issues.
If OutputPath is not defined, Invoke-Locksmith.ps1 will create its output in the local directory. 

-Mode 2
Finds any malconfigurations and writes them to a series of CSV files.
Creates code snippets to fix each issue and writes them to an environment-specific custom .ps1 file.
No attempt is made to fix identified issues.
If OutputPath is not defined, Invoke-Locksmith.ps1 will create its output in the local directory. 

-Mode 3
Finds any malconfigurations and writes them to a series of CSV files.
Creates code snippets to fix each issue and writes them to an environment-specific custom .ps1 file.
Attempts to fix all identified issues. This mode may require high-privileged access.
If OutputPath is not defined, Invoke-Locksmith.ps1 will create its output in the local directory. 

.PARAMETER OutputPath
Specifies the name and path for the CSV-based output file. If this parameter is not defined at runtime,
Invoke-Locksmith.ps1 will output its results to the console.

.INPUTS
None. You cannot pipe objects to Invoke-Locksmith.ps1.

.OUTPUTS
Output types:
1. Console display of identified issues
2. Custom PS Object containing identified issues
3. CSV for each type of malconfiguration
4. Custom .ps1 to resolve each identified issue

.EXAMPLE
PS> .\Invoke-Locksmith.ps1

Description
-------------------------
Running Invoke-Locksmith.ps1 with no parameters configured will scan any AD CS installation accessible to the user
and output all discovered AD CS issues to the console.

.EXAMPLE
PS> .\Invoke-Locksmith.ps1 -InputPath .\TrustedForests.txt

Description
-------------------------
Specifying an input file of forests will force Invoke-Locksmith.ps1 to attempt to scan the specific forests
listed in TrustedForests.txt regardless of permissions or visibility into the forest. Because no Mode is
defined, identified issues will not be written to files.

.EXAMPLE
PS> .\Invoke-Locksmith.ps1 -Mode 1 -OutputPath C:\Users\thanks\Documents

Description
-------------------------
In Mode 1, Locksmith will scan all AD CS installations it can find and write its findings to a series
of CSVs in C:\Users\thanks\Documents.

.EXAMPLE
PS> .\Invoke-Locksmith.ps1 -Mode 2 -Forest it.example.com

Description
-------------------------
In this example, Locksmith will only scan the AD CS installation of it.example.com, regardless of how many
forests it can actually access. All malconfigurations and snippets to fix them will output to the local path.

.EXAMPLE
PS> .\Invoke-Locksmith.ps1 -Mode 3 -OutputPath E:\ADisCheeseSwiss

Description
-------------------------
Mode 3 is the "easy button." Running Locksmith in Mode 3 will identify all malconfigs and output them to CSV
files located in E:\ADisCheeseSwiss. Then it will display the snippets it plans to run and waits for human
interaction to confirm everything looks correct.
#>

[CmdletBinding()]
param (
    [string]$Forest,
    [string]$InputPath,
    [int]$Mode,
    [string]$OutputPath = (Get-Location).Path
)

$Logo = "
 _       _____  _______ _     _ _______ _______ _____ _______ _     _
 |      |     | |       |____/  |______ |  |  |   |      |    |_____|
 |_____ |_____| |_____  |    \_ ______| |  |  | __|__    |    |     |
     .--.                  .--.                  .--.            
    /.-. '----------.     /.-. '----------.     /.-. '----------.
    \'-' .--'--''-'-'     \'-' .--'--''-'-'     \'-' .--'--''-'-'
     '--'                  '--'                  '--'            
"
$Logo

# TODO Convert to SID 
$SafeOwners = "Domain Admins|Enterprise Admins|BUILTIN\\Administrators|NT AUTHORITY\\SYSTEM|\\Cert Publishers|\\Administrator"
$SafeUsers = "Domain Admins|Enterprise Admins|BUILTIN\\Administrators|NT AUTHORITY\\SYSTEM|\\Cert Publishers|\\Administrator"
$ClientAuthEKUs = "1\.3\.6\.1\.5\.5\.7\.3\.2|1\.3\.6\.1\.5\.2\.3\.4|1\.3\.6\.1\.4\.1\.311\.20\.2\.2|2\.5\.29\.37\.0"
$DangerousRights = "GenericAll|WriteDacl|WriteOwner"

function Get-Targets {
    param (
        [string]$Forest,
        [string]$InputPath
    )

    # Get forests to analyze
    if ($Forest) {
        $Targets = $Forest
    } elseif ($InputPath) {
        $Targets = Get-Content $InputPath
    } else {
        $Targets = (Get-ADForest).Forests
    }
    return $Targets
}

function New-OutputPath {
    # Create one output directory per forest
    foreach ( $forest in $Targets ) {
        $ForestPath = $OutputPath + "`\" + $forest
        New-Item -Path $ForestPath -ItemType Directory -Force  | Out-Null
    }
}

function Get-ADCSObjects {
    foreach ( $forest in $Targets ) {
        $ADRoot = (Get-ADRootDSE -Server $forest).defaultNamingContext
        Get-ADObject -Filter * -SearchBase "CN=Public Key Services,CN=Services,CN=Configuration,$ADRoot" -SearchScope 2 -Properties * 
    }
}

# TODO: Combine Get-*Names functions into a single function
# TODO: Ultimate goal is to collect info about each CA as a custom object
function Get-CAFullNames {
    foreach ($item in (certutil | Select-String "^\s*Config:")) {
        ($item -Split "`"")[1]
    }
}

function Get-CANames {
    foreach ($item in (certutil | Select-String "^\s*Name:")) {
        ($item -Split "`"")[1]
    }
}

function Get-CANHostnames {
    foreach ($item in (certutil | Select-String "^\s*Server:")) {
        ($item -Split "`"")[1]
    }
}

# Use this one for testing arrays with length >1
function Get-CANamesLong {
    foreach ($item in (certutil | Select-String "Name:")) {
        ($item -Split "`"")[1]
    }
}

function Get-ADCSAuditing { 
    param (
        # Created by Get-CAFullNames
        [Parameter(Mandatory)]
        [array]$CAFullNames
    )
    foreach ($CA in $CAFullNames) {
        # TODO Add try/catch here
        certutil -config $CA -getreg CA\AuditFilter
    }
}

function Find-ESC1 {
    param(
        [Parameter(Mandatory = $true)]
        [array]$ADCSObjects,
        [string]$SafeUsers,
        [string]
    )
    $ADCSObjects | Where-Object {
        ($_.ObjectClass -eq "pKICertificateTemplate") -and
        ($_.pkiExtendedKeyUsage -match $ClientAuthEKUs) -and
        ($_."msPKI-Certificate-Name-Flag" -eq 1) -and
        ($_."msPKI-Enrollment-Flag" -ne 2) -and
        ( ($_."msPKI-RA-Signature" -eq 0) -or ($null -eq $_."msPKI-RA-Signature") ) 
    } | ForEach-Object {
        for ($i = 0; $i -le $_.ACL.count; $i += 1) {
            if (($_.ACL[$i] -notmatch $SafeUsers) -and #replace .ACL property with ntSecurityDesriptor stuff
            ($_.ACL[$i] -match "ExtendedRight")) {
                
            }
        }
    }
}

function Find-ESC2 {

}

function Find-ESC4 {

}

function Find-ESC5 {

}

function Find-ESC6 {
    certutil -v -config $CAFullNameTemp -getreg "policy\EditFlags" | Set-Content $Output\$CAShortNameTemp-RegConfig.txt
}

function Repair-ADCSAuditing {

}

function Repair-ESC1 {

}

function Repair-ESC2 {

}

function Repair-ESC4 {

}

function Repair-ESC5 {

}

function Repair-ESC6 {

}

function Write-Findings {

}