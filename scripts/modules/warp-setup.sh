#!/bin/bash
# Cloudflare WARP Outbound Setup Module

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Install wgcf (WireGuard Cloudflare WARP)
install_wgcf() {
    echo -e "${YELLOW}Installing wgcf...${NC}"
    
    # Check if already installed
    if command -v wgcf &> /dev/null; then
        echo -e "${GREEN}wgcf already installed: $(wgcf --version 2>&1 | head -n1)${NC}"
        return 0
    fi
    
    # Download latest wgcf
    local arch="amd64"
    [ "$(uname -m)" = "aarch64" ] && arch="arm64"
    [ "$(uname -m)" = "armv7l" ] && arch="arm"
    
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local download_url="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_${os}_${arch}"
    
    echo -e "${YELLOW}Downloading wgcf from: $download_url${NC}"
    
    if wget -q -O /usr/local/bin/wgcf "$download_url"; then
        chmod +x /usr/local/bin/wgcf
        echo -e "${GREEN}✓ wgcf installed successfully${NC}"
        wgcf --version 2>&1 | head -n1
    else
        echo -e "${RED}✗ Failed to download wgcf${NC}"
        return 1
    fi
}

# Register WARP account and generate config
setup_wgcf_config() {
    local work_dir="/etc/wireguard/warp"
    local license_key=$1
    
    mkdir -p "$work_dir"
    cd "$work_dir"
    
    echo -e "${YELLOW}Registering WARP account...${NC}"
    
    # Register if not already done
    if [ ! -f "wgcf-account.toml" ]; then
        if wgcf register --accept-tos; then
            echo -e "${GREEN}✓ WARP account registered${NC}"
        else
            echo -e "${RED}✗ Failed to register WARP account${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}WARP account already registered${NC}"
    fi
    
    # Apply license key if provided
    if [ -n "$license_key" ] && [ "$license_key" != "null" ]; then
        echo -e "${YELLOW}Applying WARP+ license key...${NC}"
        # Update license in config file
        sed -i "s/license_key = .*/license_key = '${license_key}'/" wgcf-account.toml
        if wgcf update; then
            echo -e "${GREEN}✓ WARP+ license applied${NC}"
        else
            echo -e "${YELLOW}⚠ Failed to apply license, continuing with free tier${NC}"
        fi
    fi
    
    # Generate WireGuard config
    echo -e "${YELLOW}Generating WireGuard configuration...${NC}"
    if wgcf generate; then
        echo -e "${GREEN}✓ WireGuard configuration generated${NC}"
    else
        echo -e "${RED}✗ Failed to generate WireGuard configuration${NC}"
        return 1
    fi
    
    # Verify config file exists
    if [ ! -f "wgcf-profile.conf" ]; then
        echo -e "${RED}✗ Configuration file not found${NC}"
        return 1
    fi
    
    # Extract configuration values
    local private_key
    local address_v4
    local address_v6
    local public_key
    local endpoint
    
    private_key=$(grep "PrivateKey" wgcf-profile.conf | cut -d' ' -f3)
    address_v4=$(grep "Address" wgcf-profile.conf | cut -d' ' -f3 | cut -d',' -f1)
    address_v6=$(grep "Address" wgcf-profile.conf | cut -d' ' -f3 | cut -d',' -f2 | tr -d ' ')
    public_key=$(grep "PublicKey" wgcf-profile.conf | cut -d' ' -f3)
    endpoint=$(grep "Endpoint" wgcf-profile.conf | cut -d' ' -f3)
    
    # Validate extracted values
    if [ -z "$private_key" ] || [ -z "$address_v4" ] || [ -z "$public_key" ] || [ -z "$endpoint" ]; then
        echo -e "${RED}✗ Failed to extract configuration values${NC}"
        return 1
    fi
    
    # Save to temporary file for Xray configuration
    cat > /tmp/warp_config <<EOF
{
  "private_key": "$private_key",
  "address_v4": "$address_v4",
  "address_v6": "$address_v6",
  "public_key": "$public_key",
  "endpoint": "$endpoint",
  "mtu": 1420,
  "reserved": [0, 0, 0]
}
EOF
    
    echo -e "${GREEN}✓ WARP configuration generated and saved${NC}"
    echo -e "${YELLOW}Configuration details:${NC}"
    echo "  - IPv4: $address_v4"
    echo "  - IPv6: $address_v6"
    echo "  - Endpoint: $endpoint"
    echo "  - Config: /tmp/warp_config"
    
    return 0
}

# Update Xray configuration with WARP outbound
update_xray_warp_config() {
    local xray_config="/usr/local/etc/xray/config.json"
    
    if [ ! -f "/tmp/warp_config" ]; then
        echo -e "${RED}✗ WARP config not found. Run setup first.${NC}"
        return 1
    fi
    
    # Read WARP config
    local private_key
    local address_v4
    local address_v6
    local public_key
    local endpoint
    local mtu
    
    private_key=$(jq -r '.private_key' /tmp/warp_config)
    address_v4=$(jq -r '.address_v4' /tmp/warp_config)
    address_v6=$(jq -r '.address_v6' /tmp/warp_config)
    public_key=$(jq -r '.public_key' /tmp/warp_config)
    endpoint=$(jq -r '.endpoint' /tmp/warp_config)
    mtu=$(jq -r '.mtu //1420' /tmp/warp_config)
    
    echo -e "${YELLOW}Updating Xray configuration with WARP outbound...${NC}"
    
    # Backup original config
    cp "$xray_config" "${xray_config}.backup.$(date +%Y%m%d%H%M%S)"
    
    # Update outbounds with actual WARP config
    jq --arg pk "$private_key" \
       --arg addr4 "$address_v4" \
       --arg addr6 "$address_v6" \
       --arg pubkey "$public_key" \
       --arg ep "$endpoint" \
       --argjson mtu "$mtu" \
       '.outbounds |= map(
         if .tag == "warp" then
           .settings.secretKey = $pk |
           .settings.address = [$addr4, $addr6] |
           .settings.peers[0].publicKey = $pubkey |
           .settings.peers[0].endpoint = $ep |
           .settings.mtu = $mtu |
           .settings.peers[0].keepAlive = 30 |
           .settings.reserved = [0, 0, 0]
         else
           .
         end
       )' "$xray_config" > /tmp/xray_config_new.json
    
    if [ $? -eq 0 ]; then
        mv /tmp/xray_config_new.json "$xray_config"
        echo -e "${GREEN}✓ Xray configuration updated with WARP${NC}"
        echo -e "${YELLOW}  - Private Key: [REDACTED]${NC}"
        echo "  - IPv4 Address: $address_v4"
        echo "  - IPv6 Address: $address_v6"
        echo "  - Endpoint: $endpoint"
        echo "  - MTU: $mtu"
    else
        echo -e "${RED}✗ Failed to update Xray configuration${NC}"
        return 1
    fi
}

# Test WARP connection
test_warp_connection() {
    echo -e "${YELLOW}Testing WARP connection...${NC}"
    
    # Restart Xray to apply configuration
    systemctl restart xray
    sleep 3
    
    # Test via curl through Xray SOCKS proxy
    local test_result
    test_result=$(curl -s --max-time 10 --proxy socks5://127.0.0.1:10808 https://1.1.1.1/cdn-cgi/trace 2>/dev/null || echo "failed")
    
    if echo "$test_result" | grep -q "warp=on"; then
        echo -e "${GREEN}✓ WARP is working!${NC}"
        echo "$test_result"
        return 0
    elif echo "$test_result" | grep -q "warp=off"; then
        echo -e "${YELLOW}⚠ Connection successful but WARP is off${NC}"
        echo "$test_result"
        return 1
    else
        echo -e "${RED}✗ WARP connection test failed${NC}"
        return 1
    fi
}

# Main WARP setup function
setup_warp() {
    local config_json=$1
    
    local warp_enabled
    local license_key
    warp_enabled=$(echo "$config_json" | jq -r '.warp_outbound.enabled')
    license_key=$(echo "$config_json" | jq -r '.warp_outbound.license_key // null')
    
    if [ "$warp_enabled" != "true" ]; then
        echo -e "${YELLOW}WARP outbound is disabled in configuration${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}=====================================${NC}"
    echo -e "${YELLOW}Cloudflare WARP Setup${NC}"
    echo -e "${YELLOW}=====================================${NC}"
    echo ""
    
    # Install WireGuard if not present
    if ! command -v wg &> /dev/null; then
        echo -e "${YELLOW}Installing WireGuard tools...${NC}"
        apt-get update -qq
        apt-get install -y wireguard-tools
        echo -e "${GREEN}✓ WireGuard tools installed${NC}"
    else
        echo -e "${GREEN}WireGuard tools already installed${NC}"
    fi
    
    # Install wgcf
    if ! command -v wgcf &> /dev/null; then
        install_wgcf || {
            echo -e "${RED}✗ Failed to install wgcf${NC}"
            return 1
        }
    fi
    
    # Setup configuration with license key
    setup_wgcf_config "$license_key" || {
        echo -e "${RED}✗ Failed to setup WARP configuration${NC}"
        return 1
    }
    
    # Update Xray config
    update_xray_warp_config || {
        echo -e "${RED}✗ Failed to update Xray configuration${NC}"
        return 1
    }
    
    # Test connection
    echo ""
    echo -e "${YELLOW}Testing WARP connection...${NC}"
    test_warp_connection
    
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}WARP Setup Complete${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo "Configuration summary:"
    echo "  - Config directory: /etc/wireguard/warp/"
    echo "  - Profile: wgcf-profile.conf"
    echo "  - Xray WireGuard outbound: Configured"
    echo "  - License: $([ "$license_key" != "null" ] && echo "WARP+" || echo "Free tier")"
    echo ""
}

# Main execution
if [ $# -eq 0 ]; then
    echo "Usage: $0 <config-file.json>"
    exit 1
fi

CONFIG_FILE=$1
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

CONFIG_JSON=$(cat "$CONFIG_FILE")
setup_warp "$CONFIG_JSON"
