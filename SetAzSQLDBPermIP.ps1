# Permitted IP list headers - StartIP,EndIP

# DB list headers - Name,ResourceGroup

$DBList = import-csv ''

$PermIPs = import-csv ''

$RulePrefix = 'Azure_Public_Outbound_'

Connect-AzAccount

Select-AzContext -Name ''

foreach ($Db in $DBList)
{
    foreach ($Pip in $PermIPs)
    {
        if ($Pip.StartIp -eq $Pip.EndIp) {
            
            $FWRuleName = $RulePrefix + ($Pip.StartIP).Replace('.','_')
        
        }
        else {
            
            $FWRuleName = $RulePrefix  + ($Pip.StartIP).Replace('.','_') + '_to_' + ($Pip.EndIP).Replace('.','_')
        
        }
        
        # Add the rule to $Db for each IP in the IP list
        New-AzMySqlFirewallRule -Name $FWRuleName -ResourceGroupName $Db.ResourceGroup -ServerName $Db.Name -EndIPAddress $Pip.EndIP -StartIPAddress $Pip.StartIP

    }
}
