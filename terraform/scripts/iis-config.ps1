Install-WindowsFeature Web-Server -IncludeManagementTools

New-Item C:\inetpub\wwwroot\index.html -Force -Value "<h1>IIS AD Lab Server</h1>"
