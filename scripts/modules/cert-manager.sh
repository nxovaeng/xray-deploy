#!/bin/bash
# Certificate Manager Module
# Manual DNS + automatic certificate issuance via acme.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Install acme.sh if not present
install_acme() {
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo -e "${YELLOW}Installing acme.sh...${NC}"
        curl https://get.acme.sh | sh -s email="$1"
        source ~/.bashrc
    else
        echo -e "${GREEN}acme.sh already installed${NC}"
    fi
}

# Check DNS propagation
check_dns_propagation() {
    local domain=$1
    local expected_ip=$2
    local max_attempts=10
    local attempt=1
    
    echo -e "${YELLOW}Checking DNS propagation for $domain...${NC}"
    
    while [ $attempt -le $max_attempts ]; do
        local resolved_ip
        resolved_ip=$(dig +short "$domain" A | head -n1)
        
        if [ "$resolved_ip" = "$expected_ip" ]; then
            echo -e "${GREEN}✓ DNS propagated correctly: $domain -> $resolved_ip${NC}"
            return 0
        fi
        
        echo -e "${YELLOW}Attempt $attempt/$max_attempts: $domain resolves to '$resolved_ip' (expected: $expected_ip)${NC}"
        sleep 5
        ((attempt++))
    done
    
    echo -e "${RED}✗ DNS propagation failed after $max_attempts attempts${NC}"
    return 1
}

# Prompt user to configure DNS
prompt_dns_configuration() {
    local domain=$1
    local server_ip=$2
    
    echo ""
    echo -e "${YELLOW}=====================================${NC}"
    echo -e "${YELLOW}DNS Configuration Required${NC}"
    echo -e "${YELLOW}=====================================${NC}"
    echo ""
    echo "Please add the following DNS record:"
    echo ""
    echo -e "${GREEN}Type:${NC}  A"
    echo -e "${GREEN}Name:${NC}  $domain"
    echo -e "${GREEN}Value:${NC} $server_ip"
    echo -e "${GREEN}TTL:${NC}   300 (or minimum allowed)"
    echo ""
    echo "If using Cloudflare:"
    echo "  - Set Proxy status to 'DNS only' (gray cloud) for TLS protocols"
    echo "  - For gRPC/XHTTP with CDN, enable 'Proxied' (orange cloud)"
    echo ""
    echo -e "${YELLOW}=====================================${NC}"
    echo ""
}

# Issue certificate using HTTP-01 challenge
issue_certificate() {
    local domain=$1
    local email=$2
    
    echo -e "${YELLOW}Issuing certificate for $domain...${NC}"
    
    # Stop services that might use port 80
    systemctl stop nginx 2>/dev/null || true
    systemctl stop apache2 2>/dev/null || true
    
    # Issue certificate in standalone mode
    ~/.acme.sh/acme.sh --issue \
        -d "$domain" \
        --standalone \
        --httpport 80 \
        --server letsencrypt \
        --keylength ec-256 \
        --force
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ Certificate issued successfully for $domain${NC}"
        return 0
    else
        echo -e "${RED}✗ Certificate issuance failed for $domain${NC}"
        return 1
    fi
}

# Install certificate to Xray directory
install_certificate() {
    local domain=$1
    local cert_dir="/etc/xray/cert/$domain"
    
    mkdir -p "$cert_dir"
    
    ~/.acme.sh/acme.sh --install-cert \
        -d "$domain" \
        --ecc \
        --fullchain-file "$cert_dir/fullchain.pem" \
        --key-file "$cert_dir/privkey.pem" \
        --reloadcmd "systemctl restart xray"
    
    # Set proper permissions
    chown -R nobody:nogroup "$cert_dir"
    chmod 644 "$cert_dir/fullchain.pem"
    chmod 600 "$cert_dir/privkey.pem"
    
    echo -e "${GREEN}✓ Certificate installed to $cert_dir${NC}"
}

# Setup auto-renewal
setup_auto_renewal() {
    # acme.sh automatically sets up cron job during installation
    echo -e "${GREEN}✓ Auto-renewal is configured via acme.sh cron job${NC}"
    
    # Display renewal command for reference
    echo -e "${YELLOW}Manual renewal command:${NC}"
    echo "~/.acme.sh/acme.sh --renew-all --force"
}

# Issue wildcard certificate using DNS-01 challenge (Cloudflare)
issue_wildcard_certificate() {
    local base_domain=$1
    local email=$2
    local cf_token=$3
    
    echo -e "${YELLOW}Issuing wildcard certificate for *.${base_domain}...${NC}"
    
    # Export Cloudflare API credentials
    export CF_Token="$cf_token"
    export CF_Account_ID=""  # Not required for token
    
    # Issue certificate with DNS-01 challenge
    ~/.acme.sh/acme.sh --issue \
        -d "${base_domain}" \
        -d "*.${base_domain}" \
        --dns dns_cf \
        --server letsencrypt \
        --keylength ec-256 \
        --force
    
    local exit_code=$?
    
    # Clear credentials
    unset CF_Token
    unset CF_Account_ID
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ Wildcard certificate issued successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Wildcard certificate issuance failed${NC}"
        return 1
    fi
}

# Install wildcard certificate for HAProxy
install_wildcard_certificate() {
    local base_domain=$1
    local cert_dir="/etc/xray/cert"
    
    mkdir -p "$cert_dir"
    
    # Install certificate
    ~/.acme.sh/acme.sh --install-cert \
        -d "${base_domain}" \
        -d "*.${base_domain}" \
        --ecc \
        --fullchain-file "$cert_dir/${base_domain}_fullchain.pem" \
        --key-file "$cert_dir/${base_domain}_privkey.pem" \
        --reloadcmd "systemctl reload haproxy nginx xray"
    
    # Create combined PEM for HAProxy (fullchain + key)
    cat "$cert_dir/${base_domain}_fullchain.pem" "$cert_dir/${base_domain}_privkey.pem" > "$cert_dir/${base_domain}.pem"
    
    # Set proper permissions
    chown -R nobody:nogroup "$cert_dir"
    chmod 644 "$cert_dir/${base_domain}_fullchain.pem"
    chmod 644 "$cert_dir/${base_domain}.pem"
    chmod 600 "$cert_dir/${base_domain}_privkey.pem"
    
    echo -e "${GREEN}✓ Wildcard certificate installed to $cert_dir${NC}"
    echo -e "${YELLOW}  - Fullchain: ${base_domain}_fullchain.pem${NC}"
    echo -e "${YELLOW}  - Private key: ${base_domain}_privkey.pem${NC}"
    echo -e "${YELLOW}  - HAProxy combined: ${base_domain}.pem${NC}"
}

# Process certificate for a domain
process_domain_certificate() {
    local domain=$1
    local email=$2
    local server_ip=$3
    local skip_dns_check=${4:-false}
    
    echo ""
    echo -e "${YELLOW}Processing certificate for: $domain${NC}"
    
    # Check if certificate already exists
    if [ -f "/etc/xray/cert/$domain/fullchain.pem" ]; then
        echo -e "${GREEN}Certificate already exists for $domain${NC}"
        read -p "Re-issue certificate? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi
    
    # Prompt for DNS configuration
    prompt_dns_configuration "$domain" "$server_ip"
    
    # Wait for user confirmation
    read -p "Press ENTER after you have configured the DNS record..." -r
    echo ""
    
    # Check DNS propagation
    if [ "$skip_dns_check" != "true" ]; then
        if ! check_dns_propagation "$domain" "$server_ip"; then
            echo -e "${RED}DNS check failed. Continue anyway? (not recommended)${NC}"
            read -p "(y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                return 1
            fi
        fi
    fi
    
    # Issue certificate
    if issue_certificate "$domain" "$email"; then
        install_certificate "$domain"
        return 0
    else
        return 1
    fi
}

# Main function to manage certificates for all domains
manage_certificates() {
    local config_json=$1
    local server_ip=$2
    
    # Parse configuration
    local email
    local auto_issue
    local wildcard_enabled
    local dns_provider
    local dns_api_token
    
    email=$(echo "$config_json" | jq -r '.email')
    auto_issue=$(echo "$config_json" | jq -r '.certificates.auto_issue')
    wildcard_enabled=$(echo "$config_json" | jq -r '.certificates.wildcard // false')
    dns_provider=$(echo "$config_json" | jq -r '.certificates.dns_provider // "cloudflare"')
    dns_api_token=$(echo "$config_json" | jq -r '.certificates.dns_api_token')
    
    if [ "$auto_issue" != "true" ]; then
        echo -e "${YELLOW}Automatic certificate issuance is disabled${NC}"
        return 0
    fi
    
    # Install acme.sh
    install_acme "$email"
    
    # Check if wildcard certificate is enabled
    if [ "$wildcard_enabled" = "true" ]; then
        local wildcard_base
        wildcard_base=$(echo "$config_json" | jq -r '.domains.wildcard_base')
        
        if [ "$wildcard_base" = "null" ]; then
            echo -e "${RED}✗ Wildcard certificate enabled but wildcard_base domain not configured${NC}"
            return 1
        fi
        
        if [ "$dns_api_token" = "null" ] || [ -z "$dns_api_token" ]; then
            echo -e "${RED}✗ DNS API token required for wildcard certificates${NC}"
            echo -e "${YELLOW}Please set certificates.dns_api_token in your configuration${NC}"
            return 1
        fi
        
        echo ""
        echo -e "${YELLOW}=====================================${NC}"
        echo -e "${YELLOW}Wildcard Certificate Setup${NC}"
        echo -e "${YELLOW}=====================================${NC}"
        echo ""
        echo "Domain: *.${wildcard_base}"
        echo "Provider: ${dns_provider}"
        echo ""
        
        # Issue wildcard certificate
        if issue_wildcard_certificate "$wildcard_base" "$email" "$dns_api_token"; then
            install_wildcard_certificate "$wildcard_base"
            echo -e "${GREEN}✓ Wildcard certificate ready for HAProxy and random subdomains${NC}"
        else
            echo -e "${RED}✗ Failed to issue wildcard certificate${NC}"
            return 1
        fi
    fi
    
    # Get subscription domain
    local sub_domain
    local cdn_domain
    sub_domain=$(echo "$config_json" | jq -r '.domains.subscription')
    cdn_domain=$(echo "$config_json" | jq -r '.domains.cdn_domain')
    
    # Process subscription domain certificate
    local domains=()
    [ "$sub_domain" != "null" ] && domains+=("$sub_domain")
    [ "$cdn_domain" != "null" ] && domains+=("$cdn_domain")
    
    if [ ${#domains[@]} -eq 0 ]; then
        echo -e "${YELLOW}No additional domains require certificates${NC}"
        return 0
    fi
    
    # Process each domain
    local failed_domains=()
    for domain in "${domains[@]}"; do
        if ! process_domain_certificate "$domain" "$email" "$server_ip"; then
            failed_domains+=("$domain")
        fi
    done
    
    # Setup auto-renewal
    setup_auto_renewal
    
    # Report results
    echo ""
    echo -e "${YELLOW}=====================================${NC}"
    echo -e "${YELLOW}Certificate Management Summary${NC}"
    echo -e "${YELLOW}=====================================${NC}"
    
    if [ ${#failed_domains[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ All certificates issued successfully${NC}"
    else
        echo -e "${RED}✗ Failed to issue certificates for:${NC}"
        for domain in "${failed_domains[@]}"; do
            echo -e "  ${RED}- $domain${NC}"
        done
    fi
    
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
manage_certificates "$CONFIG_JSON" "$SERVER_IP"
