#!/bin/bash
# HAProxy Configuration Generator Module
# SNI-based routing for multiple protocols with random subdomain support

set -euo pipefail

# Use AUTOCONF_DIR from environment or fallback to /tmp
AUTOCONF_DIR="${AUTOCONF_DIR:-/tmp}"

# Generate random subdomain (5 characters, lowercase alphanumeric)
generate_random_subdomain() {
    # Use openssl to avoid SIGPIPE from head closing the pipe early
    openssl rand -hex 3 | head -c 5
}

# Generate HAProxy stats password
generate_stats_password() {
    openssl rand -base64 12
}

# Create HAProxy frontend configuration
# Arguments: frontend_port, stats_port, xhttp_enabled, grpc_enabled, trojan_enabled, sub_enabled
create_frontend_config() {
    local frontend_port=$1
    local stats_port=$2
    local xhttp_enabled=$3
    local grpc_enabled=$4
    local trojan_enabled=$5
    local sub_enabled=$6
    
    local frontend_rules=""
    
    # Build SNI routing rules only for enabled protocols
    [ "$xhttp_enabled" = "true" ] && frontend_rules+="
    use_backend xhttp_backend if { req_ssl_sni -i \$XHTTP_DOMAIN }"
    [ "$grpc_enabled" = "true" ] && frontend_rules+="
    use_backend grpc_backend if { req_ssl_sni -i \$GRPC_DOMAIN }"
    [ "$trojan_enabled" = "true" ] && frontend_rules+="
    use_backend trojan_backend if { req_ssl_sni -i \$TROJAN_DOMAIN }"
    [ "$sub_enabled" = "true" ] && frontend_rules+="
    use_backend subscription_backend if { req_ssl_sni -i \$SUB_DOMAIN }"
    
    cat <<EOF
frontend https_frontend
    bind *:$frontend_port
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    
    # SNI-based routing (only for enabled protocols)${frontend_rules}
    
    # Reject unknown SNI (Reality uses separate port, not through HAProxy)
    default_backend reject_backend

# Stats interface (proxied via Nginx HTTPS)
frontend stats
    bind 127.0.0.1:$stats_port
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
    stats auth \$STATS_USER:\$STATS_PASS
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
    stats_user=$(echo "$config_json" | jq -r '.haproxy.stats_user // "admin"')
    stats_pass=$(echo "$config_json" | jq -r '.haproxy.stats_password')
    
    if [ "$stats_pass" = "auto-generate" ] || [ "$stats_pass" = "null" ]; then
        stats_pass=$(generate_stats_password)
        echo "$stats_pass" > $AUTOCONF_DIR/haproxy_stats_password
    fi
    
    # Get protocol enabled states
    local xhttp_enabled
    local grpc_enabled
    local trojan_enabled
    local sub_enabled
    
    xhttp_enabled=$(echo "$config_json" | jq -r '.protocols.xhttp.enabled // false')
    grpc_enabled=$(echo "$config_json" | jq -r '.protocols.grpc.enabled // false')
    trojan_enabled=$(echo "$config_json" | jq -r '.protocols.trojan.enabled // false')
    sub_enabled=$(echo "$config_json" | jq -r '.subscription.enabled // false')
    
    # Get protocol ports (Reality uses direct access, not through HAProxy)
    local xhttp_port
    local grpc_port
    local trojan_port
    local nginx_port
    
    xhttp_port=$(echo "$config_json" | jq -r '.protocols.xhttp.port // 8443')
    grpc_port=$(echo "$config_json" | jq -r '.protocols.grpc.port // 2083')
    trojan_port=$(echo "$config_json" | jq -r '.protocols.trojan.port // 2087')
    nginx_port=$(echo "$config_json" | jq -r '.subscription.nginx_port // 2096')
    
    # Get base domain for random subdomains
    local wildcard_base
    local sub_domain
    wildcard_base=$(echo "$config_json" | jq -r '.domains.wildcard_base')
    sub_domain=$(echo "$config_json" | jq -r '.domains.subscription')
    
    # Generate random subdomains or use configured ones (only for enabled protocols)
    local xhttp_domain=""
    local grpc_domain=""
    local trojan_domain=""
    
    if [ "$wildcard_base" != "null" ]; then
        [ "$xhttp_enabled" = "true" ] && xhttp_domain="$(generate_random_subdomain).${wildcard_base}"
        [ "$grpc_enabled" = "true" ] && grpc_domain="$(generate_random_subdomain).${wildcard_base}"
        [ "$trojan_enabled" = "true" ] && trojan_domain="$(generate_random_subdomain).${wildcard_base}"
    else
        # Use configured domains (backward compatibility)
        [ "$xhttp_enabled" = "true" ] && xhttp_domain=$(echo "$config_json" | jq -r '.domains.xhttp // "xhttp.example.com"')
        [ "$grpc_enabled" = "true" ] && grpc_domain=$(echo "$config_json" | jq -r '.domains.grpc // "grpc.example.com"')
        [ "$trojan_enabled" = "true" ] && trojan_domain=$(echo "$config_json" | jq -r '.domains.trojan // "trojan.example.com"')
    fi
    
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
    
    # Create unified environment file for domain substitution and other modules
    cat > $AUTOCONF_DIR/haproxy_env <<ENVEOF
# HAProxy Environment Variables - Auto-generated
# Used for HAProxy config substitution and other modules

# Domain configurations
XHTTP_DOMAIN=$xhttp_domain
GRPC_DOMAIN=$grpc_domain
TROJAN_DOMAIN=$trojan_domain
SUB_DOMAIN=$sub_domain
WILDCARD_BASE=$wildcard_base

# HAProxy stats credentials
STATS_USER=$stats_user
STATS_PASS=$stats_pass

# Ports
XHTTP_PORT=$xhttp_port
GRPC_PORT=$grpc_port
TROJAN_PORT=$trojan_port
NGINX_PORT=$nginx_port
STATS_PORT=$stats_port
ENVEOF
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
