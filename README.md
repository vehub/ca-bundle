# SSL Certificate Extractor

Scripts to connect to an SSL service and extract its certificates, creating a certificate bundle that can be used with curl and other SSL/TLS clients.

## Usage

### Linux/macOS (Bash)
```bash
./sslcerts.sh example.com:443
./sslcerts.sh https://github.com
./sslcerts.sh smtp.gmail.com:587
```

### Windows (PowerShell)
```powershell
.\sslcerts.ps1 example.com:443
.\sslcerts.ps1 https://github.com
.\sslcerts.ps1 smtp.gmail.com:587
```

### Windows (Batch)
```cmd
sslcerts.bat example.com:443
sslcerts.bat https://github.com
sslcerts.bat smtp.gmail.com:587
```

## Requirements

- **OpenSSL** must be installed and available in PATH
  - Linux: `sudo apt-get install openssl` or `yum install openssl`
  - macOS: `brew install openssl` (usually pre-installed)
  - Windows: `choco install openssl` or download from [OpenSSL website](https://www.openssl.org/source/)

## Output

Each script creates:
1. **Certificate Bundle**: `{server}_bundle.pem` - Single file containing all certificates in the chain
2. **Individual Certificates**: `{cert_name}.crt` - Separate files for each certificate

## Using the Certificate Bundle

### With curl
```bash
curl --cacert server_bundle.pem https://server/
curl --capath . https://server/
```

### With environment variables
```bash
# Linux/macOS
export SSL_CERT_FILE=$PWD/server_bundle.pem
export REQUESTS_CA_BUNDLE=$PWD/server_bundle.pem

# Windows
set SSL_CERT_FILE=%CD%\server_bundle.pem
set REQUESTS_CA_BUNDLE=%CD%\server_bundle.pem
```

### With Python requests
```python
import requests
requests.get('https://server/', verify='server_bundle.pem')
```

## Supported Protocols

The scripts automatically detect and handle STARTTLS for:
- SMTP (port 25, 587)
- POP3 (port 110)
- IMAP (port 143)
- FTP (port 21)
- XMPP
