#!/bin/bash
# Xray Configuration Generator Module
# Supports: XHTTP, gRPC protocols
# 从 autoconf.env 读取所有变量，仅负责配置生成

set -euo pipefail

# Use AUTOCONF_DIR from environment or fallback to /tmp
AUTOCONF_DIR="${AUTOCONF_DIR:-/tmp}"
AUTOCONF_FILE="${AUTOCONF_DIR}/autoconf.env"

# Load auto-generated variables (single source of truth)
if [ -f "$AUTOCONF_FILE" ]; then
    source "$AUTOCONF_FILE"
fi

# Port variables are read from autoconf.env:
# PORT_XHTTP, PORT_GRPC, PORT_WARP_XHTTP, PORT_PROTON_XHTTP

# Create Xray inbound configuration for XHTTP
create_xhttp_inbound() {
    local uuid=$1
    local path=$2
    local domain=$3
    local port=${4:-$PORT_XHTTP}
    local cert_dir="/etc/xray/cert"
    
    cat <<EOF
{
  "tag": "vless-xhttp",
  "port": $port,
  "listen": "::",
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
  }
}
EOF
}

# Create Xray inbound configuration for gRPC
create_grpc_inbound() {
    local uuid=$1
    local service_name=$2
    local domain=$3
    local port=${4:-$PORT_GRPC}
    local cert_dir="/etc/xray/cert"
    
    cat <<EOF
{
  "tag": "vless-grpc",
  "port": $port,
  "listen": "::",
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
  }
}
EOF
}

# Create WARP dedicated XHTTP inbound (for SOCKS5 outbound routing)
create_warp_xhttp_inbound() {
    local uuid=$1
    local path=$2
    local domain=$3
    local port=${4:-$PORT_WARP_XHTTP}
    local cert_dir="/etc/xray/cert"
    
    cat <<EOF
{
  "tag": "warp-xhttp",
  "port": $port,
  "listen": "::",
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
  }
}
EOF
}

# Create Proton VPN dedicated XHTTP inbound (for SOCKS5 outbound routing)
create_proton_xhttp_inbound() {
    local uuid=$1
    local path=$2
    local domain=$3
    local port=${4:-$PORT_PROTON_XHTTP}
    local cert_dir="/etc/xray/cert"
    
    cat <<EOF
{
  "tag": "proton-xhttp",
  "port": $port,
  "listen": "::",
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
  }
}
EOF
}

# Create Xray outbound configuration
create_outbound_config() {
    local warp_enabled=$1
    local proton_enabled=$2
    local warp_socks_address=${3:-127.0.0.1}
    local warp_socks_port=${4:-25344}
    local proton_socks_address=${5:-127.0.0.1}
    local proton_socks_port=${6:-25345}
    
    cat <<EOF
[
  {
    "tag": "direct",
    "protocol": "freedom",
    "settings": {}
  },
EOF

    if [ "$warp_enabled" = "true" ]; then
        cat <<EOF
  {
    "tag": "warp",
    "protocol": "socks",
    "settings": {
      "servers": [
        {
          "address": "$warp_socks_address",
          "port": $warp_socks_port
        }
      ]
    }
  },
EOF
    fi

    if [ "$proton_enabled" = "true" ]; then
        cat <<EOF
  {
    "tag": "proton",
    "protocol": "socks",
    "settings": {
      "servers": [
        {
          "address": "$proton_socks_address",
          "port": $proton_socks_port
        }
      ]
    }
  },
EOF
    fi

    cat <<EOF
  {
    "tag": "block",
    "protocol": "blackhole",
    "settings": {}
  }
]
EOF
}

# Create routing rules
create_routing_rules() {
    local warp_enabled=$1
    local proton_enabled=$2
    local routing_mode=${3:-selective}
    local block_bt=${4:-false}
    
    # Build rules array
    local rules=()
    
    # Proton XHTTP inbound → Proton outbound (1:1 direct binding)
    if [ "$proton_enabled" = "true" ]; then
        rules+=('{"type":"field","inboundTag":["proton-xhttp"],"outboundTag":"proton"}')
    fi
    
    # WARP XHTTP inbound → WARP outbound (1:1 direct binding)
    if [ "$warp_enabled" = "true" ]; then
        rules+=('{"type":"field","inboundTag":["warp-xhttp"],"outboundTag":"warp"}')
    fi
    
    # Blocking rules
    rules+=('{"type":"field","ip":["geoip:private"],"outboundTag":"block"}')
    rules+=('{"type":"field","domain":["geosite:category-ads"],"outboundTag":"block"}')
    
    # BT blocking
    if [ "$block_bt" = "true" ]; then
        rules+=('{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}')
    fi
    
    # WARP routing for selective mode
    if [ "$warp_enabled" = "true" ] && [ "$routing_mode" = "selective" ]; then
        rules+=('{"type":"field","ip":["geoip:cn"],"outboundTag":"warp"}')
        rules+=('{"type":"field","domain":["geosite:cn"],"outboundTag":"warp"}')
        rules+=('{"type":"field","domain":["geosite:netflix","geosite:disney","geosite:hbo","geosite:spotify"],"outboundTag":"warp"}')
    fi
    
    # Join rules with commas
    local rules_json=""
    local first=true
    for rule in "${rules[@]}"; do
        if [ "$first" = true ]; then
            rules_json="$rule"
            first=false
        else
            rules_json="$rules_json,$rule"
        fi
    done
    
    # Output formatted JSON
    echo "{\"domainStrategy\":\"IPIfNonMatch\",\"rules\":[$rules_json]}"
}

# Generate complete Xray configuration
generate_xray_config() {
    local config_json=$1
    
    # Parse configuration
    local xhttp_enabled=$(echo "$config_json" | jq -r '.protocols.xhttp.enabled // true')
    local grpc_enabled=$(echo "$config_json" | jq -r '.protocols.grpc.enabled // true')
    local warp_enabled=$(echo "$config_json" | jq -r '.warp_outbound.enabled // false')
    local proton_enabled=$(echo "$config_json" | jq -r '.proton_outbound.enabled // false')
    local routing_mode=$(echo "$config_json" | jq -r '.warp_outbound.routing_mode // "selective"')
    local block_bt=$(echo "$config_json" | jq -r '.warp_outbound.block_bt // false')
    
    # WARP SOCKS5 settings
    local warp_socks_address=$(echo "$config_json" | jq -r '.warp_outbound.socks_address // "127.0.0.1"')
    local warp_socks_port=$(echo "$config_json" | jq -r '.warp_outbound.socks_port // 25344')
    
    # Proton SOCKS5 settings
    local proton_socks_address=$(echo "$config_json" | jq -r '.proton_outbound.socks_address // "127.0.0.1"')
    local proton_socks_port=$(echo "$config_json" | jq -r '.proton_outbound.socks_port // 25345')
    
    # Read from autoconf.env
    local xhttp_uuid="${UUID_XHTTP:-}"
    local grpc_uuid="${UUID_GRPC:-}"
    local xhttp_path="${XHTTP_PATH:-}"
    local grpc_service="${GRPC_SERVICE_NAME:-}"
    local xhttp_domain="${DOMAIN_XHTTP:-}"
    local grpc_domain="${DOMAIN_GRPC:-}"
    local warp_domain="${DOMAIN_WARP:-}"
    local warp_path="${WARP_PATH:-/warp}"
    local proton_domain="${DOMAIN_PROTON:-}"
    local proton_path="${PROTON_PATH:-/proton}"
    
    # Validate
    if [ -z "$xhttp_uuid" ] || [ -z "$grpc_uuid" ]; then
        echo "ERROR: Required variables not found in autoconf.env. Run auto-generate.sh first." >&2
        exit 1
    fi
    
    # Build inbounds array
    local inbounds="["
    local first=true
    
    if [ "$xhttp_enabled" = "true" ]; then
        [ "$first" = false ] && inbounds+=","
        inbounds+=$(create_xhttp_inbound "$xhttp_uuid" "$xhttp_path" "$xhttp_domain")
        first=false
    fi
    
    if [ "$grpc_enabled" = "true" ]; then
        [ "$first" = false ] && inbounds+=","
        inbounds+=$(create_grpc_inbound "$grpc_uuid" "$grpc_service" "$grpc_domain")
        first=false
    fi
    
    if [ "$warp_enabled" = "true" ]; then
        [ "$first" = false ] && inbounds+=","
        inbounds+=$(create_warp_xhttp_inbound "$xhttp_uuid" "$warp_path" "$warp_domain")
        first=false
    fi
    
    if [ "$proton_enabled" = "true" ]; then
        [ "$first" = false ] && inbounds+=","
        inbounds+=$(create_proton_xhttp_inbound "$xhttp_uuid" "$proton_path" "$proton_domain")
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
  "outbounds": $(create_outbound_config "$warp_enabled" "$proton_enabled" "$warp_socks_address" "$warp_socks_port" "$proton_socks_address" "$proton_socks_port"),
  "routing": $(create_routing_rules "$warp_enabled" "$proton_enabled" "$routing_mode" "$block_bt")
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
