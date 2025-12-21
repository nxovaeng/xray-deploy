#!/bin/bash
# HAProxy Configuration Generator Module
# SNI-based routing for multiple protocols with random subdomain support

set -euo pipefail

# Generate random subdomain (5 characters, lowercase alphanumeric)
generate_random_subdomain() {
    tr -dc 'a-z0-9' < /dev/urandom | head -c 5
}

# Generate HAProxy stats password
generate_stats_password() {
    openssl rand -base64 12
}

# Create HAProxy frontend configuration
create_frontend_config() {
    local frontend_port=$1
    local stats_port=$2
    
    cat <<EOF
frontend https_frontend
    bind *:$frontend_port
    mode tcp
    option tcplog
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    
    # SNI-based routing (random subdomains for security)
    use_backend xhttp_backend if { req_ssl_sni -i \$XHTTP_DOMAIN }
    use_backend grpc_backend if { req_ssl_sni -i \$GRPC_DOMAIN }
    use_backend trojan_backend if { req_ssl_sni -i \$TROJAN_DOMAIN }
    use_backend subscription_backend if { req_ssl_sni -i \$SUB_DOMAIN }
    
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
create_backends_config() {
    local xhttp_port=$1
    local grpc_port=$2
    local trojan_port=$3
    local nginx_port=$4
    
    cat <<EOF

# Reject backend for unknown SNI
backend reject_backend
    mode tcp
    timeout server 1s
    server reject 127.0.0.1:1 send-proxy

# XHTTP backend (TCP passthrough - Xray handles TLS)
backend xhttp_backend
    mode tcp
    option ssl-hello-chk
    server xray_xhttp 127.0.0.1:$xhttp_port check

# gRPC backend (TCP passthrough - Xray handles TLS)
backend grpc_backend
    mode tcp
    option ssl-hello-chk
    server xray_grpc 127.0.0.1:$grpc_port check

# Trojan backend (TCP passthrough - Xray handles TLS)
backend trojan_backend
    mode tcp
    option ssl-hello-chk
    server xray_trojan 127.0.0.1:$trojan_port check

# Subscription backend (TCP passthrough - Nginx handles TLS)
backend subscription_backend
    mode tcp
    option ssl-hello-chk
    server nginx_sub 127.0.0.1:$nginx_port check
EOF
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
        echo "$stats_pass" > /tmp/haproxy_stats_password
    fi
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
    
    # Generate random subdomains or use configured ones
    local xhttp_domain
    local grpc_domain
    local trojan_domain
    
    if [ "$wildcard_base" != "null" ]; then
        # Generate random subdomains
        xhttp_domain="$(generate_random_subdomain).${wildcard_base}"
        grpc_domain="$(generate_random_subdomain).${wildcard_base}"
        trojan_domain="$(generate_random_subdomain).${wildcard_base}"
        
        # Save to temp files for use in subscription generation
        echo "$xhttp_domain" > /tmp/random_subdomain_xhttp
        echo "$grpc_domain" > /tmp/random_subdomain_grpc
        echo "$trojan_domain" > /tmp/random_subdomain_trojan
    else
        # Use configured domains (backward compatibility)
        xhttp_domain=$(echo "$config_json" | jq -r '.domains.xhttp // "xhttp.example.com"')
        grpc_domain=$(echo "$config_json" | jq -r '.domains.grpc // "grpc.example.com"')
        trojan_domain=$(echo "$config_json" | jq -r '.domains.trojan // "trojan.example.com"')
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

$(create_frontend_config "$frontend_port" "$stats_port")

$(create_backends_config "$xhttp_port" "$grpc_port" "$trojan_port" "$nginx_port")
EOF
    
    # Create environment file for domain substitution
    cat > /tmp/haproxy_env <<ENVEOF
XHTTP_DOMAIN=$xhttp_domain
GRPC_DOMAIN=$grpc_domain
TROJAN_DOMAIN=$trojan_domain
SUB_DOMAIN=$sub_domain
STATS_USER=$stats_user
STATS_PASS=$stats_pass
ENVEOF
    
    # Also save domains to separate files for easy access
    echo "$xhttp_domain" > /tmp/haproxy_xhttp_domain
    echo "$grpc_domain" > /tmp/haproxy_grpc_domain
    echo "$trojan_domain" > /tmp/haproxy_trojan_domain
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
