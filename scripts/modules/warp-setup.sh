#!/bin/bash
# Cloudflare WARP Outbound Setup Module

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

# ========== Helper Functions for parsing wgcf-profile.conf ==========
# Get value after '=' sign using awk (more reliable)
get_wg_value() {
    local key=$1
    local file=$2
    awk -F'= ' "/${key}/{print \$2; exit}" "$file" | tr -d '\r'
}

# Get IPv4 address from Address field (handles "ipv4, ipv6" format)
get_wg_address_v4() {
    local file=$1
    get_wg_value "Address" "$file" | tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -E '^[0-9]+\.[0-9]+' | head -n1
}

# Get IPv6 address from Address field
get_wg_address_v6() {
    local file=$1
    get_wg_value "Address" "$file" | tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -E '^[0-9a-fA-F]+:' | head -n1
}

# Get DNS IPv4
get_wg_dns_v4() {
    local file=$1
    get_wg_value "DNS" "$file" | tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -E '^[0-9]+\.[0-9]+' | head -n1
}

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
    [ "$(uname -m)" = "armv7l" ] && arch="armv7"
    
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local version="2.2.29"  # Latest stable version
    local download_url="https://github.com/ViRb3/wgcf/releases/download/v${version}/wgcf_${version}_${os}_${arch}"
    
    echo -e "${YELLOW}Downloading wgcf v${version} from: $download_url${NC}"
    
    if wget -q -O /usr/local/bin/wgcf "$download_url"; then
        chmod +x /usr/local/bin/wgcf
        echo -e "${GREEN}✓ wgcf installed successfully${NC}"
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
    
    # Apply license key if provided (upgrade to WARP+)
    if [ -n "$license_key" ] && [ "$license_key" != "null" ]; then
        echo -e "${YELLOW}Applying WARP+ license key...${NC}"
        # Use wgcf update with --license-key flag (correct method per wgcf docs)
        if wgcf update --license-key "$license_key"; then
            echo -e "${GREEN}✓ WARP+ license applied successfully${NC}"
        else
            echo -e "${YELLOW}⚠ Failed to apply WARP+ license, continuing with free tier${NC}"
            echo -e "${YELLOW}  Make sure the license key is valid and not expired${NC}"
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
    
    # Extract configuration values using helper functions
    local wg_config="wgcf-profile.conf"
    local private_key=$(get_wg_value "PrivateKey" "$wg_config")
    local address_v4=$(get_wg_address_v4 "$wg_config")
    local address_v6=$(get_wg_address_v6 "$wg_config")
    local public_key=$(get_wg_value "PublicKey" "$wg_config")
    local endpoint=$(get_wg_value "Endpoint" "$wg_config")
    
    # Validate extracted values
    if [ -z "$private_key" ] || [ -z "$address_v4" ] || [ -z "$public_key" ] || [ -z "$endpoint" ]; then
        echo -e "${RED}✗ Failed to extract configuration values${NC}"
        echo "  PrivateKey: ${private_key:-MISSING}"
        echo "  Address v4: ${address_v4:-MISSING}"
        echo "  Address v6: ${address_v6:-MISSING}"
        echo "  PublicKey: ${public_key:-MISSING}"
        echo "  Endpoint: ${endpoint:-MISSING}"
        return 1
    fi
    
    # Save to temporary file for Xray configuration
    cat > $AUTOCONF_DIR/warp_config <<EOF
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
    echo "  - Config: $AUTOCONF_DIR/warp_config"
    
    return 0
}

# Update Xray configuration with WARP outbound
update_xray_warp_config() {
    local xray_config="/usr/local/etc/xray/config.json"
    
    if [ ! -f "$AUTOCONF_DIR/warp_config" ]; then
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
    
    private_key=$(jq -r '.private_key' $AUTOCONF_DIR/warp_config)
    address_v4=$(jq -r '.address_v4' $AUTOCONF_DIR/warp_config)
    address_v6=$(jq -r '.address_v6' $AUTOCONF_DIR/warp_config)
    public_key=$(jq -r '.public_key' $AUTOCONF_DIR/warp_config)
    endpoint=$(jq -r '.endpoint' $AUTOCONF_DIR/warp_config)
    mtu=$(jq -r '.mtu //1420' $AUTOCONF_DIR/warp_config)
    
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
       )' "$xray_config" > $AUTOCONF_DIR/xray_config_new.json
    
    if [ $? -eq 0 ]; then
        mv $AUTOCONF_DIR/xray_config_new.json "$xray_config"
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

# Install wireproxy for WARP testing
install_wireproxy() {
    echo -e "${YELLOW}Installing wireproxy...${NC}"
    
    # Check if already installed
    if command -v wireproxy &> /dev/null; then
        echo -e "${GREEN}wireproxy already installed: $(wireproxy --version 2>&1 | head -n1)${NC}"
        return 0
    fi
    
    # Download latest wireproxy
    local arch="amd64"
    [ "$(uname -m)" = "aarch64" ] && arch="arm64"
    [ "$(uname -m)" = "armv7l" ] && arch="armv7"
    
    local os="linux"
    local version="1.0.9"
    local download_url="https://github.com/pufferffish/wireproxy/releases/download/v${version}/wireproxy_${os}_${arch}.tar.gz"
    
    echo -e "${YELLOW}Downloading wireproxy from: $download_url${NC}"
    
    local temp_dir=$(mktemp -d)
    if wget -q -O "${temp_dir}/wireproxy.tar.gz" "$download_url"; then
        tar -xzf "${temp_dir}/wireproxy.tar.gz" -C "${temp_dir}"
        mv "${temp_dir}/wireproxy" /usr/local/bin/wireproxy
        chmod +x /usr/local/bin/wireproxy
        rm -rf "${temp_dir}"
        echo -e "${GREEN}✓ wireproxy installed successfully${NC}"
    else
        rm -rf "${temp_dir}"
        echo -e "${RED}✗ Failed to download wireproxy${NC}"
        return 1
    fi
}

# Test WARP connection using wireproxy
test_warp_connection() {
    echo -e "${YELLOW}Testing WARP connection via wireproxy...${NC}"
    
    local warp_dir="/etc/wireguard/warp"
    local wg_config="${warp_dir}/wgcf-profile.conf"
    local wireproxy_config="${warp_dir}/wireproxy.conf"
    local wireproxy_port="40000"
    local wireproxy_pid=""
    
    # Ensure wgcf config exists
    if [ ! -f "$wg_config" ]; then
        echo -e "${RED}✗ WireGuard config not found: $wg_config${NC}"
        return 1
    fi
    
    # Install wireproxy if not present
    if ! command -v wireproxy &> /dev/null; then
        install_wireproxy || {
            echo -e "${RED}✗ Failed to install wireproxy${NC}"
            return 1
        }
    fi
    
    # Generate wireproxy config from wgcf profile using helper functions
    echo -e "${YELLOW}Generating wireproxy configuration...${NC}"
    
    local private_key=$(get_wg_value "PrivateKey" "$wg_config")
    local address_ipv4=$(get_wg_address_v4 "$wg_config")
    local dns_ipv4=$(get_wg_dns_v4 "$wg_config")
    local public_key=$(get_wg_value "PublicKey" "$wg_config")
    local endpoint=$(get_wg_value "Endpoint" "$wg_config")
    
    # Create wireproxy config
    cat > "$wireproxy_config" <<EOF
[Interface]
PrivateKey = $private_key
Address = $address_ipv4
DNS = ${dns_ipv4:-1.1.1.1}
MTU = 1420

[Peer]
PublicKey = $public_key
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25

[Socks5]
BindAddress = 127.0.0.1:${wireproxy_port}
EOF
    
    echo -e "${GREEN}✓ wireproxy config generated${NC}"
    cat "$wireproxy_config"
    echo ""
    
    # Start wireproxy in background with log output
    local wireproxy_log="${warp_dir}/wireproxy.log"
    echo -e "${YELLOW}Starting wireproxy on port ${wireproxy_port}...${NC}"
    wireproxy -c "$wireproxy_config" > "$wireproxy_log" 2>&1 &
    wireproxy_pid=$!
    
    # Wait for wireproxy to start (may need DNS resolution time)
    sleep 5
    
    # Check if wireproxy is running
    if ! kill -0 "$wireproxy_pid" 2>/dev/null; then
        echo -e "${RED}✗ wireproxy failed to start${NC}"
        echo -e "${YELLOW}Log output:${NC}"
        cat "$wireproxy_log" 2>/dev/null || echo "No log available"
        return 1
    fi
    
    echo -e "${GREEN}✓ wireproxy started (PID: $wireproxy_pid)${NC}"
    
    # Test via curl through wireproxy SOCKS5 proxy
    local test_result
    echo -e "${YELLOW}Testing connection to Cloudflare...${NC}"
    test_result=$(curl -s --max-time 15 --proxy socks5h://127.0.0.1:${wireproxy_port} https://1.1.1.1/cdn-cgi/trace 2>/dev/null || echo "failed")
    
    # Stop wireproxy
    echo -e "${YELLOW}Stopping wireproxy...${NC}"
    kill "$wireproxy_pid" 2>/dev/null
    wait "$wireproxy_pid" 2>/dev/null
    
    # Debug: show raw result
    echo -e "${YELLOW}Curl result:${NC}"
    echo "$test_result"
    echo ""
    
    # Check results
    if echo "$test_result" | grep -q "warp=on"; then
        echo -e "${GREEN}✓ WARP is working!${NC}"
        return 0
    elif echo "$test_result" | grep -q "warp=plus"; then
        echo -e "${GREEN}✓ WARP+ is working!${NC}"
        return 0
    elif echo "$test_result" | grep -q "warp=off"; then
        echo -e "${YELLOW}⚠ Connection successful but WARP is off${NC}"
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
