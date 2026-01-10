Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 10.0.0.4

$pass = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force
$cred = New-Object PSCredential("labadmin", $pass)

while(True){
    $output = & nltest /dsgetdc:$DomainName 2>&1

    if ($LASTEXITCODE -eq 0) {
        break
    }

    Start-Sleep -Seconds 10
}

Add-Computer -DomainName "dellis.lab" -Credential $cred -Restart -Force
