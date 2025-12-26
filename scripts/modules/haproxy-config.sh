#!/bin/bash
# HAProxy Configuration Generator Module
# SNI-based routing for XHTTP, gRPC, WARP, Subscription, code-server
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
# PORT_XHTTP, PORT_GRPC, PORT_WARP_XHTTP, PORT_NGINX, PORT_CODE_SERVER, PORT_HAPROXY_STATS

# Create HAProxy frontend configuration
create_frontend_config() {
    local frontend_port=$1
    local xhttp_enabled=$2
    local grpc_enabled=$3
    local sub_enabled=$4
    local code_server_enabled=$5
    local warp_enabled=$6
    local proton_enabled=$7
    
    # Read domains from autoconf.env
    local xhttp_domain="${DOMAIN_XHTTP:-}"
    local grpc_domain="${DOMAIN_GRPC:-}"
    local sub_domain="${SUBSCRIPTION_DOMAIN:-}"
    local code_server_domain="${DOMAIN_CODE_SERVER:-}"
    local warp_domain="${DOMAIN_WARP:-}"
    local proton_domain="${DOMAIN_PROTON:-}"
    local stats_user="${HAPROXY_STATS_USER:-admin}"
    local stats_pass="${HAPROXY_STATS_PASSWORD:-}"
    
    local frontend_rules=""
    
    # Build SNI routing rules
    [ "$xhttp_enabled" = "true" ] && [ -n "$xhttp_domain" ] && frontend_rules+="
    use_backend xhttp_backend if { req_ssl_sni -i ${xhttp_domain} }"
    [ "$grpc_enabled" = "true" ] && [ -n "$grpc_domain" ] && frontend_rules+="
    use_backend grpc_backend if { req_ssl_sni -i ${grpc_domain} }"
    [ "$sub_enabled" = "true" ] && [ -n "$sub_domain" ] && frontend_rules+="
    use_backend subscription_backend if { req_ssl_sni -i ${sub_domain} }"
    [ "$code_server_enabled" = "true" ] && [ -n "$code_server_domain" ] && frontend_rules+="
    use_backend code_server_backend if { req_ssl_sni -i ${code_server_domain} }"
    [ "$warp_enabled" = "true" ] && [ -n "$warp_domain" ] && frontend_rules+="
    use_backend warp_backend if { req_ssl_sni -i ${warp_domain} }"
    [ "$proton_enabled" = "true" ] && [ -n "$proton_domain" ] && frontend_rules+="
    use_backend proton_backend if { req_ssl_sni -i ${proton_domain} }"
    
    cat <<EOF
frontend https_frontend
    bind 0.0.0.0:$frontend_port
    bind [::]:$frontend_port
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    
    # SNI-based routing${frontend_rules}
    
    # Reject unknown SNI
    default_backend reject_backend

# Stats interface (localhost only)
frontend stats
    bind 127.0.0.1:$PORT_HAPROXY_STATS
    bind [::1]:$PORT_HAPROXY_STATS
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats auth ${stats_user}:${stats_pass}
EOF
}

# Create backend configurations
create_backends_config() {
    local xhttp_enabled=$1
    local grpc_enabled=$2
    local sub_enabled=$3
    local code_server_enabled=$4
    local warp_enabled=$5
    local proton_enabled=$6
    
    cat <<EOF

# Reject backend for unknown SNI
backend reject_backend
    mode tcp
    timeout server 1s
    server reject 127.0.0.1:1 send-proxy
EOF
    
    if [ "$xhttp_enabled" = "true" ]; then
        cat <<EOF

# XHTTP backend
backend xhttp_backend
    mode tcp
    server xray_xhttp 127.0.0.1:$PORT_XHTTP check inter 30s
EOF
    fi
    
    if [ "$grpc_enabled" = "true" ]; then
        cat <<EOF

# gRPC backend
backend grpc_backend
    mode tcp
    server xray_grpc 127.0.0.1:$PORT_GRPC check inter 30s
EOF
    fi
    
    if [ "$sub_enabled" = "true" ]; then
        cat <<EOF

# Subscription backend
backend subscription_backend
    mode tcp
    server nginx_sub 127.0.0.1:$PORT_NGINX check inter 30s
EOF
    fi
    
    if [ "$code_server_enabled" = "true" ]; then
        cat <<EOF

# code-server backend
backend code_server_backend
    mode tcp
    server code_server 127.0.0.1:$PORT_CODE_SERVER check inter 30s
EOF
    fi
    
    if [ "$warp_enabled" = "true" ]; then
        cat <<EOF

# WARP XHTTP backend
backend warp_backend
    mode tcp
    server xray_warp 127.0.0.1:$PORT_WARP_XHTTP check inter 30s
EOF
    fi
    
    if [ "$proton_enabled" = "true" ]; then
        cat <<EOF

# Proton VPN XHTTP backend
backend proton_backend
    mode tcp
    server xray_proton 127.0.0.1:$PORT_PROTON_XHTTP check inter 30s
EOF
    fi
}

# Generate complete HAProxy configuration
generate_haproxy_config() {
    local config_json=$1
    
    # Parse configuration
    local frontend_port=$(echo "$config_json" | jq -r '.haproxy.frontend_port // 443')
    
    # Get enabled states
    local xhttp_enabled=$(echo "$config_json" | jq -r '.protocols.xhttp.enabled // true')
    local grpc_enabled=$(echo "$config_json" | jq -r '.protocols.grpc.enabled // true')
    local sub_enabled=$(echo "$config_json" | jq -r '.subscription.enabled // false')
    local code_server_enabled=$(echo "$config_json" | jq -r '.code_server.enabled // false')
    local warp_enabled=$(echo "$config_json" | jq -r '.warp_outbound.enabled // false')
    local proton_enabled=$(echo "$config_json" | jq -r '.proton_outbound.enabled // false')
    
    cat <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    
    # Performance tuning
    tune.bufsize 32768
    tune.maxrewrite 1024
    tune.ssl.default-dh-param 2048

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5000
    timeout client  50000
    timeout server  50000

$(create_frontend_config "$frontend_port" "$xhttp_enabled" "$grpc_enabled" "$sub_enabled" "$code_server_enabled" "$warp_enabled" "$proton_enabled")

$(create_backends_config "$xhttp_enabled" "$grpc_enabled" "$sub_enabled" "$code_server_enabled" "$warp_enabled" "$proton_enabled")
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
generate_haproxy_config "$CONFIG_JSON"
