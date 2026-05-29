# ==============================================================================
# CONFIGURATION, ENVIRONMENT SETTING & GLOBAL VARIABLES
# ==============================================================================
$ScriptFolder = "C:\ProgramData\<company>\Scripts"
$TaskPath     = "\<company>\"
$EventSource  = "<company>"

# Target Script 1 Config (Pre-Maintenance Reboot)
$ScriptPathReboot = "$ScriptFolder\PreMaintenanceReboot.ps1"
$TaskNameReboot   = "Pre-maintenance Reboot"

# Target Script 2 Config (Start Maintenance Window / Keep Awake)
$ScriptPathAwake  = "$ScriptFolder\StartMaintWindow.ps1"
$TaskNameAwake    = "Start Maintenance Window"

Write-Host "Setting up secure environment..." -ForegroundColor Cyan

# 1. Register Custom Event Log Source
if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    New-EventLog -LogName System -Source $EventSource
    Write-Host "Registered Event Source '$EventSource' inside the System log." -ForegroundColor Green
} else {
    Write-Host "Event Source '$EventSource' already registered." -ForegroundColor Yellow
}

# 2. Establish Secure Script Directory Structure
if (-not (Test-Path -Path $ScriptFolder)) {
    New-Item -ItemType Directory -Path $ScriptFolder -Force | Out-Null
    Write-Host "Created directory: $ScriptFolder" -ForegroundColor Green
}

# 3. Apply Strict NTFS Access Control (SYSTEM & Administrators Only)
$Acl = Get-Acl -Path $ScriptFolder
$Acl.SetAccessRuleProtection($true, $false) # Disable inheritance, remove default users

$ArSystem = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")
$ArAdmins = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "ContainerInherit, ObjectInherit", "None", "Allow")

$Acl.SetAccessRule($ArSystem)
$Acl.SetAccessRule($ArAdmins)
Set-Acl -Path $ScriptFolder -AclObject $Acl
Write-Host "Strict NTFS permissions applied to folder structure." -ForegroundColor Green


# ==============================================================================
# GENERATE ARTIFACT 1: PRE-MAINTENANCE REBOOT SCRIPT
# ==============================================================================
Write-Host "Generating: $ScriptPathReboot..." -ForegroundColor Cyan

$RebootScriptContent = @'
$Now = Get-Date

# Calculate Maintenance Window (Saturday after 2nd Tuesday)
$FirstOfMonth = Get-Date -Year $Now.Year -Month $Now.Month -Day 1
$TuesdayCount = 0
$DayOffset = 0
while ($TuesdayCount -lt 2) {
    $CurrentDay = $FirstOfMonth.AddDays($DayOffset)
    if ($CurrentDay.DayOfWeek -eq 'Tuesday') {
        $TuesdayCount++
        if ($TuesdayCount -eq 2) { $SecondTuesday = $CurrentDay }
    }
    $DayOffset++
}

$DaysToSaturday = ([int][DayOfWeek]::Saturday - [int]$SecondTuesday.DayOfWeek + 7) % 7
if ($DaysToSaturday -eq 0) { $DaysToSaturday = 7 }
$MaintSaturday = $SecondTuesday.AddDays($DaysToSaturday)

# Window boundaries: Saturday 22:00 to Sunday 04:00
$WindowStart = Get-Date -Year $MaintSaturday.Year -Month $MaintSaturday.Month -Day $MaintSaturday.Day -Hour 22 -Minute 0 -Second 0
$WindowEnd = $WindowStart.AddHours(6)

# -------- Test Option ----------------------------------------
# $WindowStart = $Now.AddHours(-1)
# $WindowEnd = $Now.AddHours(1)
# -------------------------------------------------------------

# Operational Metrics Evaluation
$InTimeWindow   = ($Now -ge $WindowStart -and $Now -le $WindowEnd)
$LastBoot       = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
$NoRecentReboot = (($Now - $LastBoot).TotalHours -ge 24)

if (-not $InTimeWindow) {
    $Msg = "The system session woke up outside of the scheduled maintenance window. Current Time: $Now. Maintenance Window: $WindowStart to $WindowEnd. No action taken."
    Write-EventLog -LogName System -Source "UoW" -EventId 1 -EntryType Information -Message $Msg
    Write-Output "Outside maintenance window. Event ID 1 logged."
}
elseif ($NoRecentReboot -and $InTimeWindow) {
    $Msg = "The system session woke up inside the maintenance window and has not been rebooted within the last 24 hours. Uptime validation passed. Initiating maintenance reboot now."
    Write-EventLog -LogName System -Source "UoW" -EventId 2 -EntryType Information -Message $Msg
    Write-Output "Conditions met. Event ID 2 logged. Executing computer restart..."
    Restart-Computer -Force
}
elseif ($InTimeWindow -and -not $NoRecentReboot) {
    $Msg = "The system session woke up inside the maintenance window, but has been rebooted within the last 24 hours. Last boot time: $LastBoot . No action taken."
    Write-EventLog -LogName System -Source "UoW" -EventId 3 -EntryType Information -Message $Msg
    Write-Output "Inside maintenance window, but device already rebooted within 24 hours. Skipping."
}
else {
    $Msg = "The script encountered an unhandled or anomalous logical state. Current Time: $($Now). InWindow: $InTimeWindow. NoRecentReboot: $NoRecentReboot. LastBoot: $LastBoot."
    Write-EventLog -LogName System -Source "UoW" -EventId 9 -EntryType Warning -Message $Msg
    Write-Error "An anomalous script evaluation occurred. Event ID 9 logged."
}
'@

Set-Content -Path $ScriptPathReboot -Value $RebootScriptContent -Force


# ==============================================================================
# GENERATE ARTIFACT 2: START MAINTENANCE WINDOW (KEEP AWAKE) SCRIPT
# ==============================================================================
Write-Host "Generating: $ScriptPathAwake..." -ForegroundColor Cyan

$AwakeScriptContent = @'
$Now = Get-Date

# Calculate Maintenance Window (Saturday after 2nd Tuesday)
$FirstOfMonth = Get-Date -Year $Now.Year -Month $Now.Month -Day 1
$TuesdayCount = 0
$DayOffset = 0
while ($TuesdayCount -lt 2) {
    $CurrentDay = $FirstOfMonth.AddDays($DayOffset)
    if ($CurrentDay.DayOfWeek -eq 'Tuesday') {
        $TuesdayCount++
        if ($TuesdayCount -eq 2) { $SecondTuesday = $CurrentDay }
    }
    $DayOffset++
}

$DaysToSaturday = ([int][DayOfWeek]::Saturday - [int]$SecondTuesday.DayOfWeek + 7) % 7
if ($DaysToSaturday -eq 0) { $DaysToSaturday = 7 }
$MaintSaturday = $SecondTuesday.AddDays($DaysToSaturday)

# Window boundaries: Saturday 22:00 to Sunday 04:00
$WindowStart = Get-Date -Year $MaintSaturday.Year -Month $MaintSaturday.Month -Day $MaintSaturday.Day -Hour 22 -Minute 0 -Second 0
$WindowEnd = $WindowStart.AddHours(6)

# -------- Test Option ----------------------------------------
$WindowStart = $Now.AddHours(-1)
$WindowEnd = $Now.AddHours(1)
# -------------------------------------------------------------

$InTimeWindow = ($Now -ge $WindowStart -and $Now -le $WindowEnd)

if (-not $InTimeWindow) {
    $Msg = "The system booted or woke up outside of the scheduled maintenance window. Current Time: $Now. Maintenance Window: $WindowStart to $WindowEnd. Sleep inhibition bypassed."
    Write-EventLog -LogName System -Source "UoW" -EventId 10 -EntryType Information -Message $Msg
    Write-Output "Outside maintenance window. Exiting."
    Exit
}

# Inside Window: Initialize Kernel API Sleep Block Execution
$Msg = "System booted or woke up inside the maintenance window ($WindowStart to $WindowEnd). Initiating 6-hour CPU keep-awake block with Away Mode enabled."
Write-EventLog -LogName System -Source "UoW" -EventId 11 -EntryType Information -Message $Msg
Write-Output "Inside maintenance window. Inhibiting thread/system sleep states..."

$AwakeCode = @"
using System;
using System.Runtime.InteropServices;

public class WinKernelAPI {
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);

    public const uint ES_CONTINUOUS = 0x80000000;
    public const uint ES_SYSTEM_REQUIRED = 0x00000001;
    public const uint ES_AWAYMODE_REQUIRED = 0x00000040;
}
"@

Add-Type -TypeDefinition $AwakeCode

# Combine Flags: Continuous + System Required + Away Mode (0x80000000 | 0x00000001 | 0x00000040 = 0x80000041)
$Flags = [WinKernelAPI]::ES_CONTINUOUS -bor [WinKernelAPI]::ES_SYSTEM_REQUIRED -bor [WinKernelAPI]::ES_AWAYMODE_REQUIRED
[WinKernelAPI]::SetThreadExecutionState($Flags)

# Keep thread active for 6 hours (21600 seconds)
Start-Sleep -Seconds 21600

# Release explicit lock, restore standard OS power behavior
[WinKernelAPI]::SetThreadExecutionState([WinKernelAPI]::ES_CONTINUOUS)

$EndMsg = "The 6-hour maintenance awake cycle has finished. Releasing Away Mode and sleep inhibition."
Write-EventLog -LogName System -Source "UoW" -EventId 12 -EntryType Information -Message $EndMsg
Write-Output "Inhibition released."
'@

Set-Content -Path $ScriptPathAwake -Value $AwakeScriptContent -Force


# ==============================================================================
# DEPLOY TASK 1: PRE-MAINTENANCE REBOOT TASK (EVENT TRIGGERED)
# ==============================================================================
Write-Host "Registering task '$TaskNameReboot'..." -ForegroundColor Cyan

$TaskXmlReboot = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Kernel-General'] and (EventID=1)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowStartOnDemand>false</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$ScriptPathReboot"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $TaskNameReboot -TaskPath $TaskPath -Xml $TaskXmlReboot -Force


# ==============================================================================
# DEPLOY TASK 2: START MAINTENANCE WINDOW TASK (BOOT & RESUME TRIGGERED)
# ==============================================================================
Write-Host "Registering task '$TaskNameAwake'..." -ForegroundColor Cyan

$TaskXmlAwake = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
    </BootTrigger>
    
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowStartOnDemand>false</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT7H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$ScriptPathAwake"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

Register-ScheduledTask -TaskName $TaskNameAwake -TaskPath $TaskPath -Xml $TaskXmlAwake -Force

Write-Host "Success! Unified environment configurations and automated tasks are successfully deployed." -ForegroundColor Green
