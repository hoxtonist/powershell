using module Az.Automation
using module Az.Accounts
using module Az.KeyVault
using module ActiveDirectory
using module Corp.MailReport
using module Logging_V2
using module Corp.SecretServer
using module Corp.Functions


param(
    [Parameter(Mandatory = $true)]
    [string]$ticknum,
    [Parameter(Mandatory = $true)]
    [string]$serverName
    )

function New-RetryJob {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("GetCredentials", "GetDNSRecords", "RemoveDNSRecords" )][string]$jobType,
        [Parameter(Mandatory = $false)]
        [ValidateSet("A", "PTR", "CNAME" )][string]$recordType,
        [Parameter(Mandatory = $false)][string]$objectDN = $null,
        [Parameter(Mandatory = $false)][string]$samAccountName = $null,
        [Parameter(Mandatory = $false)][int32]$retryCount = 3,
        [Parameter(Mandatory = $false)][int32]$retryDelay = 10,
        [Parameter(Mandatory = $false)][switch]$warningOnFail,
        [Parameter(Mandatory = $false)][switch]$errorOnFail
        )

    ### State Parameters ###
    [bool]$jobCompleted = $false

    for ($i = 0; $i -lt $retryCount; $i++) {
        try {
            if ($jobType -in "GetDNSRecords", "RemoveDNSRecords") {
                $cimSession = New-CimSession -Credential $script:adCred -ComputerName $script:wrDC -ErrorAction Stop
            }
            switch ($jobType) {
                "GetCredentials" {
                    Save-CorpLog -Path $logPath -Name $logName -Text "[$($jobType)][$($i+1)] Getting Default Subscription" -WriteOutput
                    $defaultSub = Get-AutomationVariable -Name 'DefaultSubscription' -ErrorAction Stop
                    Save-CorpLog -Path $logPath -Name $logName -Text "[$($jobType)][$($i+1)] Connecting to Azure using Managed Identity and default subscription: $defaultSub" -WriteOutput
                    $null = Connect-AzAccount -Identity -Subscription $defaultSub -ErrorAction Stop
                    Save-CorpLog -Path $logPath -Name $logName -Text "[$($jobType)][$($i+1)] Successfully connected to Azure" -WriteOutput
                    
                    $keyVault = Get-AutomationVariable -Name 'ITKeyVault' -ErrorAction Stop
                    $adSvcAccSecretName = Get-AutomationVariable -Name 'ITKeyVault-svc-auto-directory' -ErrorAction Stop
                    $adSvcAccSecret = (Get-AzKeyVaultSecret -VaultName $keyVault -Name $adSvcAccSecretName -ErrorAction Stop).SecretValue

                    Save-CorpLog -Path $logPath -Name $logName -Text "[$($jobType)][$($i+1)] Successfully fetched $adSvcAccount secret from KeyVault" -WriteOutput
                    $script:adCred = New-Object System.Management.Automation.PSCredential ($adSvcAccount, $adSvcAccSecret)

                    Save-CorpLog -Path $logPath -Name $logName -Text "[$($jobType)][$($i+1)] Successfully Created Credentials: | $($adCred.UserName) |" -WriteOutput

                    $jobCompleted = $true
                }
                
                "GetDNSRecords"{
                    
                    Save-CorpLog -Path $logPath -Name $logName -Text "[$($jobType)][$($i+1)] Getting $($recordType) records for: $($script:dnsFqdn)" -WriteOutput

                    switch ($recordType) {

                        "A" {
                            $script:dnsResults[$recordType] = Get-DnsServerResourceRecord -ComputerName $script:wrDC -ZoneName $script:dnsZone -Name $script:dnsFqdn -CimSession $cimSession -ErrorAction Ignore 
                            $getResults = $script:dnsResults[$recordType] | Select-Object Hostname, @{Name='Zone';Expression={$script:dnsZone}}, RecordType,Type, TimeStamp, TimetoLive, @{Name='Data';Expression={$_.RecordData.IPv4Address}}
                        }

                        "PTR" {
                            $revZones = Get-DnsServerZone -ComputerName $script:wrDC -CimSession $cimSession | Where-Object {$_.IsReverseLookupZone -and -not $_.IsAutoCreated} | Select-Object ZoneName
                            foreach ($zone in $revZones) {
                                $script:dnsResults[$recordType] += Get-DnsServerResourceRecord -ComputerName $script:wrDC -ZoneName $zone.ZoneName -Type 12 -CimSession $cimSession | Where-Object {$_.RecordData.PtrDomainName -contains $script:dnsFqdn}
                            }
                            $getResults = $script:dnsResults[$recordType] | Select-Object Hostname, @{Name='ZoneName';Expression={$zone.ZoneName}}, Recordtype, Type, TimeStamp, TimetoLive, @{Name='Data';Expression={$_.RecordData.PTRDomainName}}
                        }

                        "CNAME" {
                            $script:dnsResults[$recordType] = Get-DnsServerResourceRecord -ComputerName $script:wrDC -ZoneName $script:dnsZone -Type 5 -CimSession $cimSession | Where-Object {$_.RecordData.HostNameAlias -eq $script:dnsFqdn}
                            $getResults = $script:dnsResults[$recordType] | Select-Object Hostname, @{Name='Zone';Expression={$script:dnsZone}}, RecordType, Type, TimeStamp, TimetoLive, @{Name='Data';Expression={$_.RecordData.HostNameAlias}}
                        }
                    }
                    $outResults = $getResults | Format-Table | Out-String
                    Save-CorpLog -Path $logPath -Name $logName -Text "$($outResults)" -WriteOutput
                    $jobCompleted = $true
                }
            
                "RemoveDNSRecords" {
                    if ($null -eq $script:dnsResults[$recordType]) {
                        Save-CorpLog -Path $logPath -Name $logName -Text "[$($jobType)][$($i+1)] No $($recordType) records to remove for: $($dnsFqdn)" -WriteOutput
                        } else {
                            Save-CorpLog -Path $logPath -Name $logName -Text "[$($jobType)][$($i+1)] Deleting $($recordType) records for: $($dnsFqdn)" -WriteOutput
                            switch ($recordType) {
                                "PTR" {
                                    foreach ($ptrRec in $script:dnsResults["PTR"]) {
                                        $zoneName = ($ptrRec.DistinguishedName -split ',' | Where-Object { $_ -like 'DC=*' })[1] -replace '^DC=', ''
                                        $ptrRec | Remove-DnsServerResourceRecord -ZoneName $zoneName -ComputerName $script:wrDC -CimSession $cimSession -Force
                                    }
                                }
                                default {
                                    $script:dnsResults[$recordType] | Remove-DnsServerResourceRecord -ZoneName $script:dnsZone -ComputerName $script:wrDC -CimSession $cimSession -Force
                                }
                            }
                        }


                    $jobCompleted = $true
                }

        }
    } 
    catch {
            if ($i -lt $($retryCount - 1)) {
                    Save-CorpLog -Path $logPath -Name $logName -Text "| Attempt $($i + 1) | $($jobType) job Failed. Retry in $($retryDelay) seconds: $($_)" -WriteOutput
                    Start-Sleep -Seconds $retryDelay
                } elseif ($warningOnFail) {
                    Save-CorpLog -Path $logPath -Name $logName -Text "$jobType job Failed after $($i + 1) attempts: $_" -WriteWarning
                } elseif ($errorOnFail) {
                    Save-CorpLog -Path $logPath -Name $logName -Text "$jobType job Failed after $($i + 1) attempts: $_" -WriteError
                } else {
                    Save-CorpLog -Path $logPath -Name $logName -Text "$($jobType) job Failed after $($i + 1) attempts causing runbook termination: $($_)" -throwException
                }
            }
    finally {
        Get-CimSession | Remove-CimSession -ErrorAction SilentlyContinue
    }        
        if ($jobCompleted) { break }
        
    }
}

# Configuration Parameters
[string]$adSvcAccount = "service-account-name"
[int32]$dcFetchRetryCount = 10
[int32]$dcFetchDelay = 2

# References
[string]$domainDN = $null
[pscredential]$adCred = $null
[string]$script:wrDC = $null
[string]$script:repDC = $null
$script:dnsZone = Get-AutomationVariable -Name "DomainFQDN"
$script:dnsFqdn = $serverName + "." + $script:dnsZone + "."
$script:dnsResults = @{}

# Create Log File
try {
    [string]$logPath = "C:\Workflows\Integrations_Server-Decomm-Remove-Internal-DNS"
    $logName = $ticknum.ToLower()
    Save-CorpLog -Path $logPath -Name $logName -Text "Log file created for $($ticknum.ToUpper()). Starting Runbook" -WriteOutput
} catch {
    throw "Failed to create log file: $($_)"
    }

# Validate input RITM and hostname

if ( -not ($ticknum -match '^(?i)ticknum\d{7}$' )) {
            Save-CorpLog -Path $logPath -Name $logName -Text "Invalid RITM number format" -WriteOutput -throwException
        }

if ( -not ($serverName-match '^(?=.{1,63}$)(?:(?!-)[A-Za-z0-9-]{1,63}(?<!-))$' )) {
            Save-CorpLog -Path $logPath -Name $logName -Text "Invalid hostname format" -WriteOutput -throwException
        }

# Retrieve DC
    try {
        $dcArray = Get-CorpDomainControllers
        $script:wrDC = $dcArray[0]
        $script:repDC = $dcArray[1]
        Save-CorpLog -Path $logPath -Name $logName -Text "Using Writeable DC: $($script:wrDC)" -WriteOutput
        Save-CorpLog -Path $logPath -Name $logName -Text "Using Replication Check DC: $($script:repDC)" -WriteOutput
    }
    catch {
        Save-CorpLog -Path $logPath -Name $logName -Text "Error Retrieving DCs: $($_)" -throwException
    }
    

# Collect and display records

New-RetryJob -jobType "GetCredentials" -WarningOnFail
New-RetryJob -jobType "GetDNSRecords" -recordType 'A' -WarningOnFail
New-RetryJob -jobType "GetDNSRecords" -recordType 'PTR' -WarningOnFail
New-RetryJob -jobType "GetDNSRecords" -recordType 'CNAME' -WarningOnFail


If ($script:dnsResults["A"].Count + $script:dnsResults["PTR"].Count + $script:dnsResults["CNAME"].Count -gt 20 ){
    Save-CorpLog -Path $logPath -Name $logName -Text "More than 20 records returned" -throwException
}

# Delete collected records

New-RetryJob -jobType "RemoveDNSRecords" -recordType 'CNAME' -WarningOnFail
New-RetryJob -jobType "RemoveDNSRecords" -recordType 'PTR' -WarningOnFail
New-RetryJob -jobType "RemoveDNSRecords" -recordType 'A' -WarningOnFail

# Verify no records are left

if ($script:dnsResults["A"] -or $script:dnsResults["PTR"] -or $script:dnsResults["CNAME"]) {
    $script:dnsResults = @{}
    New-RetryJob -jobType "GetDNSRecords" -recordType 'A' -WarningOnFail
    New-RetryJob -jobType "GetDNSRecords" -recordType 'PTR' -WarningOnFail
    New-RetryJob -jobType "GetDNSRecords" -recordType 'CNAME' -WarningOnFail
}

Save-CorpLog -Path $logPath -Name $logName -Text "Runboook Completed Successfully" -WriteOutput -uploadBlob
exit 0