#Requires -Version 5.1
<#
.SYNOPSIS
    Aktiviert RDP Shortpath (UDP) ueber Private Link fuer einen AVD Host Pool.
.DESCRIPTION
    Setzt in EINEM einzigen PATCH-Aufruf (az rest) die drei Host-Pool-Eigenschaften,
    die das Azure-Portal nur gegenseitig abhaengig speichern laesst:
      - publicUDP                        -> Disabled (Shortpath public networks via STUN)
      - relayUDP                         -> Disabled (Shortpath public networks via TURN/Relay)
      - allowRDPShortPathWithPrivateLink -> Enabled  (Allow Direct UDP network path with Private Link)
    Die Managed-Networks-Einstellungen (managedPrivateUDP, directUDP) werden nicht veraendert.
    Das Script zeigt den Zustand vor und nach der Aenderung und vergleicht ihn mit dem Sollwert.
    Lehnt der Dienst den Aufruf ab, wird nichts geaendert und die Fehlermeldung ausgegeben.
.NOTES
    =========================================================================
    Author      : Alexander Ortha
    Company     : Alexander Ortha IT Solutions
    Contact     : https://ortha-itsolutions.de/
    Created     : 2026-11-10
    Version     : 1.0.0
    Copyright   : (c) 2026 Alexander Ortha IT Solutions. All rights reserved.
    -------------------------------------------------------------------------
    Code created by Alexander Ortha.
    Development supported through AI-tools.
    =========================================================================
.EXAMPLE
    .\Set-AvdShortpathPrivateLink.ps1
#>

# ============================================================
# PARAMETER (im Script hinterlegt)
# ============================================================
$ScriptVersion       = "1.0.0"
$PowerShellMode      = "Compat"     # "Compat" = 5.1 + 7.x | "Seven" = bricht unter 5.1 ab

$SubscriptionId      = "33207861-9482-4afb-9786-eba3a0265bef"
$ResourceGroupName   = "rg-avd-HostPool1-Test"
$HostPoolName        = "HostPool1-Test"
$ApiVersion          = "2026-04-16"

# Sollwerte (zulaessig laut REST-Referenz: Default | Enabled | Disabled bzw. Enabled | Disabled)
$TargetPublicUdp     = "Disabled"
$TargetRelayUdp      = "Disabled"
$TargetAllowShortpathPrivateLink = "Enabled"

$ConfirmBeforeChange = $true        # $true = Rueckfrage vor dem Schreiben

# ============================================================
# GRUNDEINSTELLUNGEN
# ============================================================
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$SymOk   = [System.Char]::ConvertFromUtf32(0x2705)
$SymErr  = [System.Char]::ConvertFromUtf32(0x274C)
$SymWarn = [System.Char]::ConvertFromUtf32(0x26A0) + [System.Char]::ConvertFromUtf32(0xFE0F)
$SymInfo = [System.Char]::ConvertFromUtf32(0x2139) + [System.Char]::ConvertFromUtf32(0xFE0F)
$SymRun  = [System.Char]::ConvertFromUtf32(0x1F504)

$BodyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("avd-shortpath-body-" + [System.Guid]::NewGuid().ToString("N") + ".json")
$HostPoolUrl = "https://management.azure.com/subscriptions/" + $SubscriptionId +
               "/resourceGroups/" + $ResourceGroupName +
               "/providers/Microsoft.DesktopVirtualization/hostPools/" + $HostPoolName

# ============================================================
# HILFSFUNKTIONEN
# ============================================================
function Write-Line {
    Write-Host ("=" * 60) -ForegroundColor White
}

function Write-Section {
    param([string]$Title)
    Write-Host ("[ " + $Title + " ]") -ForegroundColor White
}

function Write-Status {
    param(
        [string]$Symbol,
        [string]$Text,
        [string]$Color = "Cyan",
        [switch]$Indent,
        [switch]$Stamp
    )
    $prefix = ""
    if ($Indent) { $prefix = "    " }
    $timeText = ""
    if ($Stamp) { $timeText = "[" + (Get-Date -Format "HH:mm:ss") + "] " }
    Write-Host ($prefix + $timeText + $Symbol + "  " + $Text) -ForegroundColor $Color
}

function Remove-BodyFile {
    if (Test-Path -LiteralPath $BodyFile) {
        Remove-Item -LiteralPath $BodyFile -Force -ErrorAction SilentlyContinue
    }
}

# Fuehrt az aus und unterdrueckt stderr. Argumente als Array.
function Invoke-AzQuiet {
    param([string[]]$AzArguments)
    $result = & az @AzArguments 2>$null
    return $result
}

# Fuehrt az aus und liefert stdout + stderr als Textzeilen (fuer Fehlermeldungen des Dienstes).
function Invoke-AzCapture {
    param([string[]]$AzArguments)
    $raw = & az @AzArguments 2>&1
    $lines = @()
    foreach ($item in $raw) { $lines += [string]$item }
    return $lines
}

# Prueft $LASTEXITCODE des zuletzt ausgefuehrten externen Programms.
function Assert-AzSuccess {
    param(
        [string]$Action,
        [string[]]$Details
    )
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Status -Symbol $SymErr -Text ($Action + " fehlgeschlagen (ExitCode " + $exitCode + ")") -Color Red -Stamp
        if ($Details) {
            foreach ($detailLine in $Details) {
                if ($detailLine -and $detailLine.Trim().Length -gt 0) {
                    Write-Host ("    " + $detailLine) -ForegroundColor Red
                }
            }
        }
        Remove-BodyFile
        Write-Line
        exit 1
    }
}

function Get-HostPoolShortpathState {
    $getArgs = @(
        "rest",
        "--method", "get",
        "--url", $HostPoolUrl,
        "--uri-parameters", ("api-version=" + $ApiVersion),
        "--output", "json"
    )
    $jsonLines = Invoke-AzQuiet -AzArguments $getArgs
    Assert-AzSuccess -Action "Lesen des Host Pools"
    $jsonText = ($jsonLines -join "`n")
    if (-not $jsonText -or $jsonText.Trim().Length -eq 0) {
        Write-Status -Symbol $SymErr -Text "Leere Antwort beim Lesen des Host Pools" -Color Red
        Remove-BodyFile
        exit 1
    }
    $hostPool = $jsonText | ConvertFrom-Json
    return $hostPool.properties
}

function Format-Value {
    param($Value)
    if ($null -eq $Value -or ([string]$Value).Length -eq 0) { return "(nicht gesetzt)" }
    return [string]$Value
}

function Show-ShortpathState {
    param($Properties)
    Write-Status -Symbol $SymInfo -Text ("publicNetworkAccess              : " + (Format-Value $Properties.publicNetworkAccess)) -Indent
    Write-Status -Symbol $SymInfo -Text ("managedPrivateUDP                : " + (Format-Value $Properties.managedPrivateUDP)) -Indent
    Write-Status -Symbol $SymInfo -Text ("directUDP                        : " + (Format-Value $Properties.directUDP)) -Indent
    Write-Status -Symbol $SymInfo -Text ("publicUDP                        : " + (Format-Value $Properties.publicUDP)) -Indent
    Write-Status -Symbol $SymInfo -Text ("relayUDP                         : " + (Format-Value $Properties.relayUDP)) -Indent
    Write-Status -Symbol $SymInfo -Text ("allowRDPShortPathWithPrivateLink : " + (Format-Value $Properties.allowRDPShortPathWithPrivateLink)) -Indent
}

function Test-TargetReached {
    param($Properties)
    $reached = $true
    if ([string]$Properties.publicUDP -ne $TargetPublicUdp) { $reached = $false }
    if ([string]$Properties.relayUDP -ne $TargetRelayUdp) { $reached = $false }
    if ([string]$Properties.allowRDPShortPathWithPrivateLink -ne $TargetAllowShortpathPrivateLink) { $reached = $false }
    return $reached
}

# ============================================================
# PRE-CHECK
# ============================================================
Write-Line
Write-Section "PRE-CHECK"

# --- PowerShell-Version / Modus ---
$PsVer = $PSVersionTable.PSVersion
Write-Status -Symbol $SymInfo -Text "Pruefe PowerShell..."
if (($PowerShellMode -ne "Compat") -and ($PowerShellMode -ne "Seven")) {
    Write-Status -Symbol $SymErr -Text ("Ungueltiger Wert fuer PowerShellMode: " + $PowerShellMode) -Color Red
    Write-Line
    exit 1
}
if (($PowerShellMode -eq "Seven") -and ($PsVer.Major -lt 7)) {
    Write-Status -Symbol $SymErr -Text ("Modus 'Seven' erfordert PowerShell 7.x, gefunden: " + $PsVer.ToString()) -Color Red
    Write-Line
    exit 1
}
if (($PsVer.Major -gt 7) -or (($PsVer.Major -eq 7) -and ($PsVer.Minor -ge 3))) {
    $PSNativeCommandUseErrorActionPreference = $false
}
Write-Status -Symbol $SymOk -Text ("PowerShell " + $PsVer.ToString() + " (Modus: " + $PowerShellMode + ")") -Color Green

# --- Azure CLI vorhanden? ---
Write-Status -Symbol $SymInfo -Text "Pruefe Azure CLI..."
$AzCommand = Get-Command -Name "az" -ErrorAction SilentlyContinue
if ($null -eq $AzCommand) {
    Write-Status -Symbol $SymErr -Text "Azure CLI (az) nicht gefunden. Installation: https://aka.ms/installazurecli" -Color Red
    Write-Line
    exit 1
}
$AzVersionLines = Invoke-AzQuiet -AzArguments @("version", "--output", "json")
Assert-AzSuccess -Action "Abfrage der Azure CLI Version"
$AzVersionInfo = ($AzVersionLines -join "`n") | ConvertFrom-Json
$AzCliVersion = [string]$AzVersionInfo.'azure-cli'
Write-Status -Symbol $SymOk -Text ("Azure CLI gefunden: " + $AzCliVersion) -Color Green

# --- Azure CLI aktuell? ---
$AzVersionText = (Invoke-AzCapture -AzArguments @("--version")) -join "`n"
Assert-AzSuccess -Action "Pruefung auf Azure CLI Updates"
if ($AzVersionText -like "*up-to-date*") {
    Write-Status -Symbol $SymOk -Text "Azure CLI ist aktuell" -Color Green
}
elseif ($AzVersionText -like "*update*available*") {
    Write-Status -Symbol $SymWarn -Text "Neuere Version verfuegbar (Aktualisierung mit: az upgrade)" -Color Yellow
}
else {
    Write-Status -Symbol $SymInfo -Text "Update-Status konnte nicht ermittelt werden"
}

# --- Azure Login vorhanden? ---
Write-Status -Symbol $SymInfo -Text "Pruefe Azure Login..."
$AccountLines = Invoke-AzQuiet -AzArguments @("account", "show", "--output", "json")
if ($LASTEXITCODE -ne 0) {
    Write-Status -Symbol $SymWarn -Text "Kein Login vorhanden, starte az login..." -Color Yellow
    & az login --output none
    Assert-AzSuccess -Action "az login"
    $AccountLines = Invoke-AzQuiet -AzArguments @("account", "show", "--output", "json")
    Assert-AzSuccess -Action "Abfrage des Azure Kontos"
}
$AccountInfo = ($AccountLines -join "`n") | ConvertFrom-Json
Write-Status -Symbol $SymOk -Text ("Login vorhanden: " + [string]$AccountInfo.user.name) -Color Green
Write-Status -Symbol $SymInfo -Text ("Aktive Subscription: " + [string]$AccountInfo.name) -Indent
Write-Line

Write-Status -Symbol $SymInfo -Text ("Script-Version: " + $ScriptVersion)
Write-Status -Symbol $SymInfo -Text ("Host Pool     : " + $HostPoolName + " (" + $ResourceGroupName + ")")
Write-Status -Symbol $SymInfo -Text ("API-Version   : " + $ApiVersion)
Write-Line

# ============================================================
# IST-ZUSTAND
# ============================================================
Write-Section "IST-ZUSTAND"
Write-Status -Symbol $SymRun -Text "Lese aktuelle Einstellungen..." -Stamp
$StateBefore = Get-HostPoolShortpathState
Show-ShortpathState -Properties $StateBefore

if ([string]$StateBefore.publicNetworkAccess -eq "Enabled") {
    Write-Status -Symbol $SymWarn -Text "publicNetworkAccess ist 'Enabled': Der Host Pool erzwingt kein Private Link." -Color Yellow
    Write-Status -Symbol $SymWarn -Text "Das Deaktivieren von STUN/TURN ist dann nicht noetig. Bitte Sollwerte pruefen." -Color Yellow -Indent
}

if (Test-TargetReached -Properties $StateBefore) {
    Write-Status -Symbol $SymOk -Text "Sollzustand ist bereits erreicht, keine Aenderung noetig." -Color Green
    Write-Line
    exit 0
}
Write-Line

# ============================================================
# GEPLANTE AENDERUNG
# ============================================================
Write-Section "GEPLANTE AENDERUNG"
Write-Status -Symbol $SymInfo -Text ("publicUDP                        : " + (Format-Value $StateBefore.publicUDP) + " -> " + $TargetPublicUdp) -Indent
Write-Status -Symbol $SymInfo -Text ("relayUDP                         : " + (Format-Value $StateBefore.relayUDP) + " -> " + $TargetRelayUdp) -Indent
Write-Status -Symbol $SymInfo -Text ("allowRDPShortPathWithPrivateLink : " + (Format-Value $StateBefore.allowRDPShortPathWithPrivateLink) + " -> " + $TargetAllowShortpathPrivateLink) -Indent
Write-Status -Symbol $SymInfo -Text "managedPrivateUDP und directUDP bleiben unveraendert." -Indent

if ($ConfirmBeforeChange) {
    $Answer = Read-Host "Aenderung jetzt durchfuehren? (j/n)"
    if ($Answer -ne "j") {
        Write-Status -Symbol $SymWarn -Text "Abbruch durch Benutzer, es wurde nichts geaendert." -Color Yellow
        Write-Line
        exit 0
    }
}
Write-Line

# ============================================================
# AENDERUNG (ein PATCH, Body als Datei)
# ============================================================
Write-Section "AENDERUNG"
$BodyObject = @{
    properties = [ordered]@{
        publicUDP                        = $TargetPublicUdp
        relayUDP                         = $TargetRelayUdp
        allowRDPShortPathWithPrivateLink = $TargetAllowShortpathPrivateLink
    }
}
$BodyJson = $BodyObject | ConvertTo-Json -Depth 5
Set-Content -LiteralPath $BodyFile -Value $BodyJson -Encoding ASCII

Write-Status -Symbol $SymRun -Text "Sende PATCH an den Host Pool..." -Stamp
$PatchArgs = @(
    "rest",
    "--method", "patch",
    "--url", $HostPoolUrl,
    "--uri-parameters", ("api-version=" + $ApiVersion),
    "--headers", "Content-Type=application/json",
    "--body", ("@" + $BodyFile),
    "--output", "json"
)
$PatchOutput = Invoke-AzCapture -AzArguments $PatchArgs
Assert-AzSuccess -Action "PATCH des Host Pools" -Details $PatchOutput
Write-Status -Symbol $SymOk -Text "PATCH wurde vom Dienst angenommen." -Color Green -Stamp
Remove-BodyFile
Write-Line

# ============================================================
# KONTROLLE
# ============================================================
Write-Section "KONTROLLE"
Write-Status -Symbol $SymRun -Text "Lese Einstellungen erneut..." -Stamp
$StateAfter = Get-HostPoolShortpathState
Show-ShortpathState -Properties $StateAfter

if (Test-TargetReached -Properties $StateAfter) {
    Write-Status -Symbol $SymOk -Text "Sollzustand erreicht." -Color Green
    Write-Status -Symbol $SymInfo -Text "Die Aenderung wirkt nur auf neue Verbindungen." -Indent
    Write-Line
    exit 0
}
else {
    Write-Status -Symbol $SymErr -Text "Sollzustand NICHT erreicht, bitte Werte oben pruefen." -Color Red
    Write-Line
    exit 1
}
