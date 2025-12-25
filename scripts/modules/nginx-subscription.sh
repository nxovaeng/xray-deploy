#!/bin/bash
# Nginx Subscription Server Setup Module
# 从 autoconf.env 读取所有变量，仅负责配置生成

set -euo pipefail

# Use AUTOCONF_DIR from environment or fallback to /tmp
AUTOCONF_DIR="${AUTOCONF_DIR:-/tmp}"
AUTOCONF_FILE="${AUTOCONF_DIR}/autoconf.env"

# Load auto-generated variables (single source of truth)
if [ -f "$AUTOCONF_FILE" ]; then
    source "$AUTOCONF_FILE"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
    local custom_dir="/var/www/sub/custom"
    
    echo -e "${YELLOW}Creating subscription directory structure...${NC}"
    
    # Create directories
    mkdir -p "$sub_dir"
    mkdir -p "$custom_dir"
    mkdir -p /var/www/html
    
    # Create README for custom directory
    cat > "$custom_dir/README.txt" <<'CUSTOMREADME'
# Custom Subscription Directory
# 自定义订阅目录

This directory is for hosting subscription files from other servers.
此目录用于存放其他服务器的订阅文件。

Usage / 用法:
1. Place subscription files here (e.g., server2.txt, server3_sub)
   将订阅文件放入此目录 (如 server2.txt, server3_sub)

2. Access via: https://{domain}/custom/{filename}
   访问地址: https://{域名}/custom/{文件名}

Examples / 示例:
- https://sub.example.com/custom/server2.txt
- https://sub.example.com/custom/us-node/sub

Note: Subdirectories are supported for organizing multiple servers.
注意: 支持子目录，便于管理多个服务器的订阅。
CUSTOMREADME
    
    # Set permissions
    chown -R www-data:www-data /var/www/sub
    chmod -R 755 /var/www/sub
    
    echo -e "${GREEN}✓ Subscription directory created: $sub_dir${NC}"
    echo -e "${GREEN}✓ Custom subscription directory: $custom_dir${NC}"
    echo "$sub_dir"
}

# Generate subscription content
generate_subscription_content() {
    local config_json=$1
    local short_id=$2
    local server_ip=$3
    local sub_dir="/var/www/sub/${short_id}"
    
    echo -e "${YELLOW}Generating subscription content...${NC}"
    
    # Read UUIDs and credentials from autoconf.env only (single source of truth)
    local reality_uuid="${UUID_REALITY:-}"
    local xhttp_uuid="${UUID_XHTTP:-}"
    local grpc_uuid="${UUID_GRPC:-}"
    local trojan_password="${TROJAN_PASSWORD:-}"
    local reality_pubkey="${REALITY_PUBLIC_KEY:-}"
    local reality_short_id="${REALITY_SHORT_ID:-}"
    
    
    # Read domains from autoconf.env or use CDN domain
    local cdn_domain=$(echo "$config_json" | jq -r '.domains.cdn_domain // null')
    local xhttp_domain="${DOMAIN_XHTTP:-${cdn_domain}}"
    local grpc_domain="${DOMAIN_GRPC:-${cdn_domain}}"
    local trojan_domain="${DOMAIN_TROJAN:-${cdn_domain}}"
    
    # Fallback to example domains if CDN not configured
    [ -z "$xhttp_domain" ] || [ "$xhttp_domain" = "null" ] && xhttp_domain="xhttp.example.com"
    [ -z "$grpc_domain" ] || [ "$grpc_domain" = "null" ] && grpc_domain="grpc.example.com"
    [ -z "$trojan_domain" ] || [ "$trojan_domain" = "null" ] && trojan_domain="trojan.example.com"
    
    # Generate share links
    local links=""
    
    # Reality link
    if [ -n "$reality_uuid" ] && [ -n "$reality_pubkey" ]; then
        local reality_enabled=$(echo "$config_json" | jq -r '.protocols.reality.enabled')
        if [ "$reality_enabled" = "true" ]; then
            local reality_port=$(echo "$config_json" | jq -r '.protocols.reality.port')
            local reality_sni=$(echo "$config_json" | jq -r '.protocols.reality.server_names[0]')
            links+="vless://${reality_uuid}@${server_ip}:${reality_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${reality_pubkey}&sid=${reality_short_id}&type=tcp&headerType=none#Reality-Direct\n"
        fi
    fi
    
    # XHTTP links (CDN-compatible: generate both CDN and Direct variants)
    if [ -n "$xhttp_uuid" ]; then
        local xhttp_enabled=$(echo "$config_json" | jq -r '.protocols.xhttp.enabled')
        if [ "$xhttp_enabled" = "true" ]; then
            local xhttp_path="${XHTTP_PATH:-$(echo "$config_json" | jq -r '.protocols.xhttp.path')}"
            local xhttp_cdn=$(echo "$config_json" | jq -r '.protocols.xhttp.cdn_compatible // false')
            
            # Direct connection link (using random subdomain)
            links+="vless://${xhttp_uuid}@${xhttp_domain}:443?encryption=none&security=tls&sni=${xhttp_domain}&fp=chrome&alpn=h2,http/1.1&type=xhttp&path=${xhttp_path}#XHTTP-Direct\n"
            
            # CDN connection link (using cdn_domain if available and cdn_compatible)
            if [ "$xhttp_cdn" = "true" ] && [ -n "$cdn_domain" ] && [ "$cdn_domain" != "null" ]; then
                links+="vless://${xhttp_uuid}@${cdn_domain}:443?encryption=none&security=tls&sni=${xhttp_domain}&fp=chrome&alpn=h2,http/1.1&type=xhttp&path=${xhttp_path}&host=${xhttp_domain}#XHTTP-CDN\n"
            fi
        fi
    fi
    
    # gRPC links (CDN-compatible: generate both CDN and Direct variants)
    if [ -n "$grpc_uuid" ]; then
        local grpc_enabled=$(echo "$config_json" | jq -r '.protocols.grpc.enabled')
        if [ "$grpc_enabled" = "true" ]; then
            local grpc_service="${GRPC_SERVICE_NAME:-$(echo "$config_json" | jq -r '.protocols.grpc.service_name')}"
            local grpc_cdn=$(echo "$config_json" | jq -r '.protocols.grpc.cdn_compatible // false')
            
            # Direct connection link
            links+="vless://${grpc_uuid}@${grpc_domain}:443?encryption=none&security=tls&sni=${grpc_domain}&fp=chrome&alpn=h2&type=grpc&serviceName=${grpc_service}#gRPC-Direct\n"
            
            # CDN connection link
            if [ "$grpc_cdn" = "true" ] && [ -n "$cdn_domain" ] && [ "$cdn_domain" != "null" ]; then
                links+="vless://${grpc_uuid}@${cdn_domain}:443?encryption=none&security=tls&sni=${grpc_domain}&fp=chrome&alpn=h2&type=grpc&serviceName=${grpc_service}&authority=${grpc_domain}#gRPC-CDN\n"
            fi
        fi
    fi
    
    # Trojan links (generate both CDN and Direct variants)
    if [ -n "$trojan_password" ]; then
        local trojan_enabled=$(echo "$config_json" | jq -r '.protocols.trojan.enabled')
        if [ "$trojan_enabled" = "true" ]; then
            # Direct connection link
            links+="trojan://${trojan_password}@${trojan_domain}:443?security=tls&sni=${trojan_domain}&fp=chrome&alpn=http/1.1&type=tcp#Trojan-Direct\n"
            
            # CDN connection link (if cdn_domain available)
            if [ -n "$cdn_domain" ] && [ "$cdn_domain" != "null" ]; then
                links+="trojan://${trojan_password}@${cdn_domain}:443?security=tls&sni=${trojan_domain}&fp=chrome&alpn=http/1.1&type=tcp&host=${trojan_domain}#Trojan-CDN\n"
            fi
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
    
    cat > /var/www/html/login.html <<'LOGINEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>订阅服务</title>
    <style>
        * { box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            display: flex;
            justify-content: center;
            align-items: flex-start;
            min-height: 100vh;
            margin: 0;
            padding: 2rem 0;
        }
        .container {
            background: white;
            padding: 2rem;
            border-radius: 10px;
            box-shadow: 0 10px 25px rgba(0,0,0,0.2);
            max-width: 600px;
            width: 90%;
        }
        h1 {
            color: #333;
            margin-bottom: 1.5rem;
            text-align: center;
        }
        h2 {
            color: #555;
            font-size: 1.1rem;
            margin: 1.5rem 0 0.5rem 0;
            padding-bottom: 0.5rem;
            border-bottom: 2px solid #667eea;
        }
        h3 {
            color: #333;
            margin: 0 0 0.5rem 0;
            font-size: 1rem;
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
            font-size: 0.85rem;
            word-break: break-all;
            margin: 0.5rem 0;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        .url-text {
            flex: 1;
            overflow-wrap: anywhere;
        }
        .copy-btn {
            background: #667eea;
            color: white;
            border: none;
            padding: 0.4rem 0.8rem;
            border-radius: 5px;
            cursor: pointer;
            font-size: 0.8rem;
            white-space: nowrap;
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
        .custom-section {
            margin-top: 1.5rem;
            padding-top: 1rem;
            border-top: 1px solid #ddd;
        }
        .custom-list {
            list-style: none;
            padding: 0;
            margin: 0;
        }
        .custom-list li {
            background: #f8f9fa;
            margin: 0.5rem 0;
            padding: 0.75rem;
            border-radius: 5px;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        .custom-list .icon {
            font-size: 1.2rem;
        }
        .custom-list .name {
            flex: 1;
            font-weight: 500;
        }
        .custom-list a {
            color: #667eea;
            text-decoration: none;
            font-size: 0.85rem;
        }
        .custom-list a:hover {
            text-decoration: underline;
        }
        .loading {
            color: #888;
            font-style: italic;
            padding: 1rem;
            text-align: center;
        }
        .empty {
            color: #888;
            padding: 1rem;
            text-align: center;
            background: #f8f9fa;
            border-radius: 5px;
        }
        .folder {
            background: #e3f2fd !important;
        }
        .refresh-btn {
            background: transparent;
            border: 1px solid #667eea;
            color: #667eea;
            padding: 0.3rem 0.6rem;
            border-radius: 5px;
            cursor: pointer;
            font-size: 0.8rem;
            margin-left: 0.5rem;
        }
        .refresh-btn:hover {
            background: #667eea;
            color: white;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔐 订阅链接</h1>
        
        <h2>📡 本机订阅</h2>
        <div class="info">
            <h3>Base64 订阅</h3>
            <div class="url-box">
                <span class="url-text" id="base64-url"></span>
                <button class="copy-btn" onclick="copyToClipboard('base64-url')">复制</button>
            </div>
        </div>
        <div class="info">
            <h3>分享链接列表</h3>
            <div class="url-box">
                <span class="url-text" id="links-url"></span>
                <button class="copy-btn" onclick="copyToClipboard('links-url')">复制</button>
            </div>
        </div>
        
        <div class="custom-section">
            <h2>🌐 自定义订阅 <button class="refresh-btn" onclick="loadCustomSubscriptions()">刷新</button></h2>
            <div id="custom-list-container">
                <div class="loading">加载中...</div>
            </div>
        </div>
        
        <div class="note">
            ⚠️ 请妥善保管订阅链接，不要分享给他人
        </div>
    </div>
    
    <script>
        // Get current domain and construct URLs
        const domain = window.location.hostname;
        const protocol = window.location.protocol;
        const baseUrl = protocol + '//' + domain;
        
        // These will be replaced by the shell script
        const shortId = 'SHORT_ID_PLACEHOLDER';
        
        // Set subscription URLs
        document.getElementById('base64-url').textContent = baseUrl + '/' + shortId + '/sub';
        document.getElementById('links-url').textContent = baseUrl + '/' + shortId + '/links.txt';
        
        function copyToClipboard(elementId) {
            const text = document.getElementById(elementId).textContent;
            navigator.clipboard.writeText(text).then(() => {
                alert('已复制到剪贴板');
            }).catch(err => {
                // Fallback for older browsers
                const textarea = document.createElement('textarea');
                textarea.value = text;
                document.body.appendChild(textarea);
                textarea.select();
                document.execCommand('copy');
                document.body.removeChild(textarea);
                alert('已复制到剪贴板');
            });
        }
        
        async function loadCustomSubscriptions() {
            const container = document.getElementById('custom-list-container');
            container.innerHTML = '<div class="loading">加载中...</div>';
            
            try {
                const response = await fetch('/custom/');
                if (!response.ok) throw new Error('Failed to fetch');
                
                const html = await response.text();
                const items = parseNginxAutoindex(html);
                
                if (items.length === 0) {
                    container.innerHTML = '<div class="empty">暂无自定义订阅<br><small>将订阅文件放入 /var/www/sub/custom/ 目录</small></div>';
                    return;
                }
                
                const ul = document.createElement('ul');
                ul.className = 'custom-list';
                
                for (const item of items) {
                    if (item.name === 'README.txt') continue; // Skip README
                    
                    const li = document.createElement('li');
                    li.className = item.isDir ? 'folder' : '';
                    
                    const icon = document.createElement('span');
                    icon.className = 'icon';
                    icon.textContent = item.isDir ? '📁' : '📄';
                    
                    const name = document.createElement('span');
                    name.className = 'name';
                    name.textContent = item.name;
                    
                    const link = document.createElement('a');
                    link.href = '/custom/' + item.name;
                    link.textContent = item.isDir ? '打开' : '查看';
                    link.target = '_blank';
                    
                    const copyBtn = document.createElement('button');
                    copyBtn.className = 'copy-btn';
                    copyBtn.textContent = '复制链接';
                    copyBtn.onclick = () => {
                        const url = baseUrl + '/custom/' + item.name;
                        navigator.clipboard.writeText(url).then(() => alert('已复制: ' + url));
                    };
                    
                    li.appendChild(icon);
                    li.appendChild(name);
                    li.appendChild(link);
                    li.appendChild(copyBtn);
                    ul.appendChild(li);
                }
                
                container.innerHTML = '';
                container.appendChild(ul);
                
            } catch (error) {
                container.innerHTML = '<div class="empty">无法加载自定义订阅列表</div>';
                console.error('Error loading custom subscriptions:', error);
            }
        }
        
        function parseNginxAutoindex(html) {
            const items = [];
            // Parse nginx autoindex HTML format
            const regex = /<a href="([^"]+)">([^<]+)<\/a>/g;
            let match;
            
            while ((match = regex.exec(html)) !== null) {
                const href = match[1];
                const name = match[2];
                
                // Skip parent directory link
                if (href === '../' || name === '../') continue;
                
                items.push({
                    name: name.replace(/\/$/, ''),
                    href: href,
                    isDir: href.endsWith('/')
                });
            }
            
            return items;
        }
        
        // Load custom subscriptions on page load
        document.addEventListener('DOMContentLoaded', loadCustomSubscriptions);
    </script>
</body>
</html>
LOGINEOF
    
    # Replace placeholder with actual short_id
    sed -i "s/SHORT_ID_PLACEHOLDER/${short_id}/g" /var/www/html/login.html
    
    echo -e "${GREEN}✓ Login page created${NC}"
}

# Configure Nginx for subscription
configure_nginx_subscription() {
    local sub_domain=$1
    local nginx_port=$2
    local login_user=$3
    local login_password=$4
    local stats_port=$5
    local short_id=$6
    local cert_dir="/etc/xray/cert"
    
    echo -e "${YELLOW}Configuring Nginx for subscription...${NC}"
    
    # Create htpasswd file
    htpasswd -bc /etc/nginx/.htpasswd "$login_user" "$login_password"
    
    # Create Nginx configuration with TLS
    cat > /etc/nginx/sites-available/subscription <<EOF
server {
    listen 127.0.0.1:${nginx_port} ssl http2;
    listen [::1]:${nginx_port} ssl http2;
    server_name ${sub_domain};
    
    # TLS configuration
    ssl_certificate ${cert_dir}/fullchain.pem;
    ssl_certificate_key ${cert_dir}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    
    root /var/www;
    
    # Login endpoint (requires authentication, serves HTML)
    location /login {
        auth_basic "Subscription Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
        default_type text/html;
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
    
    # Subscription paths (exact shortid path, no auth, plain text)
    location /${short_id}/ {
        alias /var/www/sub/${short_id}/;
        autoindex off;
        default_type text/plain;
    }
    
    # Custom subscription directory for external servers
    # Place other servers' subscription files in /var/www/sub/custom/
    location /custom/ {
        alias /var/www/sub/custom/;
        autoindex on;  # Allow listing for easy management
        default_type text/plain;
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
    sub_domain="$SUBSCRIPTION_DOMAIN"
    nginx_port=$(echo "$config_json" | jq -r '.subscription.nginx_port // 2096')
    login_user="$SUBSCRIPTION_USER"
    login_password="$SUBSCRIPTION_PASSWORD"
    stats_port=$(echo "$config_json" | jq -r '.haproxy.stats_port // 2053')
    
    if [ "$sub_enabled" != "true" ]; then
        echo -e "${YELLOW}Subscription is disabled in configuration${NC}"
        return 0
    fi
    
    if [ "$sub_domain" = "null" ]; then
        echo -e "${YELLOW}Subscription domain not configured${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}=====================================${NC}"
    echo -e "${YELLOW}Subscription Setup${NC}"
    echo -e "${YELLOW}=====================================${NC}"
    echo ""
    
    # Install Nginx
    install_nginx
    
    # Use shortid and password from autoconf.env (already generated by auto-generate.sh)
    local short_id="$SUBSCRIPTION_SHORTID"
    local login_password="$SUBSCRIPTION_PASSWORD"
    echo -e "${GREEN}ShortID: ${short_id}${NC}"
    
    # Create directory structure
    create_subscription_structure "$short_id"
    
    # Generate subscription content
    generate_subscription_content "$config_json" "$short_id" "$server_ip"
    
    # Create login page
    create_login_page "$short_id" "$sub_domain"
    
    # Configure Nginx with stats proxy
    configure_nginx_subscription "$sub_domain" "$nginx_port" "$login_user" "$login_password" "$stats_port" "$short_id"
    
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
    echo "Custom Subscriptions:"
    echo "  - Directory: /var/www/sub/custom/"
    echo "  - Access URL: https://$sub_domain/custom/{filename}"
    echo "  - 将其他服务器的订阅文件放入此目录即可通过 /custom/ 访问"
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
