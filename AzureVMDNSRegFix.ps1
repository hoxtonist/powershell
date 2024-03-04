$domainName = Get-WmiObject -Namespace root\cimv2 -Class Win32_ComputerSystem | Select-Object Domain
$networkConfigStatus = Get-WmiObject Win32_NetworkAdapterConfiguration -filter "ipenabled = 'true'" | Where-Object {$_.DefaultIPGateway -ne $null}
$regdns = $false
foreach ($nic in $networkConfigStatus) {

	If (($nic.DNSDomain -ne $domainName.Domain) -or (-not $nic.FullDNSRegistrationEnabled) -or (-not $nic.DomainDNSRegistrationEnabled))
		{
			$nic.SetDNSDomain($domainName.Domain) | Out-Null
			$nic.SetDynamicDNSRegistration($true,$true)
			if ($nic.DHCPEnabled) {$regdns = $true}
		}

    }

if ($regdns)
	{
		ipconfig /renew
	}


