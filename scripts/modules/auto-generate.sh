#!/bin/bash
# Auto-generated Variables - 生成到单个文件
# 自动生成 UUID、密码、域名等，全部写入 .env 文件

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

# 生成随机子域名
generate_subdomain() {
    openssl rand -hex 3 | head -c 6
}

# 生成随机 PATH（XHTTP）- 预定义路径
generate_path() {
    local paths=("/api" "/download" "/upload" "/files" "/data" "/static" "/media" "/resources" "/assets")
    local idx=$((RANDOM % ${#paths[@]}))
    echo "${paths[$idx]}"
}

# 生成随机 PATH（8-12位随机字符）
generate_random_path() {
    local length=$((8 + RANDOM % 5))  # 8-12
    echo "/$(openssl rand -hex $((length / 2 + 1)) | head -c $length)"
}

# 生成随机 Service Name（gRPC）
generate_service_name() {
    local names=("GunService" "ProxyService" "TransportService" "StreamService" "TunnelService" "RelayService" "GatewayService" "RouteService")
    local idx=$((RANDOM % ${#names[@]}))
    echo "${names[$idx]}"
}

# 生成短ID（Subscription）
generate_short_id() {
    openssl rand -hex 8
}

# 生成完整的自动配置文件
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
    
    # ========== 热更新逻辑 ==========
    local existing_config=""
    if [ -f "$PERSISTENT_FILE" ] && [ "$force_regenerate" = false ]; then
        echo "✓ Found existing config, preserving UUIDs/passwords (hot reload mode)"
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
        
        if [ -n "$existing_value" ]; then
            echo "$existing_value"
        else
            eval "$generate_cmd"
        fi
    }
    
    # ========== 生成/复用 UUID ==========
    local uuid_xhttp=$(get_or_generate "UUID_XHTTP" "generate_uuid")
    local uuid_grpc=$(get_or_generate "UUID_GRPC" "generate_uuid")
    
    # ========== 生成/复用密码 ==========
    local haproxy_stats_password=$(echo "$config_json" | jq -r '.haproxy.stats_password // "auto-generate"')
    local subscription_password=$(echo "$config_json" | jq -r '.subscription.login_password // "auto-generate"')
    local code_server_password=$(echo "$config_json" | jq -r '.code_server.password // "auto-generate"')
    
    if [ "$haproxy_stats_password" = "null" ] || [ "$haproxy_stats_password" = "auto-generate" ]; then
        haproxy_stats_password=$(get_or_generate "HAPROXY_STATS_PASSWORD" "generate_password")
    fi
    if [ "$subscription_password" = "null" ] || [ "$subscription_password" = "auto-generate" ]; then
        subscription_password=$(get_or_generate "SUBSCRIPTION_PASSWORD" "generate_password")
    fi
    if [ "$code_server_password" = "null" ] || [ "$code_server_password" = "auto-generate" ]; then
        code_server_password=$(get_or_generate "CODE_SERVER_PASSWORD" "generate_password")
    fi
    
    # ========== 生成/复用子域名 ==========
    local wildcard_base=$(echo "$config_json" | jq -r '.domains.wildcard_base // ""')
    local domain_xhttp=""
    local domain_grpc=""
    local domain_code_server=""
    local domain_warp=""
    
    if [ -n "$wildcard_base" ]; then
        domain_xhttp=$(get_or_generate "DOMAIN_XHTTP" "echo \$(generate_subdomain).${wildcard_base}")
        domain_grpc=$(get_or_generate "DOMAIN_GRPC" "echo \$(generate_subdomain).${wildcard_base}")
        domain_code_server="code.${wildcard_base}"
        domain_warp="warp.${wildcard_base}"
        domain_proton=$(get_or_generate "DOMAIN_PROTON" "echo \$(generate_subdomain).${wildcard_base}")
    fi
    local subscription_domain=$(echo "$config_json" | jq -r '.domains.subscription // ""')
    
    # ========== 生成/复用 XHTTP PATH 和 gRPC Service Name ==========
    local xhttp_path=$(get_or_generate "XHTTP_PATH" "generate_path")
    local grpc_service_name=$(get_or_generate "GRPC_SERVICE_NAME" "generate_service_name")
    local subscription_shortid=$(get_or_generate "SUBSCRIPTION_SHORTID" "generate_short_id")
    local proton_path=$(get_or_generate "PROTON_PATH" "generate_random_path")
    local warp_path=$(get_or_generate "WARP_PATH" "generate_random_path")
    
    # 用户名
    local haproxy_stats_user=$(echo "$config_json" | jq -r '.haproxy.stats_user // "admin"')
    local subscription_user=$(echo "$config_json" | jq -r '.subscription.login_user // "admin"')
    
    # 生成统一的配置文件
    cat > "$AUTOCONF_FILE" <<EOF
# Auto-generated Variables - $(date '+%Y-%m-%d %H:%M:%S')
# Generated by auto-generate.sh

# ========== Fixed Internal Ports (Single Source of Truth) ==========
# Using high uncommon ports to avoid conflicts
PORT_XHTTP=41443
PORT_GRPC=42083
PORT_WARP_XHTTP=43444
PORT_PROTON_XHTTP=43445
PORT_NGINX=44096
PORT_CODE_SERVER=45443
PORT_HAPROXY_STATS=46053

# ========== UUIDs ==========
UUID_XHTTP=$uuid_xhttp
UUID_GRPC=$uuid_grpc

# ========== Passwords ==========
HAPROXY_STATS_PASSWORD=$haproxy_stats_password
SUBSCRIPTION_PASSWORD=$subscription_password
CODE_SERVER_PASSWORD=$code_server_password

# ========== Domains ==========
DOMAIN_XHTTP=$domain_xhttp
DOMAIN_GRPC=$domain_grpc
DOMAIN_CODE_SERVER=$domain_code_server
DOMAIN_WARP=$domain_warp
DOMAIN_PROTON=$domain_proton
SUBSCRIPTION_DOMAIN=$subscription_domain
WILDCARD_BASE=$wildcard_base

# ========== XHTTP and gRPC ==========
XHTTP_PATH=$xhttp_path
GRPC_SERVICE_NAME=$grpc_service_name
WARP_PATH=$warp_path
PROTON_PATH=$proton_path

# ========== Users ==========
HAPROXY_STATS_USER=$haproxy_stats_user
SUBSCRIPTION_USER=$subscription_user

# ========== Subscription ==========
SUBSCRIPTION_SHORTID=$subscription_shortid
EOF
    
    # 保存到持久化目录
    cp "$AUTOCONF_FILE" "$PERSISTENT_FILE"
    
    echo ""
    echo "✓ Generated: $AUTOCONF_FILE"
    echo "✓ Persisted: $PERSISTENT_FILE"
    
    if [ -n "$existing_config" ]; then
        echo ""
        echo "Hot reload mode: UUIDs, passwords, and domains preserved."
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
  --force    强制重新生成所有变量

Hot Reload (热更新):
  默认情况下，如果已存在持久化配置，将保留 UUID、密码、子域名等不变。
  使用 --force 可强制全部重新生成。

Examples:
  $0 generate my-config.json
  $0 generate my-config.json --force
  $0 show

Output files:
  - Temporary: $AUTOCONF_FILE
  - Persistent: $PERSISTENT_FILE
EOF
        ;;
esac
