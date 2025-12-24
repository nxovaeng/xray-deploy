#!/bin/bash
# Code-Server Installation Module
# Provides web-based VS Code IDE access

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

# Default configuration
CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-latest}"
CODE_SERVER_PORT="${CODE_SERVER_PORT:-8443}"
CODE_SERVER_BIND="${CODE_SERVER_BIND:-127.0.0.1}"

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
    
    if [ "$CODE_SERVER_VERSION" = "latest" ]; then
        curl -fsSL https://code-server.dev/install.sh | sh
    else
        curl -fsSL https://code-server.dev/install.sh | sh -s -- --version="$CODE_SERVER_VERSION"
    fi
    
    if command -v code-server &> /dev/null; then
        echo -e "${GREEN}✓ code-server installed successfully${NC}"
        code-server --version 2>&1 | head -n1
    else
        echo -e "${RED}✗ Failed to install code-server${NC}"
        return 1
    fi
}

# Generate password for code-server
generate_password() {
    local password
    
    # Check if password already exists in config
    if [ -f ~/.config/code-server/config.yaml ]; then
        password=$(grep "password:" ~/.config/code-server/config.yaml | awk '{print $2}' | tr -d '"' || echo "")
        if [ -n "$password" ]; then
            echo "$password"
            return 0
        fi
    fi
    
    # Generate new password
    password=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)
    echo "$password"
}

# Configure code-server
configure_code_server() {
    local password=$1
    local port=${2:-$CODE_SERVER_PORT}
    local bind_addr=${3:-$CODE_SERVER_BIND}
    local cert_file=${4:-""}
    local key_file=${5:-""}
    
    echo -e "${YELLOW}Configuring code-server...${NC}"
    
    # Create config directory
    mkdir -p ~/.config/code-server
    
    # Generate configuration
    if [ -n "$cert_file" ] && [ -n "$key_file" ] && [ -f "$cert_file" ] && [ -f "$key_file" ]; then
        # HTTPS configuration with certificates
        cat > ~/.config/code-server/config.yaml <<EOF
bind-addr: ${bind_addr}:${port}
auth: password
password: ${password}
cert: ${cert_file}
cert-key: ${key_file}
EOF
        echo -e "${GREEN}✓ code-server configured with HTTPS${NC}"
    else
        # HTTP configuration (use with reverse proxy)
        cat > ~/.config/code-server/config.yaml <<EOF
bind-addr: ${bind_addr}:${port}
auth: password
password: ${password}
cert: false
EOF
        echo -e "${GREEN}✓ code-server configured with HTTP (use behind reverse proxy)${NC}"
    fi
    
    # Secure the config file
    chmod 600 ~/.config/code-server/config.yaml
    
    echo -e "${YELLOW}Configuration saved to: ~/.config/code-server/config.yaml${NC}"
}

# Create systemd service for code-server
create_systemd_service() {
    local user=${1:-root}
    local working_dir=${2:-/root}
    
    echo -e "${YELLOW}Creating systemd service...${NC}"
    
    # The official install script creates a service, but we override for custom user
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

# Stop code-server service
stop_code_server() {
    echo -e "${YELLOW}Stopping code-server...${NC}"
    
    systemctl stop code-server 2>/dev/null || true
    systemctl disable code-server 2>/dev/null || true
    
    echo -e "${GREEN}✓ code-server stopped${NC}"
}

# Configure HAProxy backend for code-server (optional)
configure_haproxy_backend() {
    local domain=$1
    local port=${2:-$CODE_SERVER_PORT}
    
    echo -e "${YELLOW}Generating HAProxy backend configuration for code-server...${NC}"
    
    cat <<EOF

# code-server HAProxy configuration
# Add this to your HAProxy config

# In frontend section, add:
#   use_backend code_server if { ssl_fc_sni ${domain} }

# Backend definition:
backend code_server
    mode http
    option httpchk GET /healthz
    http-check expect status 200
    server code-server 127.0.0.1:${port} check

EOF
}

# Configure Nginx location for code-server (optional)
configure_nginx_location() {
    local port=${1:-$CODE_SERVER_PORT}
    
    echo -e "${YELLOW}Generating Nginx location configuration for code-server...${NC}"
    
    cat <<EOF

# code-server Nginx configuration
# Add this location block to your Nginx server config

location / {
    proxy_pass http://127.0.0.1:${port};
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Accept-Encoding gzip;
    
    # WebSocket timeout
    proxy_read_timeout 86400;
}

EOF
}

# Install common extensions
install_extensions() {
    echo -e "${YELLOW}Installing common extensions...${NC}"
    
    local extensions=(
        "ms-python.python"
        "golang.go"
        "rust-lang.rust-analyzer"
        "ms-vscode.cpptools"
        "dbaeumer.vscode-eslint"
        "esbenp.prettier-vscode"
        "eamodio.gitlens"
        "gruntfuggly.todo-tree"
    )
    
    for ext in "${extensions[@]}"; do
        echo -e "${YELLOW}Installing extension: $ext${NC}"
        code-server --install-extension "$ext" 2>/dev/null || echo -e "${YELLOW}⚠ Failed to install $ext${NC}"
    done
    
    echo -e "${GREEN}✓ Extensions installation completed${NC}"
}

# Display status and access information
display_status() {
    local password=$1
    local port=${2:-$CODE_SERVER_PORT}
    local bind_addr=${3:-$CODE_SERVER_BIND}
    
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}code-server Setup Complete${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo "Access Information:"
    
    if [ "$bind_addr" = "127.0.0.1" ] || [ "$bind_addr" = "localhost" ]; then
        echo "  URL: http://localhost:${port}"
        echo "  (Use SSH tunnel: ssh -L ${port}:localhost:${port} user@server)"
    else
        echo "  URL: http://${bind_addr}:${port}"
    fi
    
    echo ""
    echo "Credentials:"
    echo "  Password: ${password}"
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

# Main setup function
setup_code_server() {
    local config_json=$1
    
    # Parse configuration
    local enabled
    local port
    local bind_addr
    local password
    local install_exts
    local cert_file
    local key_file
    
    enabled=$(echo "$config_json" | jq -r '.code_server.enabled // false')
    
    if [ "$enabled" != "true" ]; then
        echo -e "${YELLOW}code-server is disabled in configuration${NC}"
        return 0
    fi
    
    port=$(echo "$config_json" | jq -r '.code_server.port // 8443')
    bind_addr=$(echo "$config_json" | jq -r '.code_server.bind_address // "127.0.0.1"')
    password=$(echo "$config_json" | jq -r '.code_server.password // null')
    install_exts=$(echo "$config_json" | jq -r '.code_server.install_extensions // false')
    cert_file=$(echo "$config_json" | jq -r '.code_server.cert_file // ""')
    key_file=$(echo "$config_json" | jq -r '.code_server.key_file // ""')
    
    echo -e "${YELLOW}=====================================${NC}"
    echo -e "${YELLOW}code-server Setup${NC}"
    echo -e "${YELLOW}=====================================${NC}"
    echo ""
    
    # Generate password if not provided
    if [ "$password" = "null" ] || [ -z "$password" ]; then
        password=$(generate_password)
        echo -e "${YELLOW}Generated password: $password${NC}"
    fi
    
    # Install code-server
    install_code_server || {
        echo -e "${RED}✗ Failed to install code-server${NC}"
        return 1
    }
    
    # Configure
    configure_code_server "$password" "$port" "$bind_addr" "$cert_file" "$key_file"
    
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
    display_status "$password" "$port" "$bind_addr"
    
    # Save password to autoconf for reference
    if [ -d "$AUTOCONF_DIR" ]; then
        echo "CODE_SERVER_PASSWORD=\"$password\"" >> "${AUTOCONF_DIR}/autoconf.env"
        echo "CODE_SERVER_PORT=\"$port\"" >> "${AUTOCONF_DIR}/autoconf.env"
    fi
    
    return 0
}

# Uninstall code-server
uninstall_code_server() {
    echo -e "${YELLOW}Uninstalling code-server...${NC}"
    
    # Stop service
    stop_code_server
    
    # Remove systemd service
    rm -f /etc/systemd/system/code-server.service
    systemctl daemon-reload
    
    # Remove binary
    rm -f /usr/bin/code-server
    rm -rf /usr/lib/code-server
    
    # Remove config (optional, ask user)
    echo -e "${YELLOW}Remove configuration and data? (y/N)${NC}"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        rm -rf ~/.config/code-server
        rm -rf ~/.local/share/code-server
        echo -e "${GREEN}✓ Configuration and data removed${NC}"
    fi
    
    echo -e "${GREEN}✓ code-server uninstalled${NC}"
}

# Show usage
show_usage() {
    cat <<EOF
Usage: $0 <command> [options]

Commands:
  <config-file.json>    Install and configure from JSON config
  install               Install code-server only
  configure <password>  Configure with specified password
  start                 Start code-server service
  stop                  Stop code-server service
  status                Show status and access info
  extensions            Install common extensions
  uninstall             Uninstall code-server
  haproxy <domain>      Generate HAProxy backend config
  nginx                 Generate Nginx location config

JSON Configuration Example:
{
  "code_server": {
    "enabled": true,
    "port": 8443,
    "bind_address": "127.0.0.1",
    "password": "your-password",
    "install_extensions": true,
    "cert_file": "",
    "key_file": ""
  }
}

EOF
}

# Main execution
case "${1:-}" in
    install)
        install_code_server
        ;;
    configure)
        password=${2:-$(generate_password)}
        configure_code_server "$password"
        echo "Password: $password"
        ;;
    start)
        start_code_server
        ;;
    stop)
        stop_code_server
        ;;
    status)
        systemctl status code-server
        ;;
    extensions)
        install_extensions
        ;;
    uninstall)
        uninstall_code_server
        ;;
    haproxy)
        domain=${2:-"code.example.com"}
        configure_haproxy_backend "$domain"
        ;;
    nginx)
        configure_nginx_location
        ;;
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
