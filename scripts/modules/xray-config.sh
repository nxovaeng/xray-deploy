#!/bin/bash
# Xray Configuration Generator Module
# Supports: Reality, XHTTP, gRPC, Trojan protocols

set -euo pipefail

# Use AUTOCONF_DIR from environment or fallback to /tmp
AUTOCONF_DIR="${AUTOCONF_DIR:-/tmp}"

# Generate UUID for VLESS
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# Generate Reality keys using xray x25519
generate_reality_keys() {
    local keys_output
    keys_output=$(/usr/local/bin/xray x25519 2>&1)
    
    local private_key=""
    local public_key=""
    
    # Parse PrivateKey (works with "PrivateKey: xxx" or "Private key: xxx")
    private_key=$(echo "$keys_output" | grep -i "private" | sed 's/^[^:]*://' | tr -d ' \r\n')
    
    # Try to parse PublicKey first, then fall back to "Password" field (newer xray format)
    public_key=$(echo "$keys_output" | grep -i "public" | sed 's/^[^:]*://' | tr -d ' \r\n')
    
    # If no PublicKey found, try Password field (some xray versions use this for public key)
    if [ -z "$public_key" ]; then
        public_key=$(echo "$keys_output" | grep -i "password" | sed 's/^[^:]*://' | tr -d ' \r\n')
    fi
    
    # If still no public key, try to derive it from private key
    if [ -z "$public_key" ] && [ -n "$private_key" ]; then
        local derived
        derived=$(/usr/local/bin/xray x25519 -i "$private_key" 2>&1)
        public_key=$(echo "$derived" | grep -i "public" | sed 's/^[^:]*://' | tr -d ' \r\n')
        # Also try Password field
        if [ -z "$public_key" ]; then
            public_key=$(echo "$derived" | grep -i "password" | sed 's/^[^:]*://' | tr -d ' \r\n')
        fi
    fi
    
    # Validate keys
    if [ -z "$private_key" ] || [ ${#private_key} -lt 40 ]; then
        echo "ERROR: Failed to generate Reality private key" >&2
        echo "ERROR: xray output: $keys_output" >&2
        exit 1
    fi
    
    if [ -z "$public_key" ] || [ ${#public_key} -lt 40 ]; then
        echo "ERROR: Failed to generate Reality public key" >&2
        echo "ERROR: xray output: $keys_output" >&2
        exit 1
    fi
    
    echo "$private_key|$public_key"
}

# Generate short ID for Reality
generate_short_id() {
    openssl rand -hex 8
}

# Create Xray inbound configuration for Reality
create_reality_inbound() {
    local uuid=$1
    local port=$2
    local dest=$3
    local server_names=$4  # JSON array string
    
    # Generate Reality keys
    local keys
    keys=$(generate_reality_keys)
    local private_key
    local public_key
    private_key=$(echo "$keys" | cut -d'|' -f1)
    public_key=$(echo "$keys" | cut -d'|' -f2)
    
    # Validate keys before proceeding
    if [ -z "$private_key" ] || [ ${#private_key} -lt 40 ]; then
        echo "ERROR: private_key is empty or invalid in create_reality_inbound" >&2
        exit 1
    fi
    
    # Generate short IDs
    local short_id1
    local short_id2
    short_id1=$(generate_short_id)
    short_id2=$(generate_short_id)
    
    cat <<EOF
{
  "tag": "vless-reality",
  "port": $port,
  "listen": "0.0.0.0",
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$uuid",
        "flow": "xtls-rprx-vision"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "dest": "$dest",
      "serverNames": $server_names,
      "privateKey": "$private_key",
      "shortIds": ["$short_id1", "$short_id2"]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": true
  }
}
EOF

    # Store public key for client configuration
    echo "$public_key" > $AUTOCONF_DIR/reality_public_key
    echo "$short_id1" > $AUTOCONF_DIR/reality_short_id
}

# Create Xray inbound configuration for XHTTP
create_xhttp_inbound() {
    local uuid=$1
    local port=$2
    local path=$3
    local domain=$4
    local cert_dir="/etc/xray/cert"
    
    cat <<EOF
{
  "tag": "vless-xhttp",
  "port": $port,
  "listen": "127.0.0.1",
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$uuid",
        "flow": ""
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "${cert_dir}/fullchain.pem",
          "keyFile": "${cert_dir}/privkey.pem"
        }
      ],
      "alpn": ["h2", "http/1.1"],
      "serverName": "$domain"
    },
    "xhttpSettings": {
      "path": "$path",
      "mode": "auto"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": true
  }
}
EOF
}

# Create Xray inbound configuration for gRPC
create_grpc_inbound() {
    local uuid=$1
    local port=$2
    local service_name=$3
    local domain=$4
    local cert_dir="/etc/xray/cert"
    
    cat <<EOF
{
  "tag": "vless-grpc",
  "port": $port,
  "listen": "127.0.0.1",
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$uuid"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "grpc",
    "security": "tls",
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "${cert_dir}/fullchain.pem",
          "keyFile": "${cert_dir}/privkey.pem"
        }
      ],
      "alpn": ["h2"]
    },
    "grpcSettings": {
      "serviceName": "$service_name",
      "multiMode": false,
      "initial_windows_size": 65536
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": true
  }
}
EOF
}

# Create Xray inbound configuration for Trojan
create_trojan_inbound() {
    local password=$1
    local port=$2
    local domain=$3
    local cert_dir="/etc/xray/cert"
    
    cat <<EOF
{
  "tag": "trojan-tcp",
  "port": $port,
  "listen": "127.0.0.1",
  "protocol": "trojan",
  "settings": {
    "clients": [
      {
        "password": "$password",
        "email": "user@trojan"
      }
    ]
  },
  "streamSettings": {
    "network": "tcp",
    "security": "tls",
    "tlsSettings": {
      "certificates": [
        {
          "certificateFile": "${cert_dir}/fullchain.pem",
          "keyFile": "${cert_dir}/privkey.pem"
        }
      ],
      "alpn": ["http/1.1"]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"]
  }
}
EOF
}

# Create Xray outbound configuration
create_outbound_config() {
    local warp_enabled=$1
    
    if [ "$warp_enabled" = "true" ]; then
        cat <<EOF
[
  {
    "tag": "direct",
    "protocol": "freedom",
    "settings": {}
  },
  {
    "tag": "warp",
    "protocol": "wireguard",
    "settings": {
      "secretKey": "WARP_PRIVATE_KEY",
      "address": ["172.16.0.2/32", "2606:4700:110:8::1/128"],
      "peers": [
        {
          "publicKey": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
          "endpoint": "engage.cloudflareclient.com:2408"
        }
      ]
    }
  },
  {
    "tag": "block",
    "protocol": "blackhole",
    "settings": {}
  }
]
EOF
    else
        cat <<EOF
[
  {
    "tag": "direct",
    "protocol": "freedom",
    "settings": {}
  },
  {
    "tag": "block",
    "protocol": "blackhole",
    "settings": {}
  }
]
EOF
    fi
}

# Create routing rules
create_routing_rules() {
    local warp_enabled=$1
    local routing_mode=$2
    local block_bt=$3
    
    # Default values
    [ -z "$routing_mode" ] && routing_mode="selective"
    [ -z "$block_bt" ] && block_bt="false"
    
    if [ "$warp_enabled" = "true" ]; then
        # Build rules array based on mode
        local rules_json=""
        
        # Common blocking rules (always first)
        rules_json+='{
      "type": "field",
      "ip": ["geoip:private"],
      "outboundTag": "block"
    },
    {
      "type": "field",
      "domain": ["geosite:category-ads"],
      "outboundTag": "block"
    }'
        
        # BT protocol blocking (if enabled)
        if [ "$block_bt" = "true" ]; then
            rules_json+=',
    {
      "type": "field",
      "protocol": ["bittorrent"],
      "outboundTag": "block"
    }'
        fi
        
        # Routing mode-specific rules
        if [ "$routing_mode" = "selective" ]; then
            # Selective mode: CN IPs/domains + streaming → WARP, others → direct
            rules_json+=',
    {
      "type": "field",
      "ip": ["geoip:cn"],
      "outboundTag": "warp"
    },
    {
      "type": "field",
      "domain": ["geosite:cn"],
      "outboundTag": "warp"
    },
    {
      "type": "field",
      "domain": ["geosite:netflix", "geosite:disney", "geosite:hbo", "geosite:spotify"],
      "outboundTag": "warp"
    },
    {
      "type": "field",
      "network": "tcp,udp",
      "outboundTag": "direct"
    }'
        elif [ "$routing_mode" = "all" ]; then
            # All mode: everything → WARP
            rules_json+=',
    {
      "type": "field",
      "network": "tcp,udp",
      "outboundTag": "warp"
    }'
        fi
        
        cat <<EOF
{
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    $rules_json
  ]
}
EOF
    else
        # WARP disabled: block private IPs and ads only
        local rules_json='{
      "type": "field",
      "ip": ["geoip:private"],
      "outboundTag": "block"
    },
    {
      "type": "field",
      "domain": ["geosite:category-ads"],
      "outboundTag": "block"
    }'
        
        if [ "$block_bt" = "true" ]; then
            rules_json+=',
    {
      "type": "field",
      "protocol": ["bittorrent"],
      "outboundTag": "block"
    }'
        fi
        
        cat <<EOF
{
  "domainStrategy": "IPIfNonMatch",
  "rules": [
    $rules_json
  ]
}
EOF
    fi
}

# Generate complete Xray configuration
generate_xray_config() {
    local config_json=$1
    
    # Parse configuration
    local reality_enabled
    local xhttp_enabled
    local grpc_enabled
    local trojan_enabled
    local warp_enabled
    local routing_mode
    local block_bt
    
    reality_enabled=$(echo "$config_json" | jq -r '.protocols.reality.enabled')
    xhttp_enabled=$(echo "$config_json" | jq -r '.protocols.xhttp.enabled')
    grpc_enabled=$(echo "$config_json" | jq -r '.protocols.grpc.enabled')
    trojan_enabled=$(echo "$config_json" | jq -r '.protocols.trojan.enabled')
    warp_enabled=$(echo "$config_json" | jq -r '.warp_outbound.enabled')
    routing_mode=$(echo "$config_json" | jq -r '.warp_outbound.routing_mode // "selective"')
    block_bt=$(echo "$config_json" | jq -r '.warp_outbound.block_bt // false')
    
    # Generate UUIDs if needed
    local reality_uuid
    local xhttp_uuid
    local grpc_uuid
    local trojan_password
    
    reality_uuid=$(generate_uuid)
    xhttp_uuid=$(generate_uuid)
    grpc_uuid=$(generate_uuid)
    trojan_password=$(openssl rand -base64 16)
    
    # Store UUIDs for subscription generation
    echo "$reality_uuid" > $AUTOCONF_DIR/uuid_reality
    echo "$xhttp_uuid" > $AUTOCONF_DIR/uuid_xhttp
    echo "$grpc_uuid" > $AUTOCONF_DIR/uuid_grpc
    echo "$trojan_password" > $AUTOCONF_DIR/password_trojan
    
    # Build inbounds array
    local inbounds="["
    local first=true
    
    if [ "$reality_enabled" = "true" ]; then
        local reality_port
        local reality_dest
        local reality_sns
        reality_port=$(echo "$config_json" | jq -r '.protocols.reality.port')
        reality_dest=$(echo "$config_json" | jq -r '.protocols.reality.dest')
        reality_sns=$(echo "$config_json" | jq -c '.protocols.reality.server_names')
        
        [ "$first" = false ] && inbounds+=","
        inbounds+=$(create_reality_inbound "$reality_uuid" "$reality_port" "$reality_dest" "$reality_sns")
        first=false
    fi
    
    if [ "$xhttp_enabled" = "true" ]; then
        local xhttp_port
        local xhttp_path
        local xhttp_domain
        xhttp_port=$(echo "$config_json" | jq -r '.protocols.xhttp.port')
        xhttp_path=$(echo "$config_json" | jq -r '.protocols.xhttp.path')
        # Read from haproxy_env (generated by haproxy-config.sh) or fallback to wildcard_base
        xhttp_domain=$(grep "^XHTTP_DOMAIN=" $AUTOCONF_DIR/haproxy_env 2>/dev/null | cut -d= -f2 || echo "")
        [ -z "$xhttp_domain" ] && xhttp_domain=$(echo "$config_json" | jq -r '.domains.wildcard_base // "xhttp.example.com"')
        
        [ "$first" = false ] && inbounds+=","
        inbounds+=$(create_xhttp_inbound "$xhttp_uuid" "$xhttp_port" "$xhttp_path" "$xhttp_domain")
        first=false
    fi
    
    if [ "$grpc_enabled" = "true" ]; then
        local grpc_port
        local grpc_service
        local grpc_domain
        grpc_port=$(echo "$config_json" | jq -r '.protocols.grpc.port')
        grpc_service=$(echo "$config_json" | jq -r '.protocols.grpc.service_name')
        # Read from haproxy_env (generated by haproxy-config.sh) or fallback to wildcard_base
        grpc_domain=$(grep "^GRPC_DOMAIN=" $AUTOCONF_DIR/haproxy_env 2>/dev/null | cut -d= -f2 || echo "")
        [ -z "$grpc_domain" ] && grpc_domain=$(echo "$config_json" | jq -r '.domains.wildcard_base // "grpc.example.com"')
        
        [ "$first" = false ] && inbounds+=","
        inbounds+=$(create_grpc_inbound "$grpc_uuid" "$grpc_port" "$grpc_service" "$grpc_domain")
        first=false
    fi
    
    if [ "$trojan_enabled" = "true" ]; then
        local trojan_port
        local trojan_domain
        trojan_port=$(echo "$config_json" | jq -r '.protocols.trojan.port')
        # Read from haproxy_env (generated by haproxy-config.sh) or fallback to wildcard_base
        trojan_domain=$(grep "^TROJAN_DOMAIN=" $AUTOCONF_DIR/haproxy_env 2>/dev/null | cut -d= -f2 || echo "")
        [ -z "$trojan_domain" ] && trojan_domain=$(echo "$config_json" | jq -r '.domains.wildcard_base // "trojan.example.com"')
        
        [ "$first" = false ] && inbounds+=","
        inbounds+=$(create_trojan_inbound "$trojan_password" "$trojan_port" "$trojan_domain")
        first=false
    fi
    
    inbounds+="]"
    
    # Generate complete config
    cat <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": $inbounds,
  "outbounds": $(create_outbound_config "$warp_enabled"),
  "routing": $(create_routing_rules "$warp_enabled" "$routing_mode" "$block_bt")
}
EOF
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
generate_xray_config "$CONFIG_JSON"
