package main

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"flag"
	"fmt"
	"net"
	"net/smtp"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Target      string
	InsecureSSL bool
	Timeout     time.Duration
	Verbose     bool
}

func main() {
	var config Config
	flag.StringVar(&config.Target, "target", "", "Target server (server:port, protocol://server, or just server)")
	flag.BoolVar(&config.InsecureSSL, "insecure", false, "Skip certificate verification")
	flag.DurationVar(&config.Timeout, "timeout", 10*time.Second, "Connection timeout")
	flag.BoolVar(&config.Verbose, "verbose", false, "Verbose output")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "SSL Certificate Extractor\n\n")
		fmt.Fprintf(os.Stderr, "Usage: %s [options] target\n\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "Creates a certificate bundle file (server_bundle.pem) containing all certificates\n")
		fmt.Fprintf(os.Stderr, "in the chain that can be used with curl, wget, and other SSL/TLS clients.\n\n")
		fmt.Fprintf(os.Stderr, "Arguments:\n")
		fmt.Fprintf(os.Stderr, "  target    Target server in format:\n")
		fmt.Fprintf(os.Stderr, "            - server (defaults to port 443)\n")
		fmt.Fprintf(os.Stderr, "            - server:port\n")
		fmt.Fprintf(os.Stderr, "            - protocol://server (https, smtp, imap, pop3)\n\n")
		fmt.Fprintf(os.Stderr, "Options:\n")
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nExamples:\n")
		fmt.Fprintf(os.Stderr, "  %s example.com\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s example.com:443\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s https://github.com\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s smtp://smtp.gmail.com:587\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s -insecure self-signed.example.com\n", os.Args[0])
	}

	flag.Parse()

	if flag.NArg() > 0 {
		config.Target = flag.Arg(0)
	}

	if config.Target == "" {
		flag.Usage()
		os.Exit(1)
	}

	if err := extractCertificates(config); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func extractCertificates(config Config) error {
	server, port, protocol, err := parseTarget(config.Target)
	if err != nil {
		return fmt.Errorf("invalid target: %v", err)
	}

	if config.Verbose {
		fmt.Printf("Connecting to %s:%d (protocol: %s)...\n", server, port, protocol)
	}

	// Get certificates based on protocol
	var certs []*x509.Certificate
	switch protocol {
	case "https", "tls":
		certs, err = getTLSCertificates(server, port, config)
	case "smtp":
		certs, err = getSMTPCertificates(server, port, config)
	case "imap":
		certs, err = getIMAPCertificates(server, port, config)
	case "pop3":
		certs, err = getPOP3Certificates(server, port, config)
	default:
		certs, err = getTLSCertificates(server, port, config)
	}

	if err != nil {
		return fmt.Errorf("failed to get certificates: %v", err)
	}

	if len(certs) == 0 {
		return fmt.Errorf("no certificates found")
	}

	// Create certificate bundle
	bundleFile := fmt.Sprintf("%s_bundle.pem", server)
	if err := createCertificateBundle(certs, bundleFile, config.Verbose); err != nil {
		return fmt.Errorf("failed to create bundle: %v", err)
	}

	// Create individual certificate files
	if err := createIndividualCertificates(certs, config.Verbose); err != nil {
		return fmt.Errorf("failed to create individual certificates: %v", err)
	}

	// Print usage instructions
	printUsageInstructions(bundleFile, server)

	return nil
}

func parseTarget(target string) (server string, port int, protocol string, err error) {
	// Default values
	port = 443
	protocol = "https"

	// Check for protocol://server format
	if strings.Contains(target, "://") {
		parts := strings.SplitN(target, "://", 2)
		protocol = strings.ToLower(parts[0])
		serverPart := parts[1]

		// Remove path if present
		if idx := strings.Index(serverPart, "/"); idx != -1 {
			serverPart = serverPart[:idx]
		}

		// Check for port in server part
		if strings.Contains(serverPart, ":") {
			host, portStr, splitErr := net.SplitHostPort(serverPart)
			if splitErr != nil {
				return "", 0, "", splitErr
			}
			server = host
			port, err = strconv.Atoi(portStr)
			if err != nil {
				return "", 0, "", fmt.Errorf("invalid port: %s", portStr)
			}
		} else {
			server = serverPart
			// Set default ports based on protocol
			switch protocol {
			case "https":
				port = 443
			case "smtp":
				port = 587 // STARTTLS port
			case "imap":
				port = 143 // STARTTLS port
			case "pop3":
				port = 110 // STARTTLS port
			default:
				port = 443
			}
		}
	} else if strings.Contains(target, ":") {
		// server:port format
		host, portStr, splitErr := net.SplitHostPort(target)
		if splitErr != nil {
			return "", 0, "", splitErr
		}
		server = host
		port, err = strconv.Atoi(portStr)
		if err != nil {
			return "", 0, "", fmt.Errorf("invalid port: %s", portStr)
		}
	} else {
		// Just server name
		server = target
	}

	return server, port, protocol, nil
}

func getTLSCertificates(server string, port int, config Config) ([]*x509.Certificate, error) {
	conn, err := tls.DialWithDialer(
		&net.Dialer{Timeout: config.Timeout},
		"tcp",
		fmt.Sprintf("%s:%d", server, port),
		&tls.Config{
			InsecureSkipVerify: config.InsecureSSL,
			ServerName:         server,
		},
	)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	state := conn.ConnectionState()
	return state.PeerCertificates, nil
}

func getSMTPCertificates(server string, port int, config Config) ([]*x509.Certificate, error) {
	// Connect to SMTP server
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", server, port), config.Timeout)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	// Create SMTP client
	client, err := smtp.NewClient(conn, server)
	if err != nil {
		return nil, err
	}
	defer client.Quit()

	// Start TLS
	tlsConfig := &tls.Config{
		InsecureSkipVerify: config.InsecureSSL,
		ServerName:         server,
	}

	if err := client.StartTLS(tlsConfig); err != nil {
		return nil, err
	}

	// The standard library doesn't expose the TLS connection state from SMTP
	// So we'll use our custom STARTTLS implementation
	client.Quit()
	conn.Close()

	return getTLSCertificatesWithSTARTTLS(server, port, "smtp", config)
}

func getIMAPCertificates(server string, port int, config Config) ([]*x509.Certificate, error) {
	return getTLSCertificatesWithSTARTTLS(server, port, "imap", config)
}

func getPOP3Certificates(server string, port int, config Config) ([]*x509.Certificate, error) {
	return getTLSCertificatesWithSTARTTLS(server, port, "pop3", config)
}

func getTLSCertificatesWithSTARTTLS(server string, port int, protocol string, config Config) ([]*x509.Certificate, error) {
	// Connect to the server
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", server, port), config.Timeout)
	if err != nil {
		return nil, err
	}
	defer conn.Close()

	// Set read timeout for initial responses
	conn.SetReadDeadline(time.Now().Add(config.Timeout))

	// Read initial server greeting
	buffer := make([]byte, 4096)
	_, err = conn.Read(buffer)
	if err != nil {
		return nil, fmt.Errorf("failed to read server greeting: %v", err)
	}

	// Send STARTTLS command based on protocol
	var starttlsCmd string
	switch protocol {
	case "smtp":
		// Send EHLO first
		conn.Write([]byte("EHLO localhost\r\n"))
		conn.Read(buffer) // Read EHLO response
		starttlsCmd = "STARTTLS\r\n"
	case "imap":
		starttlsCmd = "a001 STARTTLS\r\n"
	case "pop3":
		starttlsCmd = "STLS\r\n"
	default:
		return nil, fmt.Errorf("unsupported STARTTLS protocol: %s", protocol)
	}

	// Send STARTTLS command
	_, err = conn.Write([]byte(starttlsCmd))
	if err != nil {
		return nil, fmt.Errorf("failed to send STARTTLS: %v", err)
	}

	// Read STARTTLS response
	_, err = conn.Read(buffer)
	if err != nil {
		return nil, fmt.Errorf("failed to read STARTTLS response: %v", err)
	}

	// Upgrade to TLS
	tlsConn := tls.Client(conn, &tls.Config{
		InsecureSkipVerify: config.InsecureSSL,
		ServerName:         server,
	})

	err = tlsConn.Handshake()
	if err != nil {
		return nil, fmt.Errorf("TLS handshake failed: %v", err)
	}

	state := tlsConn.ConnectionState()
	return state.PeerCertificates, nil
}

func createCertificateBundle(certs []*x509.Certificate, filename string, verbose bool) error {
	file, err := os.Create(filename)
	if err != nil {
		return err
	}
	defer file.Close()

	for i, cert := range certs {
		if verbose {
			fmt.Printf("Adding certificate %d to bundle: %s\n", i+1, cert.Subject.CommonName)
		}

		block := &pem.Block{
			Type:  "CERTIFICATE",
			Bytes: cert.Raw,
		}

		if err := pem.Encode(file, block); err != nil {
			return err
		}

		// Add newline between certificates
		if i < len(certs)-1 {
			file.Write([]byte("\n"))
		}
	}

	fmt.Printf("Created certificate bundle: %s\n", filename)
	fmt.Printf("Bundle contains %d certificate(s)\n", len(certs))

	return nil
}

func createIndividualCertificates(certs []*x509.Certificate, verbose bool) error {
	for i, cert := range certs {
		filename := generateCertFilename(cert, i+1)

		// Check if file already exists
		if _, err := os.Stat(filename); err == nil {
			if verbose {
				fmt.Printf("Individual cert already exists: %s\n", filename)
			}
			continue
		}

		file, err := os.Create(filename)
		if err != nil {
			return err
		}

		block := &pem.Block{
			Type:  "CERTIFICATE",
			Bytes: cert.Raw,
		}

		err = pem.Encode(file, block)
		file.Close()

		if err != nil {
			return err
		}

		fmt.Printf("Saving individual cert: %s\n", filename)
	}

	return nil
}

func generateCertFilename(cert *x509.Certificate, index int) string {
	// Try to use the common name
	if cert.Subject.CommonName != "" {
		name := sanitizeFilename(cert.Subject.CommonName)
		return fmt.Sprintf("%s.crt", name)
	}

	// Try to use the first DNS name
	if len(cert.DNSNames) > 0 {
		name := sanitizeFilename(cert.DNSNames[0])
		return fmt.Sprintf("%s.crt", name)
	}

	// Fall back to generic name
	return fmt.Sprintf("cert_%d.crt", index)
}

func sanitizeFilename(name string) string {
	// Remove or replace invalid filename characters
	re := regexp.MustCompile(`[^a-zA-Z0-9\-\._]`)
	cleaned := re.ReplaceAllString(name, "_")

	// Remove leading wildcards
	cleaned = strings.TrimPrefix(cleaned, "*.")

	return cleaned
}

func printUsageInstructions(bundleFile, server string) {
	fmt.Printf("\nUsage with curl:\n")
	fmt.Printf("  curl --cacert %s https://%s/\n", bundleFile, server)
	fmt.Printf("  curl --capath . https://%s/\n", server)
	fmt.Printf("\nUsage with environment variables:\n")

	absPath, _ := filepath.Abs(bundleFile)
	fmt.Printf("  export SSL_CERT_FILE='%s'\n", absPath)
	fmt.Printf("  export REQUESTS_CA_BUNDLE='%s'\n", absPath)
	fmt.Printf("\nUsage with Go:\n")
	fmt.Printf("  import \"crypto/x509\"\n")
	fmt.Printf("  caCert, _ := ioutil.ReadFile(\"%s\")\n", bundleFile)
	fmt.Printf("  caCertPool := x509.NewCertPool()\n")
	fmt.Printf("  caCertPool.AppendCertsFromPEM(caCert)\n")
}
