#!/bin/bash
# Multi-Protocol Proxy Deployment Script
# Supports: XHTTP, gRPC
# Version: 2.0.0

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
AUTOCONF_DIR="$SCRIPT_DIR/autoconf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Banner
print_banner() {
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║     Multi-Protocol Proxy Deployment Script                   ║
║                                                              ║
║     Protocols: XHTTP | gRPC                                  ║
║     Features: HAProxy SNI | Auto Certs | WARP                ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        log_error "Cannot detect OS. Supported: Debian 10+, Ubuntu 18.04+"
        exit 1
    fi
    
    log_info "Detected OS: $OS $VER"
    
    # Check if supported
    if [[ "$OS" != "debian" && "$OS" != "ubuntu" ]]; then
        log_error "Unsupported OS: $OS"
        log_error "Supported: Debian 10+, Ubuntu 18.04+"
        exit 1
    fi
}

# Get server public IP
get_server_ip() {
    local ip
    ip=$(curl -s4 ifconfig.me || curl -s4 icanhazip.com || echo "")
    
    if [ -z "$ip" ]; then
        log_error "Failed to detect server IP address"
        exit 1
    fi
    
    echo "$ip"
}

# Install dependencies
install_dependencies() {
    log_info "Installing system dependencies..."
    
    apt-get update
    apt-get install -y \
        curl \
        wget \
        jq \
        openssl \
        socat \
        dnsutils \
        ca-certificates \
        gnupg \
        lsb-release
    
    log_success "Dependencies installed"
}

# Install Xray
install_xray() {
    log_info "Installing Xray-core..."
    
    if [ -f /usr/local/bin/xray ]; then
        log_warn "Xray already installed, skipping..."
        return 0
    fi
    
    # Download and run official install script
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    # Create log directory
    mkdir -p /var/log/xray
    
    # Create config directory
    mkdir -p /usr/local/etc/xray
    mkdir -p /etc/xray/cert
    
    log_success "Xray installed: $(/usr/local/bin/xray version | head -n1)"
}

# Install HAProxy
install_haproxy() {
    log_info "Installing HAProxy..."
    
    if command -v haproxy &> /dev/null; then
        log_warn "HAProxy already installed"
        return 0
    fi
    
    apt-get install -y haproxy
    
    # Enable and start HAProxy
    systemctl enable haproxy
    
    log_success "HAProxy installed: $(haproxy -v | head -n1)"
}

# Configure system optimizations
configure_system() {
    log_info "Applying system optimizations..."
    
    # BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf <<EOF

# BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3

# Network optimizations
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=10
net.ipv4.tcp_keepalive_probes=3
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
        sysctl -p
        log_success "BBR and network optimizations applied"
    else
        log_warn "System optimizations already applied"
    fi
}

# Load configuration
load_config() {
    local config_file=$1
    
    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: $config_file"
        exit 1
    fi
    
    # Validate JSON
    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "Invalid JSON in configuration file"
        exit 1
    fi
    
    CONFIG_JSON=$(cat "$config_file")
    log_success "Configuration loaded: $config_file"
}

# Generate auto-configuration variables
# Argument: force_regenerate (optional)
generate_auto_config() {
    local force_flag=""
    if [ "${FORCE_REGENERATE:-false}" = true ]; then
        log_warn "Force regenerate mode: all UUIDs/passwords/shortids will be regenerated"
        force_flag="--force"
    else
        log_info "Hot reload mode: preserving existing UUIDs/passwords/shortids"
    fi
    
    log_info "Generating auto-configuration variables..."
    
    if ! "$MODULES_DIR/auto-generate.sh" generate "$CONFIG_FILE" $force_flag; then
        log_error "Failed to generate auto-configuration"
        return 1
    fi
    
    log_success "Auto-configuration variables generated"
}

# Deploy Xray configuration
deploy_xray_config() {
    log_info "Generating Xray configuration..."
    
    local xray_config
    xray_config=$("$MODULES_DIR/xray-config.sh" "$CONFIG_FILE")
    
    # Write to config file
    echo "$xray_config" > /usr/local/etc/xray/config.json
    
    # Validate configuration
    if /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json; then
        log_success "Xray configuration generated and validated"
    else
        log_error "Xray configuration validation failed"
        return 1
    fi
}

# Deploy HAProxy configuration
deploy_haproxy_config() {
    local haproxy_enabled
    haproxy_enabled=$(echo "$CONFIG_JSON" | jq -r '.haproxy.enabled')
    
    if [ "$haproxy_enabled" != "true" ]; then
        log_warn "HAProxy is disabled in configuration"
        return 0
    fi
    
    log_info "Generating HAProxy configuration..."
    
    # haproxy-config.sh reads directly from autoconf.env (single source of truth)
    local haproxy_config
    haproxy_config=$("$MODULES_DIR/haproxy-config.sh" "$CONFIG_FILE")
    
    # Write to config file
    echo "$haproxy_config" > /etc/haproxy/haproxy.cfg
    
    # Validate configuration
    if haproxy -c -f /etc/haproxy/haproxy.cfg; then
        log_success "HAProxy configuration generated and validated"
    else
        log_error "HAProxy configuration validation failed"
        return 1
    fi
}

# Manage SSL certificates
manage_certificates() {
    log_info "Managing SSL certificates..."
    
    "$MODULES_DIR/cert-manager.sh" "$CONFIG_FILE" "$SERVER_IP"
}

# Generate subscription
generate_subscription() {
    log_info "Generating subscription URLs..."
    
    if "$MODULES_DIR/nginx-subscription.sh" "$CONFIG_FILE" "$SERVER_IP"; then
        log_success "Subscription setup completed"
    else
        log_warn "Subscription setup failed, continuing..."
    fi
}

# Setup code-server (optional)
setup_code_server() {
    local code_server_enabled
    code_server_enabled=$(echo "$CONFIG_JSON" | jq -r '.code_server.enabled // false')
    
    if [ "$code_server_enabled" = "true" ]; then
        log_info "Setting up code-server..."
        if "$MODULES_DIR/code-server-setup.sh" "$CONFIG_FILE"; then
            log_success "code-server setup completed"
        else
            log_warn "code-server setup failed, continuing..."
        fi
    fi
}

# Start services
start_services() {
    log_info "Starting services..."
    
    # Start Xray
    systemctl enable xray
    systemctl restart xray
    
    if systemctl is-active --quiet xray; then
        log_success "Xray started successfully"
    else
        log_error "Failed to start Xray"
        journalctl -u xray -n 50 --no-pager
        return 1
    fi
    
    # Start HAProxy if enabled
    local haproxy_enabled
    haproxy_enabled=$(echo "$CONFIG_JSON" | jq -r '.haproxy.enabled')
    
    if [ "$haproxy_enabled" = "true" ]; then
        systemctl enable haproxy
        systemctl restart haproxy
        
        if systemctl is-active --quiet haproxy; then
            log_success "HAProxy started successfully"
        else
            log_error "Failed to start HAProxy"
            journalctl -u haproxy -n 50 --no-pager
            return 1
        fi
    fi
}

# Display deployment summary
display_summary() {
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}Deployment Complete!${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo "Server Information:"
    echo "  IP Address: $SERVER_IP"
    echo ""
    
    # Display enabled protocols
    echo "Enabled Protocols:"
    
    local xhttp_enabled=$(echo "$CONFIG_JSON" | jq -r '.protocols.xhttp.enabled // true')
    local grpc_enabled=$(echo "$CONFIG_JSON" | jq -r '.protocols.grpc.enabled // true')
    local warp_enabled=$(echo "$CONFIG_JSON" | jq -r '.warp_outbound.enabled // false')
    
    [ "$xhttp_enabled" = "true" ] && echo "  ✓ VLESS-XHTTP-H2/H3-TLS"
    [ "$grpc_enabled" = "true" ] && echo "  ✓ VLESS-gRPC-TLS"
    [ "$warp_enabled" = "true" ] && echo "  ✓ WARP SOCKS5 Outbound"
    
    echo ""
    echo "Useful Commands:"
    echo "  Check Xray status:   systemctl status xray"
    echo "  Check Xray logs:     journalctl -u xray -f"
    echo "  Renew certificates:  ~/.acme.sh/acme.sh --renew-all"
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo ""
}

# Main deployment function
main_deploy() {
    local config_file=$1
    
    print_banner
    echo ""
    
    # Pre-flight checks
    check_root
    detect_os
    
    # Get server IP
    SERVER_IP=$(get_server_ip)
    log_info "Server IP: $SERVER_IP"
    
    # Load configuration
    load_config "$config_file"
    CONFIG_FILE="$config_file"
    
    # Create autoconf directory for generated configs
    mkdir -p "$AUTOCONF_DIR"
    export AUTOCONF_DIR
    log_info "Autoconf directory: $AUTOCONF_DIR"
    
    # Ensure module scripts are executable
    log_info "Setting executable permissions for modules..."
    chmod +x "$MODULES_DIR"/*.sh
    
    # Install phase
    log_info "===== Installation Phase ====="
    install_dependencies
    install_xray
    install_haproxy
    configure_system
    
    # Auto-configuration phase (must be first - generates autoconf.env for all modules)
    log_info "===== Auto-Configuration Phase ====="
    generate_auto_config
    
    # Certificate phase (reads from autoconf.env, must be before Xray config as it references cert files)
    log_info "===== Certificate Phase ====="
    manage_certificates
    
    # Configuration phase
    log_info "===== Configuration Phase ====="
    deploy_xray_config
    deploy_haproxy_config
    
    # Optional features
    log_info "===== Optional Features ====="
    generate_subscription
    setup_code_server
    
    # Start services
    log_info "===== Starting Services ====="
    start_services
    
    # Display summary
    display_summary
}

# Check-only mode
check_only() {
    local config_file=$1
    
    print_banner
    echo ""
    log_info "Running in check-only mode..."
    
    # Load and validate config
    load_config "$config_file"
    
    log_info "Configuration validation passed"
    
    # Display what would be deployed
    echo ""
    echo "Deployment Preview:"
    echo "  XHTTP:       $(echo "$CONFIG_JSON" | jq -r '.protocols.xhttp.enabled // true')"
    echo "  gRPC:        $(echo "$CONFIG_JSON" | jq -r '.protocols.grpc.enabled // true')"
    echo "  HAProxy:     $(echo "$CONFIG_JSON" | jq -r '.haproxy.enabled // true')"
    echo "  WARP:        $(echo "$CONFIG_JSON" | jq -r '.warp_outbound.enabled // false')"
    echo "  code-server: $(echo "$CONFIG_JSON" | jq -r '.code_server.enabled // false')"
    echo ""
}

# Update mode - skip installation and certificate phases
update_deploy() {
    local config_file=$1
    
    print_banner
    echo ""
    log_info "Running in update mode - skipping installation and certificate phases..."
    echo ""
    
    # Pre-flight checks (lightweight)
    check_root
    detect_os
    
    # Get server IP
    SERVER_IP=$(get_server_ip)
    log_info "Server IP: $SERVER_IP"
    
    # Load configuration
    load_config "$config_file"
    CONFIG_FILE="$config_file"
    
    # Create autoconf directory for generated configs
    mkdir -p "$AUTOCONF_DIR"
    export AUTOCONF_DIR
    log_info "Autoconf directory: $AUTOCONF_DIR"
    
    # Ensure module scripts are executable
    log_info "Setting executable permissions for modules..."
    chmod +x "$MODULES_DIR"/*.sh
    
    # Auto-configuration phase (generate variables before config generation)
    log_info "===== Auto-Configuration Phase ====="
    generate_auto_config
    
    # Configuration phase (skip installation)
    log_info "===== Configuration Phase ====="
    deploy_xray_config
    deploy_haproxy_config
    
    # Optional features
    log_info "===== Optional Features ====="
    generate_subscription
    setup_code_server
    
    # Start services (restart, not initial start)
    log_info "===== Restarting Services ====="
    systemctl restart xray
    if systemctl is-active --quiet xray; then
        log_success "Xray restarted successfully"
    else
        log_error "Failed to restart Xray"
        journalctl -u xray -n 50 --no-pager
        return 1
    fi
    
    # Restart HAProxy if enabled
    local haproxy_enabled
    haproxy_enabled=$(echo "$CONFIG_JSON" | jq -r '.haproxy.enabled')
    
    if [ "$haproxy_enabled" = "true" ]; then
        systemctl restart haproxy
        
        if systemctl is-active --quiet haproxy; then
            log_success "HAProxy restarted successfully"
        else
            log_error "Failed to restart HAProxy"
            journalctl -u haproxy -n 50 --no-pager
            return 1
        fi
    fi
    
    # Display summary
    display_summary
}

# Batch deployment from servers.json
batch_deploy() {
    local servers_file=$1
    
    log_error "Batch deployment not yet implemented"
    log_info "Please deploy servers individually for now"
    exit 1
}

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --config FILE         Path to configuration JSON file (required)
  --check-only          Validate configuration without deploying
  --update              Update configuration only (skip installation & certificates)
  --force               Force regenerate all UUIDs/passwords/shortids (ignore existing)
  --batch FILE          Deploy to multiple servers from servers.json
  --help                Show this help message

Hot Reload:
  By default, UUIDs/passwords/shortids are preserved across updates.
  Use --force to regenerate all auto-generated values.

Examples:
  # Initial deployment (install + configure)
  sudo $0 --config my-config.json
  
  # Update configuration only (faster, preserves UUIDs/passwords)
  sudo $0 --config my-config.json --update
  
  # Force regenerate all values (new UUIDs, passwords, etc.)
  sudo $0 --config my-config.json --update --force
  
  # Check configuration only
  sudo $0 --config my-config.json --check-only
  
  # Batch deployment (TODO)
  sudo $0 --batch servers.json

EOF
    exit 0
}

# Parse command line arguments
CONFIG_FILE=""
CHECK_ONLY=false
UPDATE_ONLY=false
FORCE_REGENERATE=false
BATCH_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --check-only)
            CHECK_ONLY=true
            shift
            ;;
        --update)
            UPDATE_ONLY=true
            shift
            ;;
        --force)
            FORCE_REGENERATE=true
            shift
            ;;
        --batch)
            BATCH_FILE="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Main execution
if [ -n "$BATCH_FILE" ]; then
    batch_deploy "$BATCH_FILE"
elif [ -n "$CONFIG_FILE" ]; then
    if [ "$CHECK_ONLY" = true ]; then
        check_only "$CONFIG_FILE"
    elif [ "$UPDATE_ONLY" = true ]; then
        update_deploy "$CONFIG_FILE"
    else
        main_deploy "$CONFIG_FILE"
    fi
else
    log_error "No configuration file specified"
    usage
fi
