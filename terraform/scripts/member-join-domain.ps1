Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 10.0.0.4

$pass = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force
$cred = New-Object PSCredential("DELLIS\\Administrator", $pass)

Add-Computer -DomainName "dellis.lab" -Credential $cred -Restart -Force
