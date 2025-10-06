# PowerShell script to connect to an SSL service and extract its certificates
# Creates a certificate bundle for use with curl and other SSL/TLS clients

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Target,
    
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$OpenSSLOptions = @()
)

function Show-Usage {
    $scriptName = Split-Path $MyInvocation.ScriptName -Leaf
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  $scriptName server[:port] [other s_client flags]" -ForegroundColor White
    Write-Host "  $scriptName protocol://server [other s_client flags]" -ForegroundColor White
    Write-Host ""
    Write-Host "Creates a certificate bundle file (server_bundle.pem) containing all certificates" -ForegroundColor Gray
    Write-Host "in the chain that can be used with curl, wget, and other SSL/TLS clients." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Examples:" -ForegroundColor Yellow
    Write-Host "  $scriptName example.com" -ForegroundColor White
    Write-Host "  $scriptName example.com:443" -ForegroundColor White
    Write-Host "  $scriptName https://example.com" -ForegroundColor White
    Write-Host ""
    Write-Host "Requirements:" -ForegroundColor Yellow
    Write-Host "  - OpenSSL must be installed and available in PATH" -ForegroundColor Gray
    Write-Host "  - You can install OpenSSL via: choco install openssl" -ForegroundColor Gray
    exit 1
}

# Check if OpenSSL is available
try {
    $null = Get-Command openssl -ErrorAction Stop
} catch {
    Write-Error "OpenSSL not found in PATH. Please install OpenSSL first."
    Write-Host "You can install it via Chocolatey: choco install openssl" -ForegroundColor Yellow
    exit 1
}

# Parse command-line arguments
$opensslArgs = @()

if ($Target -match "://") {
    # proto://domain format
    $uri = [Uri]$Target
    $server = $uri.Host
    $port = if ($uri.Port -ne -1) { $uri.Port } else { $uri.Scheme }
} elseif ($Target -match ":") {
    # Explicit port number supplied
    $parts = $Target.Split(":")
    $server = $parts[0]
    $port = $parts[1]
} else {
    # No port number specified; default to 443 (https)
    $server = $Target
    $port = 443
}

# If the protocol/port specified is a non-SSL service that s_client supports starttls for, enable that
$starttlsProtocols = @("smtp", "pop3", "imap", "ftp", "xmpp")
if ($port -in $starttlsProtocols) {
    $opensslArgs += "-starttls", $port
} elseif ($port -eq "imap3") {
    $opensslArgs += "-starttls", "imap"
} elseif ($port -eq "pop") {
    $port = "pop3"
    $opensslArgs += "-starttls", "pop3"
}

# Add any additional OpenSSL options
$opensslArgs += $OpenSSLOptions

Write-Host "Connecting to $server`:$port..." -ForegroundColor Green

# Try to connect and collect certs
try {
    $connectOutput = & openssl s_client -showcerts -connect "$server`:$port" $opensslArgs 2>$null | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "OpenSSL connection failed with exit code $LASTEXITCODE"
    }
} catch {
    Write-Error "Connection failed: $_"
    exit 1
}

Write-Host ""

# Initialize variables for certificate bundle
$bundleFile = "${server}_bundle.pem"
$bundleContent = @()
$certCount = 0

$state = "begin"
$currentCert = @()
$certName = ""

# Process the OpenSSL output line by line
$lines = $connectOutput -split "`r?`n"

foreach ($line in $lines) {
    switch ("$state;$line") {
        { $_ -match "^begin;Certificate chain" } {
            # First certificate is about to begin!
            $state = "reading"
            $currentCert = @()
            $certName = ""
            break
        }
        
        { $_ -match "^reading;-----END CERTIFICATE-----" } {
            # Last line of a cert; save it and get ready for the next
            $currentCert += $line
            
            # Add this certificate to the bundle
            $bundleContent += $currentCert
            $bundleContent += ""  # Add blank line between certificates
            $certCount++

            # Pick a name to save the individual cert under (optional)
            if ($certName -match "/CN=([^/]+)") {
                $certFile = ($matches[1] -replace "[^\w\-\.]", "_") + ".crt"
            } elseif ($certName -and $certName -ne "/") {
                $certFile = ($certName.TrimStart("/") -replace "[/\\:]", "_" -replace "\s", "_") + ".crt"
            } else {
                Write-Host "Certificate #$certCount (no name found)" -ForegroundColor Yellow
                $certFile = "cert_$certCount.crt"
            }

            # Save individual cert (optional)
            if (Test-Path $certFile) {
                Write-Host "Individual cert already exists: $certFile" -ForegroundColor Yellow
            } else {
                Write-Host "Saving individual cert: $certFile" -ForegroundColor Green
                $currentCert -join "`n" | Out-File -FilePath $certFile -Encoding ASCII
            }

            $state = "reading"
            $currentCert = @()
            $certName = ""
            break
        }
        
        { $_ -match "^reading;\s*\d+\s+s:(.+)" } {
            # This is the cert subject summary from openssl
            $certName = $matches[1]
            # Don't include subject/issuer info in the actual certificate data
            break
        }
        
        { $_ -match "^reading;\s*\d+\s+i:(.+)" } {
            # This is the cert issuer summary from openssl
            # Don't include subject/issuer info in the actual certificate data
            break
        }
        
        { $_ -match "^reading;---" } {
            # That's the end of the certs...
            $state = "done"
            break
        }
        
        { $_ -match "^reading;" } {
            $certLine = $line.Substring(8)  # Remove "reading;" prefix
            # Only include actual certificate data (PEM format)
            if ($certLine -match "^-----BEGIN CERTIFICATE-----$" -or 
                $certLine -match "^-----END CERTIFICATE-----$" -or 
                $certLine -match "^[A-Za-z0-9+/=]+$") {
                $currentCert += $certLine
            }
            break
        }
    }
    
    if ($state -eq "done") { break }
}

# Save the certificate bundle
if ($bundleContent.Count -gt 0) {
    Write-Host ""
    Write-Host "Creating certificate bundle: $bundleFile" -ForegroundColor Green
    Write-Host "Bundle contains $certCount certificate(s)" -ForegroundColor Green
    
    # Remove the trailing empty line
    if ($bundleContent[-1] -eq "") {
        $bundleContent = $bundleContent[0..($bundleContent.Count-2)]
    }
    
    $bundleContent -join "`n" | Out-File -FilePath $bundleFile -Encoding ASCII
    
    Write-Host ""
    Write-Host "Usage with curl:" -ForegroundColor Yellow
    Write-Host "  curl --cacert $bundleFile https://$server/" -ForegroundColor White
    Write-Host "  curl --capath . https://$server/" -ForegroundColor White
    Write-Host ""
    Write-Host "Usage with PowerShell:" -ForegroundColor Yellow
    Write-Host "  `$env:SSL_CERT_FILE = `"`$PWD\$bundleFile`"" -ForegroundColor White
    Write-Host "  `$env:REQUESTS_CA_BUNDLE = `"`$PWD\$bundleFile`"" -ForegroundColor White
    Write-Host ""
    Write-Host "Usage with Python requests:" -ForegroundColor Yellow
    Write-Host "  import requests" -ForegroundColor White
    Write-Host "  requests.get('https://$server/', verify=r'$bundleFile')" -ForegroundColor White
} else {
    Write-Error "No certificates found to create bundle"
    exit 1
}