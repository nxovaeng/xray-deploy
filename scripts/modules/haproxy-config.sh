#!/bin/bash
# HAProxy Configuration Generator Module
# SNI-based routing for multiple protocols
# 从 autoconf.env 读取所有变量，仅负责配置生成

set -euo pipefail

# Use AUTOCONF_DIR from environment or fallback to /tmp
AUTOCONF_DIR="${AUTOCONF_DIR:-/tmp}"
AUTOCONF_FILE="${AUTOCONF_DIR}/autoconf.env"

# Load auto-generated variables (single source of truth)
if [ -f "$AUTOCONF_FILE" ]; then
    source "$AUTOCONF_FILE"
fi

# Create HAProxy frontend configuration
# Arguments: frontend_port, stats_port, xhttp_enabled, grpc_enabled, trojan_enabled, sub_enabled
create_frontend_config() {
    local frontend_port=$1
    local stats_port=$2
    local xhttp_enabled=$3
    local grpc_enabled=$4
    local trojan_enabled=$5
    local sub_enabled=$6
    
    # Read domains from autoconf.env (single source of truth)
    local xhttp_domain="${DOMAIN_XHTTP:-}"
    local grpc_domain="${DOMAIN_GRPC:-}"
    local trojan_domain="${DOMAIN_TROJAN:-}"
    local sub_domain="${SUBSCRIPTION_DOMAIN:-}"
    local stats_user="${HAPROXY_STATS_USER:-admin}"
    local stats_pass="${HAPROXY_STATS_PASSWORD:-}"
    
    local frontend_rules=""
    
    # Build SNI routing rules only for enabled protocols (use actual values)
    [ "$xhttp_enabled" = "true" ] && [ -n "$xhttp_domain" ] && frontend_rules+="
    use_backend xhttp_backend if { req_ssl_sni -i ${xhttp_domain} }"
    [ "$grpc_enabled" = "true" ] && [ -n "$grpc_domain" ] && frontend_rules+="
    use_backend grpc_backend if { req_ssl_sni -i ${grpc_domain} }"
    [ "$trojan_enabled" = "true" ] && [ -n "$trojan_domain" ] && frontend_rules+="
    use_backend trojan_backend if { req_ssl_sni -i ${trojan_domain} }"
    [ "$sub_enabled" = "true" ] && [ -n "$sub_domain" ] && frontend_rules+="
    use_backend subscription_backend if { req_ssl_sni -i ${sub_domain} }"
    
    cat <<EOF
frontend https_frontend
    bind 0.0.0.0:$frontend_port
    bind [::]:$frontend_port
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    
    # SNI-based routing (only for enabled protocols)${frontend_rules}
    
    # Reject unknown SNI (Reality uses separate port, not through HAProxy)
    default_backend reject_backend

# Stats interface (dual-stack)
frontend stats
    bind 127.0.0.1:$stats_port
    bind [::1]:$stats_port
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats auth ${stats_user}:${stats_pass}
EOF
}

# Create backend configurations
# Arguments: xhttp_port, grpc_port, trojan_port, nginx_port, xhttp_enabled, grpc_enabled, trojan_enabled, sub_enabled
create_backends_config() {
    local xhttp_port=$1
    local grpc_port=$2
    local trojan_port=$3
    local nginx_port=$4
    local xhttp_enabled=$5
    local grpc_enabled=$6
    local trojan_enabled=$7
    local sub_enabled=$8
    
    # Always output reject backend
    cat <<EOF

# Reject backend for unknown SNI
backend reject_backend
    mode tcp
    timeout server 1s
    server reject 127.0.0.1:1 send-proxy
EOF
    
    # Conditionally output backends
    if [ "$xhttp_enabled" = "true" ]; then
        cat <<EOF

# XHTTP backend (TCP passthrough - Xray handles TLS)
backend xhttp_backend
    mode tcp
    server xray_xhttp 127.0.0.1:$xhttp_port check inter 30s
EOF
    fi
    
    if [ "$grpc_enabled" = "true" ]; then
        cat <<EOF

# gRPC backend (TCP passthrough - Xray handles TLS)
backend grpc_backend
    mode tcp
    server xray_grpc 127.0.0.1:$grpc_port check inter 30s
EOF
    fi
    
    if [ "$trojan_enabled" = "true" ]; then
        cat <<EOF

# Trojan backend (TCP passthrough - Xray handles TLS)
backend trojan_backend
    mode tcp
    server xray_trojan 127.0.0.1:$trojan_port check inter 30s
EOF
    fi
    
    if [ "$sub_enabled" = "true" ]; then
        cat <<EOF

# Subscription backend (TCP passthrough - Nginx handles TLS)
backend subscription_backend
    mode tcp
    server nginx_sub 127.0.0.1:$nginx_port check inter 30s
EOF
    fi
}

# Generate complete HAProxy configuration
generate_haproxy_config() {
    local config_json=$1
    
    # Parse configuration
    local frontend_port
    local stats_port
    local stats_user
    local stats_pass
    
    frontend_port=$(echo "$config_json" | jq -r '.haproxy.frontend_port // 443')
    stats_port=$(echo "$config_json" | jq -r '.haproxy.stats_port // 2053')
    local stats_user="$HAPROXY_STATS_USER"
    local stats_pass="$HAPROXY_STATS_PASSWORD"
    
    # Get protocol enabled states
    local xhttp_enabled
    local grpc_enabled
    local trojan_enabled
    local sub_enabled
    
    xhttp_enabled=$(echo "$config_json" | jq -r '.protocols.xhttp.enabled // false')
    grpc_enabled=$(echo "$config_json" | jq -r '.protocols.grpc.enabled // false')
    trojan_enabled=$(echo "$config_json" | jq -r '.protocols.trojan.enabled // false')
    sub_enabled=$(echo "$config_json" | jq -r '.subscription.enabled // false')
    
    # Get protocol ports
    local xhttp_port
    local grpc_port
    local trojan_port
    local nginx_port
    
    xhttp_port=$(echo "$config_json" | jq -r '.protocols.xhttp.port // 8443')
    grpc_port=$(echo "$config_json" | jq -r '.protocols.grpc.port // 2083')
    trojan_port=$(echo "$config_json" | jq -r '.protocols.trojan.port // 2087')
    nginx_port=$(echo "$config_json" | jq -r '.subscription.nginx_port // 2096')
    
    # Domains are read directly from autoconf.env in create_frontend_config()
    
    # Generate configuration
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
    
    # Default SSL material locations
    ca-base /etc/ssl/certs
    crt-base /etc/ssl/private
    
    # Increase buffer size for better performance
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

$(create_frontend_config "$frontend_port" "$stats_port" "$xhttp_enabled" "$grpc_enabled" "$trojan_enabled" "$sub_enabled")

$(create_backends_config "$xhttp_port" "$grpc_port" "$trojan_port" "$nginx_port" "$xhttp_enabled" "$grpc_enabled" "$trojan_enabled" "$sub_enabled")
EOF
    
    # NOTE: Previously this script wrote a separate "$AUTOCONF_DIR/haproxy_env" file
    # for downstream consumption. That is redundant: all auto-generated variables
    # are centralized in "$AUTOCONF_FILE" (autoconf.env). Other modules read
    # DOMAIN_* and HAPROXY_STATS_* from autoconf.env directly.
    # No additional file is written here to avoid duplication.
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
