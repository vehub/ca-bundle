@echo off
REM Batch script to connect to an SSL service and extract its certificates
REM Creates a certificate bundle for use with curl and other SSL/TLS clients

setlocal enabledelayedexpansion

if "%1"=="" goto usage
if "%1"=="-h" goto usage
if "%1"=="--help" goto usage

REM Check if OpenSSL is available
where openssl >nul 2>&1
if errorlevel 1 (
    echo ERROR: OpenSSL not found in PATH. Please install OpenSSL first.
    echo You can install it via Chocolatey: choco install openssl
    exit /b 1
)

REM Parse the target argument
set "target=%1"
set "server="
set "port=443"
set "starttls_option="

REM Check if target contains ://
echo !target! | findstr "://" >nul
if not errorlevel 1 (
    REM Extract server from URL
    for /f "tokens=2 delims=/" %%a in ("!target!") do (
        set "server=%%a"
    )
    REM Extract protocol for port
    for /f "tokens=1 delims=:" %%a in ("!target!") do (
        set "protocol=%%a"
    )
    if "!protocol!"=="https" set "port=443"
    if "!protocol!"=="smtp" (
        set "port=25"
        set "starttls_option=-starttls smtp"
    )
    if "!protocol!"=="pop3" (
        set "port=110"
        set "starttls_option=-starttls pop3"
    )
    if "!protocol!"=="imap" (
        set "port=143"
        set "starttls_option=-starttls imap"
    )
) else (
    REM Check if target contains :
    echo !target! | findstr ":" >nul
    if not errorlevel 1 (
        REM Split server:port
        for /f "tokens=1 delims=:" %%a in ("!target!") do set "server=%%a"
        for /f "tokens=2 delims=:" %%a in ("!target!") do set "port=%%a"
        
        REM Check for starttls protocols
        if "!port!"=="smtp" set "starttls_option=-starttls smtp"
        if "!port!"=="pop3" set "starttls_option=-starttls pop3"
        if "!port!"=="imap" set "starttls_option=-starttls imap"
        if "!port!"=="ftp" set "starttls_option=-starttls ftp"
        if "!port!"=="xmpp" set "starttls_option=-starttls xmpp"
        if "!port!"=="pop" (
            set "port=pop3"
            set "starttls_option=-starttls pop3"
        )
        if "!port!"=="imap3" set "starttls_option=-starttls imap"
    ) else (
        REM Just server name, use default port 443
        set "server=!target!"
        set "port=443"
    )
)

echo Connecting to !server!:!port!...

REM Create temporary file for OpenSSL output
set "temp_file=%temp%\sslcerts_%random%.tmp"

REM Connect and get certificates
openssl s_client -showcerts -connect "!server!:!port!" !starttls_option! %2 %3 %4 %5 %6 %7 %8 %9 < nul > "!temp_file!" 2>nul
if errorlevel 1 (
    echo Connection failed
    if exist "!temp_file!" del "!temp_file!"
    exit /b 1
)

echo.

REM Initialize variables
set "bundle_file=!server!_bundle.pem"
set "cert_count=0"
set "in_cert_chain=0"
set "in_cert=0"
set "current_cert="
set "cert_name="

REM Create temporary files for processing
set "bundle_temp=%temp%\bundle_%random%.tmp"
set "cert_temp=%temp%\cert_%random%.tmp"

REM Process the OpenSSL output
for /f "usebackq delims=" %%a in ("!temp_file!") do (
    set "line=%%a"
    
    REM Check for certificate chain start
    echo !line! | findstr /c:"Certificate chain" >nul
    if not errorlevel 1 (
        set "in_cert_chain=1"
        goto continue
    )
    
    if "!in_cert_chain!"=="1" (
        REM Check for certificate start
        echo !line! | findstr /c:"-----BEGIN CERTIFICATE-----" >nul
        if not errorlevel 1 (
            set "in_cert=1"
            echo !line! >> "!cert_temp!"
            goto continue
        )
        
        REM Check for certificate end
        echo !line! | findstr /c:"-----END CERTIFICATE-----" >nul
        if not errorlevel 1 (
            echo !line! >> "!cert_temp!"
            set /a cert_count+=1
            
            REM Append cert to bundle
            type "!cert_temp!" >> "!bundle_temp!"
            echo. >> "!bundle_temp!"
            
            REM Save individual certificate
            if "!cert_name!"=="" (
                echo Saving individual cert: cert_!cert_count!.crt
                copy "!cert_temp!" "cert_!cert_count!.crt" >nul
            ) else (
                set "clean_name=!cert_name: =_!"
                set "clean_name=!clean_name:/=_!"
                set "clean_name=!clean_name:\=_!"
                set "clean_name=!clean_name::=_!"
                echo Saving individual cert: !clean_name!.crt
                copy "!cert_temp!" "!clean_name!.crt" >nul
            )
            
            REM Reset for next certificate
            del "!cert_temp!" 2>nul
            set "in_cert=0"
            set "cert_name="
            goto continue
        )
        
        REM Check for subject line
        echo !line! | findstr /r "^ *[0-9]* s:" >nul
        if not errorlevel 1 (
            for /f "tokens=2*" %%b in ("!line!") do (
                set "subject=%%c"
                REM Extract CN from subject
                echo !subject! | findstr "CN=" >nul
                if not errorlevel 1 (
                    for /f "tokens=2 delims==" %%d in ("!subject!") do (
                        for /f "tokens=1 delims=/" %%e in ("%%d") do (
                            set "cert_name=%%e"
                        )
                    )
                )
            )
            goto continue
        )
        
        REM Check for end of certificates
        echo !line! | findstr /c:"---" >nul
        if not errorlevel 1 (
            goto done_parsing
        )
        
        REM If we're in a certificate, add the line
        if "!in_cert!"=="1" (
            echo !line! >> "!cert_temp!"
        )
    )
    
    :continue
)

:done_parsing

REM Clean up temporary files
if exist "!temp_file!" del "!temp_file!"
if exist "!cert_temp!" del "!cert_temp!"

REM Create the final bundle file
if exist "!bundle_temp!" (
    echo.
    echo Creating certificate bundle: !bundle_file!
    echo Bundle contains !cert_count! certificate(s)
    copy "!bundle_temp!" "!bundle_file!" >nul
    del "!bundle_temp!"
    
    echo.
    echo Usage with curl:
    echo   curl --cacert !bundle_file! https://!server!/
    echo   curl --capath . https://!server!/
    echo.
    echo Usage with environment variables:
    echo   set SSL_CERT_FILE=%CD%\!bundle_file!
    echo   set REQUESTS_CA_BUNDLE=%CD%\!bundle_file!
) else (
    echo No certificates found to create bundle
    exit /b 1
)

goto end

:usage
echo Usage:
echo   %~n0 server[:port] [other s_client flags]
echo   %~n0 protocol://server [other s_client flags]
echo.
echo Creates a certificate bundle file (server_bundle.pem) containing all certificates
echo in the chain that can be used with curl, wget, and other SSL/TLS clients.
echo.
echo Examples:
echo   %~n0 example.com
echo   %~n0 example.com:443
echo   %~n0 https://example.com
echo.
echo Requirements:
echo   - OpenSSL must be installed and available in PATH
echo   - You can install OpenSSL via: choco install openssl
exit /b 1

:end