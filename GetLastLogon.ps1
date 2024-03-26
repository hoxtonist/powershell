$suffixes = @( "-suffix1", "-suffix2" )
$dclist = get-addomainController -filter 'IsReadOnly -eq $false'

$mainUserList = $null

Foreach ( $suffix in $suffixes ) {
    $mainUserList = $mainUserList + ( Get-ADUser -Filter "UserPrincipalName -like $('" *' + $suffix + '@domain.com' + '"')" -Properties LastLogon | Select SAMAccountName, @{Name='LastLogon';Expression= { [DateTime]::FromFileTime($_.LastLogon)}} )
}


Foreach ( $dc in $dclist ) {
    $selectedRecord = $null
    $dcuserlist = $null
    Foreach ( $suffix in $suffixes ) {
        $dcuserlist = $dcuserlist + ( Get-ADUser -Server $dc.Name -Filter "UserPrincipalName -like $( '" *' + $suffix + '@domain.com' + '"' )" -Properties LastLogon | Select SAMAccountName, @{ Name='LastLogon';Expression= { [DateTime]::FromFileTime( $_.LastLogon ) } } )
        }
    Foreach ( $dcuser in $dcuserlist ) {
            $selectedRecord = $mainUserList | Where-Object { $_.SAMAccountName -eq $dcuser.SAMAccountName }
            if ($dcuser.LastLogon -gt $selectedRecord.LastLogon) {
                $mainUserList = $mainUserList | Where-Object { $_.SAMAccountName -ne $selectedRecord.SAMAccountName }
                $mainUserList = $mainUserList + $dcuser
                }            
            }
    }   
