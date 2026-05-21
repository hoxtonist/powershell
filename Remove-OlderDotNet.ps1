#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes all .NET 6 and 7 installations, removes outdated .NET 8.0.x packages 
based on per-component compliance, and verifies remaining versions post-cleanup.

.DESCRIPTION
Scans the Windows registry for .NET 6, 7, and 8 family installations.
- All .NET 6 and 7 packages are flagged for immediate removal.
- For .NET 8, if an outdated 8.0.x package is found, it is only uninstalled 
  if a matching component at or above the minimum patch level is also installed.
Logs a final confirmation of installed packages before exiting.
#>

# ── Configuration ────────────────────────────────────────────────────────────
$minPatch = 26
$minVersion = [version]"8.0.$minPatch"

# ── Transcript / Logging ─────────────────────────────────────────────────────
$logPath = "$env:TEMP\dotnet-cleanup-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
Start-Transcript -Path $logPath -Force
Write-Host "Log file: $logPath" -ForegroundColor Cyan

# ── Helper: safe version parsing ─────────────────────────────────────────────
function ConvertTo-Version {
    param([string]$str)
    $v = $null
    $clean = $str -replace '[^0-9.]', ''
    if ([System.Version]::TryParse($clean, [ref]$v)) { return $v }
    return [version]"0.0.0"
}

# ── Helper: run an uninstall process and return the exit code ─────────────────
function Invoke-UninstallProcess {
    param([string]$FilePath, [string]$Arguments)
    try {
        $p = Start-Process -FilePath $FilePath `
            -ArgumentList $Arguments `
            -Wait -PassThru -WindowStyle Hidden `
            -ErrorAction Stop
        return $p.ExitCode
    }
    catch {
        Write-Warning "Process launch failed for '$FilePath $Arguments': $_"
        return -1
    }
}

# ── Helper: Query Registry for .NET 6, 7, and 8 packages ─────────────────────
function Get-DotNetPackages {
    $regBases = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    $foundPackages = foreach ($base in $regBases) {
        if (Test-Path $base) {
            Get-ChildItem $base -ErrorAction SilentlyContinue |
            Get-ItemProperty -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -and
                ($_.DisplayName -match "ASP\.NET|\.NET|Windows Desktop Runtime") -and
                ($_.DisplayVersion -match "^[678]\.0" -or $_.DisplayName -match "[678]\.0\.\d+")
            } |
            Select-Object `
            @{N='Name'; E={ $_.DisplayName }},
            @{N='BaseName'; E={
                # Strip version, architecture, and extra spaces/hyphens to match families
                $bn = $_.DisplayName -replace '[678]\.0\.\d+', '' -replace '\(x(64|86|arm64)\)', '' -replace '\s+', ' '
                $bn.Replace(' - ', ' ').Trim('- ').Trim()
            }},
            @{N='MajorVersion'; E={
                if ($_.DisplayVersion -match "^([678])\.0") { $Matches[1] }
                elseif ($_.DisplayName -match "([678])\.0\.\d+") { $Matches[1] }
                else { "0" }
            }},
            @{N='Version'; E={
                if ($_.DisplayVersion -match "^[678]\.0") { $_.DisplayVersion }
                elseif ($_.DisplayName -match "([678]\.0\.\d+)") { $Matches[1] }
                else { "0.0.0" }
            }},
            @{N='QuietUninstallString'; E={ $_.QuietUninstallString }},
            @{N='UninstallString'; E={ $_.UninstallString }}
        }
    }

    # De-duplicate and sort
    $foundPackages |
    Sort-Object Name, Version -Unique |
    Sort-Object { ConvertTo-Version $_.Version }
}

# ── 1. Discover .NET packages ────────────────────────────────────────────────
Write-Host "`nSearching registry for .NET 6, 7, and 8 family packages..." -ForegroundColor Cyan

$allInstalledDotNet = Get-DotNetPackages

if (-not $allInstalledDotNet) {
    Write-Host "No targeted .NET installations found in the registry." -ForegroundColor Yellow
    Stop-Transcript
    exit 0
}

Write-Host "`nFound the following .NET packages (Pre-Cleanup):" -ForegroundColor Cyan
$allInstalledDotNet | ForEach-Object { Write-Host " $($_.Name) [$($_.Version)]" }

# ── 2. Evaluate targets for removal ─────────────────────────────────────────
Write-Host "`nEvaluating package removal targets..." -ForegroundColor Cyan

$safeToRemove = @()

# Unconditionally target all .NET 6 and .NET 7 packages
$packages6and7 = $allInstalledDotNet | Where-Object { $_.MajorVersion -in '6', '7' }
if ($packages6and7) {
    Write-Host " Found $($packages6and7.Count) .NET 6/7 package(s) designated for absolute removal." -ForegroundColor Yellow
    $safeToRemove += $packages6and7
}

# Evaluate .NET 8 packages against compliance minimums
$dotnet8Packages = $allInstalledDotNet | Where-Object { $_.MajorVersion -eq '8' }
$oldDotNet8Packages = $dotnet8Packages | Where-Object { (ConvertTo-Version $_.Version) -lt $minVersion }

if ($oldDotNet8Packages) {
    foreach ($oldPkg in $oldDotNet8Packages) {
        # Find if there is a version of THIS SPECIFIC component >= the minimum patch
        $hasNewer = $dotnet8Packages | Where-Object {
            $_.BaseName -eq $oldPkg.BaseName -and
            (ConvertTo-Version $_.Version) -ge $minVersion
        }

        if ($hasNewer) {
            Write-Host " [Match Found] $($oldPkg.Name) has a compliant .NET 8 version installed." -ForegroundColor Green
            $safeToRemove += $oldPkg
        } else {
            Write-Host " [Skipping] $($oldPkg.Name) has no compliant .NET 8 version (>= 8.0.$minPatch) installed." -ForegroundColor Yellow
        }
    }
}

if (-not $safeToRemove) {
    Write-Host "`nNo actions required. No legacy .NET 6/7 or non-compliant .NET 8 packages targeted." -ForegroundColor Gray
    Stop-Transcript
    exit 0
}

Write-Host "`nProceeding with cleanup of $($safeToRemove.Count) targeted package(s)..." -ForegroundColor Cyan

# ── 3. Uninstall targeted packages ──────────────────────────────────────────
$rebootRequired = $false
$successCount = 0
$failCount = 0

foreach ($pkg in $safeToRemove) {
    Write-Host "`nRemoving: $($pkg.Name) (Version: $($pkg.Version))..." -ForegroundColor Yellow
    $uninstalled = $false
    $exitCode = -1

    try {
        # Strategy A: QuietUninstallString
        if ($pkg.QuietUninstallString) {
            Write-Verbose "Using QuietUninstallString: $($pkg.QuietUninstallString)"
            if ($pkg.QuietUninstallString -match '^"([^"]+)"\s*(.*)$') {
                $exe = $Matches[1]; $args = $Matches[2]
            } elseif ($pkg.QuietUninstallString -match '^(\S+)\s*(.*)$') {
                $exe = $Matches[1]; $args = $Matches[2]
            } else {
                $exe = $pkg.QuietUninstallString; $args = ''
            }

            $exitCode = Invoke-UninstallProcess -FilePath $exe -Arguments $args
            if ($exitCode -in 0, 3010, 1605) { $uninstalled = $true }
        }

        # Strategy B: msiexec via UninstallString
        if (-not $uninstalled -and $pkg.UninstallString -match "msiexec") {
            if ($pkg.UninstallString -match '\{[a-fA-F0-9-]{36}\}') {
                $guid = $Matches[0]
                Write-Verbose "Using msiexec /x $guid /qn /norestart"
                $exitCode = Invoke-UninstallProcess -FilePath "msiexec.exe" -Arguments "/x `"$guid`" /qn /norestart"
                if ($exitCode -in 0, 3010, 1605) { $uninstalled = $true }
            }
        }

        # Strategy C: plain UninstallString
        if (-not $uninstalled -and $pkg.UninstallString) {
            Write-Verbose "Falling back to raw UninstallString: $($pkg.UninstallString)"
            if ($pkg.UninstallString -match '^"([^"]+)"\s*(.*)$') {
                $exe = $Matches[1]; $args = $Matches[2]
            } elseif ($pkg.UninstallString -match '^(\S+)\s*(.*)$') {
                $exe = $Matches[1]; $args = $Matches[2]
            } else {
                $exe = $pkg.UninstallString; $args = ''
            }

            $exitCode = Invoke-UninstallProcess -FilePath $exe -Arguments $args
            if ($exitCode -in 0, 3010, 1605) { $uninstalled = $true }
        }

        if ($uninstalled) {
            if ($exitCode -eq 3010) {
                Write-Host " Removed $($pkg.Name) — reboot required to complete." -ForegroundColor Yellow
                $rebootRequired = $true
            } else {
                Write-Host " Successfully removed $($pkg.Name)." -ForegroundColor Green
            }
            $successCount++
        } else {
            Write-Warning " All uninstall strategies failed for $($pkg.Name)."
            $failCount++
        }
    }
    catch {
        Write-Warning " Unexpected error while removing $($pkg.Name): $_"
        $failCount++
    }
}

# ── 4. Verify Post-Cleanup Installations ─────────────────────────────────────
Write-Host "`nRefreshing registry to verify remaining packages..." -ForegroundColor Cyan

$remainingDotNet = Get-DotNetPackages

Write-Host "`nCurrently installed .NET packages (Post-Cleanup):" -ForegroundColor Green
if ($remainingDotNet) {
    $remainingDotNet | ForEach-Object { Write-Host " $($_.Name) [$($_.Version)]" }
} else {
    Write-Host " No targeted .NET packages remain installed." -ForegroundColor Yellow
}

# ── 5. Summary ───────────────────────────────────────────────────────────────
Write-Host "`n── Cleanup Summary ──────────────────────────────────────" -ForegroundColor Cyan
Write-Host " Removed : $successCount package(s)" -ForegroundColor Green
if ($failCount -gt 0) {
    Write-Host " Failed  : $failCount package(s)" -ForegroundColor Red
}
if ($rebootRequired) {
    Write-Host "`n *** A system reboot is required to complete removal of one or more packages. ***" -ForegroundColor Yellow
}
Write-Host "`nLog saved to: $logPath" -ForegroundColor Cyan

Stop-Transcript

exit $(if ($failCount -gt 0) { 2 } elseif ($rebootRequired) { 3010 } else { 0 })
