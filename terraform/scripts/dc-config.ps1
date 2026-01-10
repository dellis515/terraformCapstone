Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools

$securePass = ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force

Install-ADDSForest `
  -DomainName "dellis.lab" `
  -DomainNetbiosName "DELLIS" `
  -SafeModeAdministratorPassword $securePass `
  -InstallDNS `
  -Force `
  -NoRebootOnCompletion:$false

Add-DnsServerForwarder -IPAddress 8.8.8.8