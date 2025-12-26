#!/bin/bash
# Proton VPN Management API Installation Script
# Installs Flask API service for managing wireproxy-proton

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
INSTALL_DIR="/opt/proton-ctl"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/proton-ctl"
CONFIG_DIR="/etc/wireproxy"
REGIONS_DIR="${CONFIG_DIR}/regions"

# Install Python and dependencies
install_dependencies() {
    echo -e "${YELLOW}Installing dependencies...${NC}"
    
    apt-get update
    apt-get install -y python3 python3-venv python3-pip
    
    echo -e "${GREEN}✓ Dependencies installed${NC}"
}

# Setup proton-ctl API service
setup_proton_ctl() {
    echo -e "${YELLOW}Setting up proton-ctl API...${NC}"
    
    # Create install directory
    mkdir -p "$INSTALL_DIR"
    
    # Copy files
    cp "${SOURCE_DIR}/proton_ctl.py" "$INSTALL_DIR/"
    cp "${SOURCE_DIR}/requirements.txt" "$INSTALL_DIR/"
    
    # Create virtual environment
    python3 -m venv "${INSTALL_DIR}/venv"
    
    # Install Python dependencies
    "${INSTALL_DIR}/venv/bin/pip" install --upgrade pip
    "${INSTALL_DIR}/venv/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"
    
    # Create regions directory
    mkdir -p "$REGIONS_DIR"
    
    echo -e "${GREEN}✓ proton-ctl API installed${NC}"
}

# Create systemd service
create_systemd_service() {
    echo -e "${YELLOW}Creating systemd service...${NC}"
    
    cp "${SOURCE_DIR}/proton-ctl.service" /etc/systemd/system/
    
    systemctl daemon-reload
    systemctl enable proton-ctl
    systemctl start proton-ctl
    
    sleep 2
    
    if systemctl is-active --quiet proton-ctl; then
        echo -e "${GREEN}✓ proton-ctl service started${NC}"
    else
        echo -e "${RED}✗ Failed to start proton-ctl service${NC}"
        journalctl -u proton-ctl -n 20 --no-pager
        return 1
    fi
}

# Create wireproxy-proton systemd service (if not exists)
create_wireproxy_proton_service() {
    if [ -f /etc/systemd/system/wireproxy-proton.service ]; then
        echo -e "${YELLOW}wireproxy-proton.service already exists${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Creating wireproxy-proton systemd service...${NC}"
    
    cat > /etc/systemd/system/wireproxy-proton.service <<EOF
[Unit]
Description=Wireproxy Proton VPN SOCKS5 Proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wireproxy -c ${CONFIG_DIR}/proton.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    
    echo -e "${GREEN}✓ wireproxy-proton.service created (not started)${NC}"
}

# Display summary
display_summary() {
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}Proton VPN Management API Installed${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo "API Endpoints:"
    echo "  GET  /api/proton/status  - Get service status"
    echo "  GET  /api/proton/regions - Get available regions"
    echo "  POST /api/proton/switch  - Switch region"
    echo "  POST /api/proton/start   - Start service"
    echo "  POST /api/proton/stop    - Stop service"
    echo ""
    echo "Configuration:"
    echo "  Install: $INSTALL_DIR"
    echo "  Regions: $REGIONS_DIR"
    echo "  API Port: 127.0.0.1:8081"
    echo ""
    echo "Add WireGuard configs:"
    echo "  cp proton-jp.conf $REGIONS_DIR/"
    echo "  cp proton-us.conf $REGIONS_DIR/"
    echo ""
    echo "Commands:"
    echo "  Status:  systemctl status proton-ctl"
    echo "  Logs:    journalctl -u proton-ctl -f"
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo ""
}

# Main setup function
setup() {
    echo -e "${YELLOW}=====================================${NC}"
    echo -e "${YELLOW}Proton VPN Management API Setup${NC}"
    echo -e "${YELLOW}=====================================${NC}"
    echo ""
    
    install_dependencies
    setup_proton_ctl
    create_systemd_service
    create_wireproxy_proton_service
    display_summary
}

# CLI interface
case "${1:-}" in
    setup|install)
        setup
        ;;
    --help|-h|help|"")
        cat <<EOF
Usage: $0 <command>

Commands:
  setup    Install proton-ctl API service

This script installs the Proton VPN Management API service which provides
HTTP endpoints for managing the wireproxy-proton service.

EOF
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        exit 1
        ;;
esac
