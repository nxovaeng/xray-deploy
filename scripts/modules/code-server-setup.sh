#!/bin/bash
# Code-Server Installation Module
# Provides web-based VS Code IDE access via HAProxy reverse proxy

set -euo pipefail

# Use AUTOCONF_DIR from environment or fallback to /tmp
AUTOCONF_DIR="${AUTOCONF_DIR:-/tmp}"
AUTOCONF_FILE="${AUTOCONF_DIR}/autoconf.env"

# Load auto-generated variables if available
if [ -f "$AUTOCONF_FILE" ]; then
    source "$AUTOCONF_FILE"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Port is read from autoconf.env (PORT_CODE_SERVER)
CODE_SERVER_BIND="127.0.0.1"

# Install code-server
install_code_server() {
    echo -e "${YELLOW}Installing code-server...${NC}"
    
    # Check if already installed
    if command -v code-server &> /dev/null; then
        local current_version
        current_version=$(code-server --version 2>&1 | head -n1)
        echo -e "${GREEN}code-server already installed: $current_version${NC}"
        return 0
    fi
    
    # Install using official script
    echo -e "${YELLOW}Downloading and installing code-server...${NC}"
    
    curl -fsSL https://code-server.dev/install.sh | sh
    
    if command -v code-server &> /dev/null; then
        echo -e "${GREEN}✓ code-server installed successfully${NC}"
        code-server --version 2>&1 | head -n1
    else
        echo -e "${RED}✗ Failed to install code-server${NC}"
        return 1
    fi
}

# Configure code-server with certificate (uses wildcard cert from cert-manager)
configure_code_server() {
    local password=$1
    local port=$2
    local cert_file=$3
    local key_file=$4
    
    echo -e "${YELLOW}Configuring code-server...${NC}"
    
    # Create config directory
    mkdir -p ~/.config/code-server
    
    # Generate configuration with HTTPS (using wildcard cert)
    cat > ~/.config/code-server/config.yaml <<EOF
bind-addr: ${CODE_SERVER_BIND}:${port}
auth: password
password: ${password}
cert: ${cert_file}
cert-key: ${key_file}
EOF
    
    # Secure the config file
    chmod 600 ~/.config/code-server/config.yaml
    
    echo -e "${GREEN}✓ code-server configured${NC}"
    echo -e "${YELLOW}  - Bind: ${CODE_SERVER_BIND}:${port}${NC}"
    echo -e "${YELLOW}  - Cert: ${cert_file}${NC}"
}

# Create systemd service for code-server
create_systemd_service() {
    local user=${1:-root}
    local working_dir=${2:-/root}
    
    echo -e "${YELLOW}Creating systemd service...${NC}"
    
    cat > /etc/systemd/system/code-server.service <<EOF
[Unit]
Description=code-server
After=network.target

[Service]
Type=exec
User=${user}
WorkingDirectory=${working_dir}
ExecStart=/usr/bin/code-server
Restart=always
RestartSec=10
Environment=HOME=${working_dir}

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload
    
    echo -e "${GREEN}✓ Systemd service created${NC}"
}

# Start code-server service
start_code_server() {
    echo -e "${YELLOW}Starting code-server...${NC}"
    
    systemctl enable code-server
    systemctl restart code-server
    
    sleep 2
    
    if systemctl is-active --quiet code-server; then
        echo -e "${GREEN}✓ code-server started successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to start code-server${NC}"
        journalctl -u code-server -n 20 --no-pager
        return 1
    fi
}

# Install common extensions
install_extensions() {
    echo -e "${YELLOW}Installing common extensions...${NC}"
    
    local extensions=(
        "ms-python.python"
        "golang.go"
        "rust-lang.rust-analyzer"
        "dbaeumer.vscode-eslint"
        "esbenp.prettier-vscode"
        "eamodio.gitlens"
    )
    
    for ext in "${extensions[@]}"; do
        echo -e "${YELLOW}  Installing: $ext${NC}"
        code-server --install-extension "$ext" 2>/dev/null || true
    done
    
    echo -e "${GREEN}✓ Extensions installation completed${NC}"
}

# Display status and access information
display_status() {
    local password=$1
    local domain=$2
    
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}code-server Setup Complete${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo "Access Information:"
    echo -e "  URL: ${GREEN}https://${domain}${NC}"
    echo -e "  Password: ${GREEN}${password}${NC}"
    echo ""
    echo "Configuration:"
    echo "  Config file: ~/.config/code-server/config.yaml"
    echo "  Data dir: ~/.local/share/code-server"
    echo ""
    echo "Useful Commands:"
    echo "  Status:   systemctl status code-server"
    echo "  Logs:     journalctl -u code-server -f"
    echo "  Restart:  systemctl restart code-server"
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo ""
}

# Main setup function (reads from config.json and autoconf.env)
setup_code_server() {
    local config_json=$1
    
    # Parse configuration
    local enabled
    local install_exts
    local port
    
    enabled=$(echo "$config_json" | jq -r '.code_server.enabled // false')
    
    if [ "$enabled" != "true" ]; then
        echo -e "${YELLOW}code-server is disabled in configuration${NC}"
        return 0
    fi
    
    install_exts=$(echo "$config_json" | jq -r '.code_server.install_extensions // false')
    
    # Port is read from autoconf.env
    local port="${PORT_CODE_SERVER:-45443}"
    
    # Read from autoconf.env (single source of truth)
    local password="${CODE_SERVER_PASSWORD:-}"
    local domain="${DOMAIN_CODE_SERVER:-}"
    local cert_dir="/etc/xray/cert"
    local cert_file="${cert_dir}/fullchain.pem"
    local key_file="${cert_dir}/privkey.pem"
    
    # Validate required variables
    if [ -z "$password" ]; then
        echo -e "${RED}✗ CODE_SERVER_PASSWORD not found in autoconf.env${NC}"
        return 1
    fi
    
    if [ -z "$domain" ]; then
        echo -e "${RED}✗ DOMAIN_CODE_SERVER not found in autoconf.env${NC}"
        return 1
    fi
    
    # Check certificate files
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        echo -e "${RED}✗ Certificate files not found in ${cert_dir}${NC}"
        echo -e "${YELLOW}  Run cert-manager.sh first to issue wildcard certificate${NC}"
        return 1
    fi
    
    echo -e "${YELLOW}=====================================${NC}"
    echo -e "${YELLOW}code-server Setup${NC}"
    echo -e "${YELLOW}=====================================${NC}"
    echo ""
    echo "Domain: $domain"
    echo "Port: $port (internal, HAProxy routes external 443)"
    echo ""
    
    # Install code-server
    install_code_server || {
        echo -e "${RED}✗ Failed to install code-server${NC}"
        return 1
    }
    
    # Configure with wildcard certificate
    configure_code_server "$password" "$port" "$cert_file" "$key_file"
    
    # Create systemd service
    create_systemd_service "root" "/root"
    
    # Install extensions if requested
    if [ "$install_exts" = "true" ]; then
        install_extensions
    fi
    
    # Start service
    start_code_server || {
        echo -e "${RED}✗ Failed to start code-server${NC}"
        return 1
    }
    
    # Display status
    display_status "$password" "$domain"
    
    return 0
}

# Show usage
show_usage() {
    cat <<EOF
Usage: $0 <config-file.json>

This module installs and configures code-server for web-based VS Code access.

Requirements:
  - autoconf.env must be generated first (run auto-generate.sh)
  - Wildcard certificate must be issued (run cert-manager.sh)
  - HAProxy must be configured to route code.{domain} (run haproxy-config.sh)

JSON Configuration:
{
  "code_server": {
    "enabled": true,
    "port": 8443,
    "password": "auto-generate",
    "install_extensions": false
  }
}

Variables from autoconf.env:
  - CODE_SERVER_PASSWORD: Login password
  - DOMAIN_CODE_SERVER: Access domain (code.{wildcard_base})

EOF
}

# Main execution
case "${1:-}" in
    --help|-h|help)
        show_usage
        ;;
    *.json)
        if [ -f "$1" ]; then
            CONFIG_JSON=$(cat "$1")
            setup_code_server "$CONFIG_JSON"
        else
            echo -e "${RED}Error: Configuration file not found: $1${NC}"
            exit 1
        fi
        ;;
    *)
        if [ -n "${1:-}" ]; then
            echo -e "${RED}Unknown command: $1${NC}"
        fi
        show_usage
        exit 1
        ;;
esac
