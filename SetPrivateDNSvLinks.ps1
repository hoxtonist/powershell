Set-AzContext -Subscription '<remote virtual network subscription name>'

$vnname = '<remote virtual network name>'
$vnid = (Get-AzVirtualNetwork -Name $vnname).id


Set-AzContext -Subscription '<private DNS zones subscription name>'

$zones = (Get-AzPrivateDnsZone).name

$rgn = '<private DNS zone resource group name>'

Foreach ($zone in $zones) {

$vlname = $zone + "_to_" +  $vnname

New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $rgn -ZoneName $zone -RemoteVirtualNetworkId $vnid -Name $vlname

}
