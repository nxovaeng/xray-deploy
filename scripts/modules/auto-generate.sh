#!/bin/bash
# Auto-generated Variables - 生成到单个文件
# 自动生成的变量（UUID、密码、密钥、域名等）全部写入 .env 文件

set -euo pipefail

AUTOCONF_DIR="${AUTOCONF_DIR:-/tmp}"
AUTOCONF_FILE="${AUTOCONF_DIR}/autoconf.env"

# 持久化配置目录（用于热更新保留变量）
PERSISTENT_DIR="/etc/xray/autoconf"
PERSISTENT_FILE="${PERSISTENT_DIR}/autoconf.env"

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
    openssl rand -hex 3 | head -c 6
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
# 参数: config_file [--force]
# --force: 强制重新生成所有变量（忽略已有配置）
generate() {
    local config_file=$1
    local force_regenerate=false
    
    # 检查 --force 参数
    if [ "${2:-}" = "--force" ]; then
        force_regenerate=true
        echo "⚠️  Force regenerate mode: all variables will be regenerated"
    fi
    
    if [ ! -f "$config_file" ]; then
        echo "Error: config file not found: $config_file"
        return 1
    fi
    
    mkdir -p "$AUTOCONF_DIR"
    mkdir -p "$PERSISTENT_DIR"
    
    local config_json=$(cat "$config_file")
    
    # 读取配置
    local reality_enabled=$(echo "$config_json" | jq -r '.protocols.reality.enabled // false')
    local xhttp_enabled=$(echo "$config_json" | jq -r '.protocols.xhttp.enabled // false')
    local grpc_enabled=$(echo "$config_json" | jq -r '.protocols.grpc.enabled // false')
    local trojan_enabled=$(echo "$config_json" | jq -r '.protocols.trojan.enabled // false')
    local sub_enabled=$(echo "$config_json" | jq -r '.subscription.enabled // false')
    local code_server_enabled=$(echo "$config_json" | jq -r '.code_server.enabled // false')
    
    # ========== 热更新逻辑 ==========
    # 检查是否存在持久化配置文件
    local existing_config=""
    if [ -f "$PERSISTENT_FILE" ] && [ "$force_regenerate" = false ]; then
        echo "✓ Found existing config, preserving UUIDs/passwords/shortids (hot reload mode)"
        existing_config=$(cat "$PERSISTENT_FILE")
    else
        echo "✓ Generating new configuration"
    fi
    
    # 辅助函数：从已有配置中获取值，如果不存在则生成新值
    get_or_generate() {
        local var_name=$1
        local generate_cmd=$2
        local existing_value=""
        
        if [ -n "$existing_config" ]; then
            existing_value=$(echo "$existing_config" | grep "^${var_name}=" | cut -d'=' -f2- | head -n1)
        fi
        
        if [ -n "$existing_value" ] && [ "$existing_value" != "FAILED" ]; then
            echo "$existing_value"
        else
            eval "$generate_cmd"
        fi
    }
    
    # ========== 生成/复用 UUID ==========
    local uuid_reality=$(get_or_generate "UUID_REALITY" "generate_uuid")
    local uuid_xhttp=$(get_or_generate "UUID_XHTTP" "generate_uuid")
    local uuid_grpc=$(get_or_generate "UUID_GRPC" "generate_uuid")
    
    # ========== 生成/复用密码 ==========
    # 优先使用 config.json 中指定的值，其次复用已有值，最后生成新值
    local password_trojan=$(echo "$config_json" | jq -r '.uuids.trojan_password // "auto-generate"')
    local haproxy_stats_password=$(echo "$config_json" | jq -r '.haproxy.stats_password // "auto-generate"')
    local subscription_password=$(echo "$config_json" | jq -r '.subscription.login_password // "auto-generate"')
    local code_server_password=$(echo "$config_json" | jq -r '.code_server.password // "auto-generate"')
    
    # 处理密码：如果为 auto-generate 或 null，则尝试复用或生成
    if [ "$password_trojan" = "null" ] || [ "$password_trojan" = "auto-generate" ]; then
        password_trojan=$(get_or_generate "TROJAN_PASSWORD" "generate_password")
    fi
    if [ "$haproxy_stats_password" = "null" ] || [ "$haproxy_stats_password" = "auto-generate" ]; then
        haproxy_stats_password=$(get_or_generate "HAPROXY_STATS_PASSWORD" "generate_password")
    fi
    if [ "$subscription_password" = "null" ] || [ "$subscription_password" = "auto-generate" ]; then
        subscription_password=$(get_or_generate "SUBSCRIPTION_PASSWORD" "generate_password")
    fi
    if [ "$code_server_password" = "null" ] || [ "$code_server_password" = "auto-generate" ]; then
        code_server_password=$(get_or_generate "CODE_SERVER_PASSWORD" "generate_password")
    fi
    
    # ========== 生成/复用 Reality 密钥 ==========
    local reality_private_key=""
    local reality_public_key=""
    local reality_short_id=""
    local reality_short_id2=""
    
    # 尝试从已有配置复用
    if [ -n "$existing_config" ]; then
        reality_private_key=$(echo "$existing_config" | grep "^REALITY_PRIVATE_KEY=" | cut -d'=' -f2- | head -n1)
        reality_public_key=$(echo "$existing_config" | grep "^REALITY_PUBLIC_KEY=" | cut -d'=' -f2- | head -n1)
        reality_short_id=$(echo "$existing_config" | grep "^REALITY_SHORT_ID=" | cut -d'=' -f2- | head -n1)
        reality_short_id2=$(echo "$existing_config" | grep "^REALITY_SHORT_ID2=" | cut -d'=' -f2- | head -n1)
    fi
    
    # 如果不存在或为 FAILED，则重新生成
    if [ -z "$reality_private_key" ] || [ "$reality_private_key" = "FAILED" ]; then
        if command -v /usr/local/bin/xray &>/dev/null; then
            local reality_keys=$(generate_reality_keys)
            if [ -n "$reality_keys" ]; then
                reality_private_key=$(echo "$reality_keys" | cut -d':' -f1)
                reality_public_key=$(echo "$reality_keys" | cut -d':' -f2)
                reality_short_id=$(generate_short_id)
                reality_short_id2=$(generate_short_id)
            else
                echo "Warning: Failed to generate Reality keys"
                reality_private_key="FAILED"
                reality_public_key="FAILED"
                reality_short_id="FAILED"
                reality_short_id2="FAILED"
            fi
        fi
    fi
    local reality_keys="${reality_private_key}:${reality_public_key}"
    
    # ========== 生成/复用子域名 ==========
    local wildcard_base=$(echo "$config_json" | jq -r '.domains.wildcard_base // ""')
    local domain_xhttp=""
    local domain_grpc=""
    local domain_trojan=""
    local domain_code_server=""
    
    if [ -n "$wildcard_base" ]; then
        # 复用已有子域名或生成新的
        domain_xhttp=$(get_or_generate "DOMAIN_XHTTP" "echo \$(generate_subdomain).${wildcard_base}")
        domain_grpc=$(get_or_generate "DOMAIN_GRPC" "echo \$(generate_subdomain).${wildcard_base}")
        domain_trojan=$(get_or_generate "DOMAIN_TROJAN" "echo \$(generate_subdomain).${wildcard_base}")
        domain_code_server="code.${wildcard_base}"  # 固定子域名，不变
    fi
    local subscription_domain=$(echo "$config_json" | jq -r '.domains.subscription // ""')
    
    # ========== 生成/复用 XHTTP PATH 和 gRPC Service Name ==========
    local xhttp_path=$(get_or_generate "XHTTP_PATH" "generate_path")
    local grpc_service_name=$(get_or_generate "GRPC_SERVICE_NAME" "generate_service_name")
    local subscription_shortid=$(get_or_generate "SUBSCRIPTION_SHORTID" "generate_short_id")
    
    # 端口和用户
    local xhttp_port=$(echo "$config_json" | jq -r '.protocols.xhttp.port // 8443')
    local grpc_port=$(echo "$config_json" | jq -r '.protocols.grpc.port // 2083')
    local trojan_port=$(echo "$config_json" | jq -r '.protocols.trojan.port // 2087')
    local nginx_port=$(echo "$config_json" | jq -r '.subscription.nginx_port // 2096')
    local haproxy_stats_port=$(echo "$config_json" | jq -r '.haproxy.stats_port // 2053')
    local haproxy_stats_user=$(echo "$config_json" | jq -r '.haproxy.stats_user // "admin"')
    local subscription_user=$(echo "$config_json" | jq -r '.subscription.login_user // "admin"')
    
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
CODE_SERVER_PASSWORD=$code_server_password

# Reality Keys
REALITY_KEYS=$reality_keys
REALITY_PRIVATE_KEY=$reality_private_key
REALITY_PUBLIC_KEY=$reality_public_key
REALITY_SHORT_ID=$reality_short_id
REALITY_SHORT_ID2=$reality_short_id2

# Domains
DOMAIN_XHTTP=$domain_xhttp
DOMAIN_GRPC=$domain_grpc
DOMAIN_TROJAN=$domain_trojan
DOMAIN_CODE_SERVER=$domain_code_server
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
SUBSCRIPTION_USER=$subscription_user
EOF
    
    # 保存到持久化目录（用于热更新）
    cp "$AUTOCONF_FILE" "$PERSISTENT_FILE"
    
    echo ""
    echo "✓ Generated: $AUTOCONF_FILE"
    echo "✓ Persisted: $PERSISTENT_FILE"
    
    if [ -n "$existing_config" ]; then
        echo ""
        echo "Hot reload mode: UUIDs, passwords, shortids, and domains preserved."
        echo "To force regenerate all, use: $0 generate config.json --force"
    fi
    
    echo ""
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
        generate "${2:-scripts/config-template.json}" "${3:-}"
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
  generate <config.json> [--force]  生成自动配置文件
  show                              显示生成的配置文件内容
  export                            导出为环境变量格式

Options:
  --force    强制重新生成所有变量（忽略已有配置）

Hot Reload (热更新):
  默认情况下，如果已存在持久化配置 ($PERSISTENT_FILE)，
  将保留 UUID、密码、密钥、子域名、ShortID 等不变，
  仅更新端口等可变配置。使用 --force 可强制全部重新生成。

Examples:
  $0 generate my-config.json           # 热更新模式
  $0 generate my-config.json --force   # 强制重新生成
  $0 show
  source <($0 export)

Output files:
  - Temporary: $AUTOCONF_FILE
  - Persistent: $PERSISTENT_FILE
EOF
        ;;
esac
