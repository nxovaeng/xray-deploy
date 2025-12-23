#!/bin/bash
# Auto-generated Variables - 生成到单个文件
# 自动生成的变量（UUID、密码、密钥、域名等）全部写入 .env 文件

set -euo pipefail

AUTOCONF_DIR="${AUTOCONF_DIR:-/tmp}"
AUTOCONF_FILE="${AUTOCONF_DIR}/autoconf.env"

# 生成 UUID
generate_uuid() {
    if command -v uuidgen &> /dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# 生成密码
generate_password() {
    openssl rand -base64 16 | tr -d '\n'
}

# 生成 Reality 密钥对
generate_reality_keys() {
    local keys_output
    keys_output=$(/usr/local/bin/xray x25519 2>&1)
    
    local private_key=""
    local public_key=""
    
    private_key=$(echo "$keys_output" | grep -i "private" | sed 's/^[^:]*://' | tr -d ' \r\n')
    public_key=$(echo "$keys_output" | grep -i "public" | sed 's/^[^:]*://' | tr -d ' \r\n')
    
    if [ -z "$public_key" ]; then
        public_key=$(echo "$keys_output" | grep -i "password" | sed 's/^[^:]*://' | tr -d ' \r\n')
    fi
    
    if [ -z "$public_key" ] && [ -n "$private_key" ]; then
        local derived
        derived=$(/usr/local/bin/xray x25519 -i "$private_key" 2>&1)
        public_key=$(echo "$derived" | grep -i "public" | sed 's/^[^:]*://' | tr -d ' \r\n')
        if [ -z "$public_key" ]; then
            public_key=$(echo "$derived" | grep -i "password" | sed 's/^[^:]*://' | tr -d ' \r\n')
        fi
    fi
    
    if [ -z "$private_key" ] || [ ${#private_key} -lt 40 ]; then
        return 1
    fi
    
    echo "$private_key:$public_key"
}

# 生成随机子域名
generate_subdomain() {
    openssl rand -hex 3 | head -c 5
}

# 生成随机 PATH（XHTTP）
generate_path() {
    local paths=("/api" "/download" "/upload" "/files" "/data" "/static" "/media" "/resources" "/assets")
    local idx=$((RANDOM % ${#paths[@]}))
    echo "${paths[$idx]}"
}

# 生成随机 Service Name（gRPC）
generate_service_name() {
    local names=("GunService" "ProxyService" "TransportService" "StreamService" "TunnelService" "RelayService" "GatewayService" "RouteService")
    local idx=$((RANDOM % ${#names[@]}))
    echo "${names[$idx]}"
}

# 生成短ID（Reality和Subscription）
generate_short_id() {
    openssl rand -hex 8
}

# 生成完整的自动配置文件
generate() {
    local config_file=$1
    
    if [ ! -f "$config_file" ]; then
        echo "Error: config file not found: $config_file"
        return 1
    fi
    
    mkdir -p "$AUTOCONF_DIR"
    
    local config_json=$(cat "$config_file")
    
    # 读取配置
    local reality_enabled=$(echo "$config_json" | jq -r '.protocols.reality.enabled // false')
    local xhttp_enabled=$(echo "$config_json" | jq -r '.protocols.xhttp.enabled // false')
    local grpc_enabled=$(echo "$config_json" | jq -r '.protocols.grpc.enabled // false')
    local trojan_enabled=$(echo "$config_json" | jq -r '.protocols.trojan.enabled // false')
    local sub_enabled=$(echo "$config_json" | jq -r '.subscription.enabled // false')
    
    # 生成变量
    local uuid_reality=$(generate_uuid)
    local uuid_xhttp=$(generate_uuid)
    local uuid_grpc=$(generate_uuid)
    
    # Passwords - 优先从config读取，如果为null或auto-generate则生成
    local password_trojan=$(echo "$config_json" | jq -r '.uuids.trojan_password // "auto-generate"')
    local haproxy_stats_password=$(echo "$config_json" | jq -r '.haproxy.stats_password // "auto-generate"')
    local subscription_password=$(echo "$config_json" | jq -r '.subscription.login_password // "auto-generate"')
    
    # 生成缺失的密码
    [ "$password_trojan" = "null" ] || [ "$password_trojan" = "auto-generate" ] && password_trojan=$(generate_password)
    [ "$haproxy_stats_password" = "null" ] || [ "$haproxy_stats_password" = "auto-generate" ] && haproxy_stats_password=$(generate_password)
    [ "$subscription_password" = "null" ] || [ "$subscription_password" = "auto-generate" ] && subscription_password=$(generate_password)
    
    # Reality 密钥
    local reality_keys=""
    local reality_private_key=""
    local reality_public_key=""
    local reality_short_id=""
    if [ "$reality_enabled" = "true" ] && command -v /usr/local/bin/xray &>/dev/null; then
        reality_keys=$(generate_reality_keys)
        if [ -n "$reality_keys" ]; then
            reality_private_key=$(echo "$reality_keys" | cut -d':' -f1)
            reality_public_key=$(echo "$reality_keys" | cut -d':' -f2)
            reality_short_id=$(generate_short_id)
        else
            echo "Warning: Failed to generate Reality keys"
            reality_keys="FAILED:FAILED"
            reality_private_key="FAILED"
            reality_public_key="FAILED"
            reality_short_id="FAILED"
        fi
    fi
    
    # 子域名
    local wildcard_base=$(echo "$config_json" | jq -r '.domains.wildcard_base // ""')
    local domain_xhttp=$([ "$xhttp_enabled" = "true" ] && [ -n "$wildcard_base" ] && echo "$(generate_subdomain).${wildcard_base}" || echo "")
    local domain_grpc=$([ "$grpc_enabled" = "true" ] && [ -n "$wildcard_base" ] && echo "$(generate_subdomain).${wildcard_base}" || echo "")
    local domain_trojan=$([ "$trojan_enabled" = "true" ] && [ -n "$wildcard_base" ] && echo "$(generate_subdomain).${wildcard_base}" || echo "")
    local subscription_domain=$(echo "$config_json" | jq -r '.domains.subscription // ""')
    
    # XHTTP PATH 和 gRPC Service Name
    local xhttp_path=$([ "$xhttp_enabled" = "true" ] && generate_path || echo "")
    local grpc_service_name=$([ "$grpc_enabled" = "true" ] && generate_service_name || echo "")
    local subscription_shortid=$([ "$sub_enabled" = "true" ] && generate_short_id || echo "")
    
    # 端口和用户
    local xhttp_port=$(echo "$config_json" | jq -r '.protocols.xhttp.port // 8443')
    local grpc_port=$(echo "$config_json" | jq -r '.protocols.grpc.port // 2083')
    local trojan_port=$(echo "$config_json" | jq -r '.protocols.trojan.port // 2087')
    local nginx_port=$(echo "$config_json" | jq -r '.subscription.nginx_port // 2096')
    local haproxy_stats_port=$(echo "$config_json" | jq -r '.haproxy.stats_port // 2053')
    local haproxy_stats_user=$(echo "$config_json" | jq -r '.haproxy.stats_user // "admin"')
    
    # 生成统一的配置文件
    cat > "$AUTOCONF_FILE" <<EOF
# Auto-generated Variables - $(date '+%Y-%m-%d %H:%M:%S')
# Generated by auto-generate.sh

# UUIDs
UUID_REALITY=$uuid_reality
UUID_XHTTP=$uuid_xhttp
UUID_GRPC=$uuid_grpc

# Passwords
TROJAN_PASSWORD=$password_trojan
HAPROXY_STATS_PASSWORD=$haproxy_stats_password
SUBSCRIPTION_PASSWORD=$subscription_password

# Reality Keys
REALITY_KEYS=$reality_keys
REALITY_PRIVATE_KEY=$reality_private_key
REALITY_PUBLIC_KEY=$reality_public_key
REALITY_SHORT_ID=$reality_short_id

# Domains
DOMAIN_XHTTP=$domain_xhttp
DOMAIN_GRPC=$domain_grpc
DOMAIN_TROJAN=$domain_trojan
SUBSCRIPTION_DOMAIN=$subscription_domain
WILDCARD_BASE=$wildcard_base

# XHTTP and gRPC
XHTTP_PATH=$xhttp_path
GRPC_SERVICE_NAME=$grpc_service_name

# Ports
XHTTP_PORT=$xhttp_port
GRPC_PORT=$grpc_port
TROJAN_PORT=$trojan_port
NGINX_PORT=$nginx_port
HAPROXY_STATS_PORT=$haproxy_stats_port

# HAProxy Stats
HAPROXY_STATS_USER=$haproxy_stats_user

# Subscription
SUBSCRIPTION_SHORTID=$subscription_shortid
EOF
    
    echo "✓ Generated: $AUTOCONF_FILE"
    cat "$AUTOCONF_FILE"
}

# 显示配置
show() {
    if [ ! -f "$AUTOCONF_FILE" ]; then
        echo "Error: $AUTOCONF_FILE not found"
        return 1
    fi
    cat "$AUTOCONF_FILE"
}

# 导出为环境变量
export_env() {
    if [ ! -f "$AUTOCONF_FILE" ]; then
        echo "Error: $AUTOCONF_FILE not found"
        return 1
    fi
    # 生成可用于 source 的格式
    echo "# Source this file: source <(auto-generate.sh export-env)"
    grep -v "^#" "$AUTOCONF_FILE" | grep "="
}

# CLI 接口
case "${1:-help}" in
    gen|generate)
        generate "${2:-scripts/config-template.json}"
        ;;
    show|cat)
        show
        ;;
    env|export)
        export_env
        ;;
    *)
        cat <<EOF
Usage: $0 <command> [args]

Commands:
  generate <config.json>  生成自动配置文件 (默认: scripts/config-template.json)
  show                    显示生成的配置文件内容
  export                  导出为环境变量格式

Examples:
  $0 generate my-config.json
  $0 show
  source <($0 export)

Output file: $AUTOCONF_FILE
EOF
        ;;
esac
