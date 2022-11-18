$cred = Get-Credential



$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($cred.Password)
$pass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
$db = $null
$report = 'C:\scripts\AzureSQLDBUsers\AzureSQLDBUsers-' + $(((get-date).ToUniversalTime()).ToString("yyyyMMddTHHmmssZ")) + '.txt'


$SQLQuery=@'
SELECT name as username,
type_desc as type,
authentication_type_desc as authentication_type
from sys.database_principals
where type not in ('A', 'G', 'R', 'X')
and sid is not null
and name != 'guest'
and name != 'dbo'
order by username;
'@


Connect-AzAccount -Credential $cred | Out-Null

$Subs = Get-AzSubscription

New-Item $report


Foreach ($SubID in $Subs.Id){

    Select-AZSubscription $SubID | Out-Null
    $AzSubName = (Get-AzSubscription -subscriptionid $SubID).Name
 
    Foreach ($sqls in Get-AzSqlServer) {

        Foreach ($db in Get-AzSqlDatabase -ServerName $sqls.ServerName -ResourceGroupName $sqls.ResourceGroupName){
    
            
            $db | Select-Object DatabaseName, ServerName, ResourceGroupName, @{n="Subscription";e={$AzSubName}} | Format-Table >> $report
            
            $conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:" + $db.ServerName + ".database.windows.net,1433;Initial Catalog=" + $db.DatabaseName + ";`
            Persist Security Info=False;Authentication=Active Directory Password;User ID=" + $cred.Username + " ;Password=" + $pass + ";MultipleActiveResultSets=False;`
            Encrypt=False;TrustServerCertificate=True;Connection Timeout=10;")
            
            $conn.Open()

            $cmd = New-Object System.Data.SqlClient.SqlCommand($SQLQuery, $conn)

            $dataset = New-Object System.Data.DataSet
            $dataadapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)

            [void]$dataadapter.fill($dataset)


            Write-Output $dataset.Tables | Format-Table >> $report
            
            $conn.Close()
            
            }

                    
            }

    }