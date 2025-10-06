# SSL Certificate Extractor Makefile

BINARY_NAME=sslcerts
VERSION?=$(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
LDFLAGS=-ldflags="-s -w -X main.version=$(VERSION)"

# Default target
.PHONY: all
all: build

# Build for current platform
.PHONY: build
build:
	go build $(LDFLAGS) -o $(BINARY_NAME) main.go

# Build for all platforms (used by CI)
.PHONY: build-all
build-all: build-linux build-darwin build-windows

.PHONY: build-linux
build-linux:
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build $(LDFLAGS) -o $(BINARY_NAME)-linux-amd64 main.go
	GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build $(LDFLAGS) -o $(BINARY_NAME)-linux-arm64 main.go

.PHONY: build-darwin
build-darwin:
	GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build $(LDFLAGS) -o $(BINARY_NAME)-macos-amd64 main.go
	GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build $(LDFLAGS) -o $(BINARY_NAME)-macos-arm64 main.go

.PHONY: build-windows
build-windows:
	GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build $(LDFLAGS) -o $(BINARY_NAME)-windows-amd64.exe main.go
	GOOS=windows GOARCH=arm64 CGO_ENABLED=0 go build $(LDFLAGS) -o $(BINARY_NAME)-windows-arm64.exe main.go

# Test the application
.PHONY: test
test:
	go test -v ./...

# Run with example
.PHONY: run-example
run-example: build
	./$(BINARY_NAME) example.com

# Clean build artifacts
.PHONY: clean
clean:
	rm -f $(BINARY_NAME)*
	rm -f *.crt *.pem

# Install dependencies
.PHONY: deps
deps:
	go mod download
	go mod tidy

# Format code
.PHONY: fmt
fmt:
	go fmt ./...

# Lint code (requires golangci-lint)
.PHONY: lint
lint:
	golangci-lint run

# Show version
.PHONY: version
version:
	@echo $(VERSION)

# Help
.PHONY: help
help:
	@echo "Available targets:"
	@echo "  build        - Build for current platform"
	@echo "  build-all    - Build for all platforms"
	@echo "  build-linux  - Build for Linux (amd64, arm64)"
	@echo "  build-darwin - Build for macOS (amd64, arm64)"
	@echo "  build-windows- Build for Windows (amd64, arm64)"
	@echo "  test         - Run tests"
	@echo "  run-example  - Build and run with example.com"
	@echo "  clean        - Clean build artifacts"
	@echo "  deps         - Install/update dependencies"
	@echo "  fmt          - Format code"
	@echo "  lint         - Lint code"
	@echo "  version      - Show version"
	@echo "  help         - Show this help"