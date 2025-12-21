#!/bin/bash
# Nginx Subscription Server Setup Module

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Generate random ShortID (12 characters, alphanumeric)
generate_short_id() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12
}

# Generate random subdomain (5 characters, lowercase alphanumeric)
generate_random_subdomain() {
    tr -dc 'a-z0-9' < /dev/urandom | head -c 5
}

# Install and configure Nginx
install_nginx() {
    echo -e "${YELLOW}Installing Nginx...${NC}"
    
    if command -v nginx &> /dev/null; then
        echo -e "${GREEN}Nginx already installed: $(nginx -v 2>&1)${NC}"
        return 0
    fi
    
    apt-get update -qq
    apt-get install -y nginx apache2-utils
    
    # Enable and start nginx
    systemctl enable nginx
    systemctl start nginx
    
    echo -e "${GREEN}✓ Nginx installed${NC}"
}

# Create subscription directory structure
create_subscription_structure() {
    local short_id=$1
    local sub_dir="/var/www/sub/${short_id}"
    
    echo -e "${YELLOW}Creating subscription directory structure...${NC}"
    
    # Create directories
    mkdir -p "$sub_dir"
    mkdir -p /var/www/html
    
    # Set permissions
    chown -R www-data:www-data /var/www/sub
    chmod -R 755 /var/www/sub
    
    echo -e "${GREEN}✓ Subscription directory created: $sub_dir${NC}"
    echo "$sub_dir"
}

# Generate subscription content
generate_subscription_content() {
    local config_json=$1
    local short_id=$2
    local server_ip=$3
    local sub_dir="/var/www/sub/${short_id}"
    
    echo -e "${YELLOW}Generating subscription content...${NC}"
    
    # Read UUIDs and credentials from temp files
    local reality_uuid=$(cat /tmp/uuid_reality 2>/dev/null || echo "")
    local xhttp_uuid=$(cat /tmp/uuid_xhttp 2>/dev/null || echo "")
    local grpc_uuid=$(cat /tmp/uuid_grpc 2>/dev/null || echo "")
    local trojan_password=$(cat /tmp/password_trojan 2>/dev/null || echo "")
    local reality_pubkey=$(cat /tmp/reality_public_key 2>/dev/null || echo "")
    local reality_short_id=$(cat /tmp/reality_short_id 2>/dev/null || echo "")
    
    # Read random subdomains if exist, or use CDN domain
    local cdn_domain=$(echo "$config_json" | jq -r '.domains.cdn_domain // null')
    local xhttp_domain=$(cat /tmp/random_subdomain_xhttp 2>/dev/null || echo "$cdn_domain")
    local grpc_domain=$(cat /tmp/random_subdomain_grpc 2>/dev/null || echo "$cdn_domain")
    local trojan_domain=$(cat /tmp/random_subdomain_trojan 2>/dev/null || echo "$cdn_domain")
    
    # Fallback to example domains if CDN not configured
    [ "$xhttp_domain" = "null" ] && xhttp_domain="xhttp.example.com"
    [ "$grpc_domain" = "null" ] && grpc_domain="grpc.example.com"
    [ "$trojan_domain" = "null" ] && trojan_domain="trojan.example.com"
    
    # Generate share links
    local links=""
    
    # Reality link
    if [ -n "$reality_uuid" ] && [ -n "$reality_pubkey" ]; then
        local reality_enabled=$(echo "$config_json" | jq -r '.protocols.reality.enabled')
        if [ "$reality_enabled" = "true" ]; then
            local reality_port=$(echo "$config_json" | jq -r '.protocols.reality.port')
            local reality_sni=$(echo "$config_json" | jq -r '.protocols.reality.server_names[0]')
            links+="vless://${reality_uuid}@${server_ip}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_pubkey}&sid=${reality_short_id}&type=tcp&headerType=none#Reality-XTLS-Vision\n"
        fi
    fi
    
    # XHTTP link (CDN-compatible)
    if [ -n "$xhttp_uuid" ]; then
        local xhttp_enabled=$(echo "$config_json" | jq -r '.protocols.xhttp.enabled')
        if [ "$xhttp_enabled" = "true" ]; then
            local xhttp_path=$(echo "$config_json" | jq -r '.protocols.xhttp.path')
            links+="vless://${xhttp_uuid}@${xhttp_domain}:443?encryption=none&security=tls&sni=${xhttp_domain}&alpn=h2,http/1.1&type=xhttp&path=${xhttp_path}#XHTTP-TLS-CDN\n"
        fi
    fi
    
    # gRPC link (CDN-compatible)
    if [ -n "$grpc_uuid" ]; then
        local grpc_enabled=$(echo "$config_json" | jq -r '.protocols.grpc.enabled')
        if [ "$grpc_enabled" = "true" ]; then
            local grpc_service=$(echo "$config_json" | jq -r '.protocols.grpc.service_name')
            links+="vless://${grpc_uuid}@${grpc_domain}:443?encryption=none&security=tls&sni=${grpc_domain}&alpn=h2&type=grpc&serviceName=${grpc_service}#gRPC-TLS-CDN\n"
        fi
    fi
    
    # Trojan link (CDN-compatible)
    if [ -n "$trojan_password" ]; then
        local trojan_enabled=$(echo "$config_json" | jq -r '.protocols.trojan.enabled')
        if [ "$trojan_enabled" = "true" ]; then
            links+="trojan://${trojan_password}@${trojan_domain}:443?security=tls&sni=${trojan_domain}&alpn=http/1.1&type=tcp#Trojan-TCP-TLS-CDN\n"
        fi
    fi
    
    # Save links
    echo -e "$links" > "${sub_dir}/links.txt"
    
    # Generate Base64 subscription
    echo -e "$links" | base64 -w 0 > "${sub_dir}/sub"
     
    echo -e "${GREEN}✓ Subscription content generated${NC}"
    echo "  - Links: ${sub_dir}/links.txt"
    echo "  - Base64: ${sub_dir}/sub"
    echo ""
    [ "$cdn_domain" != "null" ] && echo -e "${YELLOW}Using CDN domain: ${cdn_domain}${NC}"
}

# Create login page
create_login_page() {
    local short_id=$1
    local sub_domain=$2
    
    echo -e "${YELLOW}Creating login page...${NC}"
    
    cat > /var/www/html/login.html <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>订阅服务</title>
    <style>
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            margin: 0;
        }
        .container {
            background: white;
            padding: 2rem;
            border-radius: 10px;
            box-shadow: 0 10px 25px rgba(0,0,0,0.2);
            max-width: 500px;
            width: 90%;
        }
        h1 {
            color: #333;
            margin-bottom: 1.5rem;
            text-align: center;
        }
        .info {
            background: #f8f9fa;
            padding: 1rem;
            border-radius: 5px;
            margin-bottom: 1rem;
        }
        .url-box {
            background: #e9ecef;
            padding: 0.75rem;
            border-radius: 5px;
            font-family: monospace;
            word-break: break-all;
            margin: 0.5rem 0;
        }
        .copy-btn {
            background: #667eea;
            color: white;
            border: none;
            padding: 0.5rem 1rem;
            border-radius: 5px;
            cursor: pointer;
            font-size: 0.9rem;
            margin-top: 0.5rem;
        }
        .copy-btn:hover {
            background: #5568d3;
        }
        .note {
            color: #666;
            font-size: 0.9rem;
            margin-top: 1rem;
            padding: 0.75rem;
            background: #fff3cd;
            border-radius: 5px;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔐 订阅链接</h1>
        <div class="info">
            <h3>Base64 订阅</h3>
            <div class="url-box" id="base64-url">https://${sub_domain}/${short_id}/sub</div>
            <button class="copy-btn" onclick="copyToClipboard('base64-url')">复制链接</button>
        </div>
        <div class="info">
            <h3>Clash 订阅</h3>
            <div class="url-box" id="clash-url">https://${sub_domain}/${short_id}/clash.yaml</div>
            <button class="copy-btn" onclick="copyToClipboard('clash-url')">复制链接</button>
        </div>
        <div class="info">
            <h3>分享链接列表</h3>
            <div class="url-box" id="links-url">https://${sub_domain}/${short_id}/links.txt</div>
            <button class="copy-btn" onclick="copyToClipboard('links-url')">复制链接</button>
        </div>
        <div class="note">
            ⚠️ 请妥善保管订阅链接，不要分享给他人
        </div>
    </div>
    <script>
        function copyToClipboard(elementId) {
            const text = document.getElementById(elementId).innerText;
            navigator.clipboard.writeText(text).then(() => {
                alert('已复制到剪贴板');
            });
        }
    </script>
</body>
</html>
EOF
    
    echo -e "${GREEN}✓ Login page created${NC}"
}

# Configure Nginx for subscription
configure_nginx_subscription() {
    local sub_domain=$1
    local nginx_port=$2
    local login_user=$3
    local login_password=$4
    local stats_port=$5
    local cert_dir="/etc/xray/cert"
    
    echo -e "${YELLOW}Configuring Nginx for subscription...${NC}"
    
    # Create htpasswd file
    htpasswd -bc /etc/nginx/.htpasswd "$login_user" "$login_password"
    
    # Create Nginx configuration with TLS
    cat > /etc/nginx/sites-available/subscription <<EOF
server {
    listen 127.0.0.1:${nginx_port} ssl http2;
    server_name ${sub_domain};
    
    # TLS configuration
    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    
    root /var/www;
    
    # Login endpoint (requires authentication)
    location = /login {
        auth_basic "Subscription Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
        alias /var/www/html/login.html;
    }
    
    # HAProxy stats proxy (passthrough auth to HAProxy)
    location /stats {
        proxy_pass http://127.0.0.1:${stats_port}/stats;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Subscription paths (strict 12-character alphanumeric ShortID, no auth)
    location ~ ^/[A-Za-z0-9]{12}/.*$ {
        root /var/www/sub;
        autoindex off;
        add_header Content-Type text/plain;
    }
    
    # All other paths return 404
    location / {
        return 404;
    }
}
EOF
    
    # Enable site
    ln -sf /etc/nginx/sites-available/subscription /etc/nginx/sites-enabled/
    
    # Test configuration
    if nginx -t; then
        systemctl reload nginx
        echo -e "${GREEN}✓ Nginx configured for subscription with TLS${NC}"
    else
        echo -e "${RED}✗ Nginx configuration test failed${NC}"
        return 1
    fi
}

# Main subscription setup function
setup_subscription() {
    local config_json=$1
    local server_ip=$2
    
    local sub_enabled
    local sub_domain
    local nginx_port
    local login_user
    local login_password
    local stats_port
    
    sub_enabled=$(echo "$config_json" | jq -r '.subscription.enabled // true')
    sub_domain=$(echo "$config_json" | jq -r '.domains.subscription')
    nginx_port=$(echo "$config_json" | jq -r '.subscription.nginx_port // 2096')
    login_user=$(echo "$config_json" | jq -r '.subscription.login_user // "admin"')
    login_password=$(echo "$config_json" | jq -r '.subscription.login_password')
    stats_port=$(echo "$config_json" | jq -r '.haproxy.stats_port // 2053')
    
    if [ "$sub_enabled" != "true" ]; then
        echo -e "${YELLOW}Subscription is disabled in configuration${NC}"
        return 0
    fi
    
    if [ "$sub_domain" = "null" ]; then
        echo -e "${YELLOW}Subscription domain not configured${NC}"
        return 0
    fi
    
    # Generate random password if auto-generate
    if [ "$login_password" = "null" ] || [ "$login_password" = "auto-generate" ]; then
        login_password=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
        echo "$login_password" > /tmp/subscription_password
    fi
    
    echo -e "${YELLOW}=====================================${NC}"
    echo -e "${YELLOW}Subscription Setup${NC}"
    echo -e "${YELLOW}=====================================${NC}"
    echo ""
    
    # Install Nginx
    install_nginx
    
    # Generate ShortID
    local short_id=$(generate_short_id)
    echo -e "${GREEN}Generated ShortID: ${short_id}${NC}"
    echo "$short_id" > /tmp/subscription_shortid
    
    # Create directory structure
    create_subscription_structure "$short_id"
    
    # Generate subscription content
    generate_subscription_content "$config_json" "$short_id" "$server_ip"
    
    # Create login page
    create_login_page "$short_id" "$sub_domain"
    
    # Configure Nginx with stats proxy
    configure_nginx_subscription "$sub_domain" "$nginx_port" "$login_user" "$login_password" "$stats_port"
    
    echo ""
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}Subscription Setup Complete${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo ""
    echo "Subscription Information:"
    echo "  - Domain: $sub_domain"
    echo "  - Login URL: https://$sub_domain/login"
    echo "  - Login User: $login_user"
    echo "  - Login Password: $login_password"
    echo ""
    echo "Service URLs:"
    echo "  - Base64: https://$sub_domain/$short_id/sub"
    echo "  - Links: https://$sub_domain/$short_id/links.txt"
    echo "  - HAProxy Stats: https://$sub_domain/stats"
    echo ""
    echo -e "${YELLOW}⚠️  请妥善保管登录密码和ShortID${NC}"
    echo ""
}

# Main execution
if [ $# -lt 2 ]; then
    echo "Usage: $0 <config-file.json> <server-ip>"
    exit 1
fi

CONFIG_FILE=$1
SERVER_IP=$2

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

CONFIG_JSON=$(cat "$CONFIG_FILE")
setup_subscription "$CONFIG_JSON" "$SERVER_IP"
