Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 10.0.0.4

$pass = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force
$cred = New-Object PSCredential("labadmin", $pass)

Add-Computer -DomainName "dellis.lab" -Credential $cred -Restart -Force
