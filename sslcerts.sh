#!/bin/bash

# Connect to an SSL service and extract its certificates to files in the
# current directory.

usage() {
    echo "Usage:" >&2
    echo "  $(basename "$0") server[:port] [other s_client flags]" >&2
    echo "  $(basename "$0") protocol://server [other s_client flags]" >&2
    echo >&2
    echo "Creates a certificate bundle file (server_bundle.pem) containing all certificates" >&2
    echo "in the chain that can be used with curl, wget, and other SSL/TLS clients." >&2
    echo >&2
    echo "Examples:" >&2
    echo "  $(basename "$0") example.com" >&2
    echo "  $(basename "$0") example.com:443" >&2
    echo "  $(basename "$0") https://example.com" >&2
    exit 1
}


# Parse command-line arguments
openssl_options=()
if (( $# < 1 )); then    # No server address specified
    usage

elif [[ "$1" = *://* ]]; then   # proto://domain format
    port="${1%%://*}" # Just use the protocol name as the port; let openssl look it up
    server="${1#*://}"
    server="${server%%/*}"

elif [[ "$1" = *:* ]]; then    # Explicit port number supplied
    port="${1#*:}"
    server="${1%:*}"

else # No port number specified; default to 443 (https)
    server="$1"
    port=443
fi

# If the protocol/port specified is a non-SSL service that s_client supports starttls for, enable that
if [[ "$port" = "smtp" || "$port" = "pop3" || "$port" = "imap" || "$port" = "ftp" || "$port" = "xmpp" ]]; then
    openssl_options+=(-starttls "$port")
elif [[ "$port" = "imap3" ]]; then
    openssl_options+=(-starttls imap)
elif [[ "$port" = "pop" ]]; then
    port=pop3
    openssl_options+=(-starttls pop3)
fi


# Any leftover command-line arguments get passed to openssl s_client
shift
openssl_options+=("$@")

# Try to connect and collect certs
connect_output=$(openssl s_client -showcerts -connect "$server:$port" "${openssl_options[@]}" </dev/null) || {
    status=$?
    echo "Connection failed; exiting" >&2
    exit $status
}
echo

nl=$'\n'

# Initialize variables for certificate bundle
bundle_file="${server}_bundle.pem"
bundle_content=""
cert_count=0

state=begin
while IFS= read -r line <&3; do
    case "$state;$line" in
      "begin;Certificate chain" )
        # First certificate is about to begin!
        state=reading
        current_cert=""
        certname=""
        ;;

      "reading;-----END CERTIFICATE-----" )
        # Last line of a cert; save it and get ready for the next
        current_cert+="${current_cert:+$nl}$line"
        
        # Add this certificate to the bundle
        bundle_content+="${bundle_content:+$nl}$current_cert$nl"
        ((cert_count++))

        # Pick a name to save the individual cert under (optional)
        if [[ "$certname" = */CN=* ]]; then
            certfile="${certname#*/CN=}"
            certfile="${certfile%%/*}"
            certfile="${certfile// /_}.crt"
        elif [[ -n "$certname" && "$certname" != "/" ]]; then
            certfile="${certname#/}"
            certfile="${certfile//\//:}"
            certfile="${certfile// /_}.crt"
        else
            echo "Certificate #$cert_count (no name found)"
            certfile="cert_${cert_count}.crt"
        fi

        # Save individual cert (optional)
        if [[ -e "$certfile" ]]; then
            echo "Individual cert already exists: $certfile" >&2
        else
            echo "Saving individual cert: $certfile"
            echo "$current_cert" >"$certfile"
        fi

        state=reading
        current_cert=""
        certname=""
        ;;

      "reading; "*" s:"* )
        # This is the cert subject summary from openssl
        certname="${line#*:}"
        # Don't include subject/issuer info in the actual certificate data
        ;;

       "reading; "*" i:"* )
        # This is the cert issuer summary from openssl
        # Don't include subject/issuer info in the actual certificate data
        ;;

      "reading;---" )
        # That's the end of the certs...
        break
        ;;

      "reading;"* )
        # Only include actual certificate data (PEM format)
        if [[ "$line" =~ ^-----BEGIN\ CERTIFICATE----- ]] || [[ "$line" =~ ^-----END\ CERTIFICATE----- ]] || [[ "$line" =~ ^[A-Za-z0-9+/=]+$ ]]; then
            current_cert+="${current_cert:+$nl}$line"
        fi
        ;;
    esac
done 3<<< "$connect_output"

# Save the certificate bundle
if [[ -n "$bundle_content" ]]; then
    echo
    echo "Creating certificate bundle: $bundle_file"
    echo "Bundle contains $cert_count certificate(s)"
    echo "$bundle_content" > "$bundle_file"
    echo
    echo "Usage with curl:"
    echo "  curl --cacert $bundle_file https://$server/"
    echo "  curl --capath . https://$server/"
    echo
    echo "Usage with other tools:"
    echo "  export SSL_CERT_FILE=\$PWD/$bundle_file"
    echo "  export REQUESTS_CA_BUNDLE=\$PWD/$bundle_file"
else
    echo "No certificates found to create bundle" >&2
    exit 1
fi
