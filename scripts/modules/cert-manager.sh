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
    local email=$1
    local acme_home="/root/.acme.sh"
    
    if [ -f "$acme_home/acme.sh" ]; then
        echo -e "${GREEN}acme.sh already installed${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Installing acme.sh...${NC}"
    
    # Install acme.sh with proper flags for root/sudo usage
    curl https://get.acme.sh | sh -s -- --install-online -m "$email" --home "$acme_home"
    
    # Create alias for easier access
    export ACME_HOME="$acme_home"
    
    echo -e "${GREEN}✓ acme.sh installed to $acme_home${NC}"
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
        # Use dig to get final IP (handles CNAME chains)
        resolved_ip=$(dig +short "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        
        # If no IP found, try with @8.8.8.8
        if [ -z "$resolved_ip" ]; then
            resolved_ip=$(dig +short "$domain" @8.8.8.8 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        
        if [ "$resolved_ip" = "$expected_ip" ]; then
            echo -e "${GREEN}✓ DNS propagated correctly: $domain -> $resolved_ip${NC}"
            return 0
        fi
        
        # Also accept if domain resolves to ANY IP (for CDN proxied domains)
        if [ -n "$resolved_ip" ]; then
            echo -e "${YELLOW}$domain resolves to $resolved_ip (expected: $expected_ip)${NC}"
            echo -e "${YELLOW}If using CDN proxy, this may be expected${NC}"
        fi
        
        echo -e "${YELLOW}Attempt $attempt/$max_attempts: waiting for DNS propagation...${NC}"
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
    /root/.acme.sh/acme.sh --home /root/.acme.sh --issue \
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
    
    /root/.acme.sh/acme.sh --home /root/.acme.sh --install-cert \
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
    echo "/root/.acme.sh/acme.sh --renew-all --force"
}

# Issue wildcard certificate using DNS-01 challenge (Cloudflare)
issue_wildcard_certificate() {
    local base_domain=$1
    local email=$2
    local cf_token=$3
    local force_renew=${4:-false}
    
    # Check if certificate already exists in acme.sh
    local cert_path="/root/.acme.sh/${base_domain}_ecc"
    if [ -f "$cert_path/${base_domain}.cer" ] && [ "$force_renew" != "true" ]; then
        # Check if certificate is still valid (not expiring in 30 days)
        local expiry_date
        expiry_date=$(openssl x509 -in "$cert_path/${base_domain}.cer" -noout -enddate 2>/dev/null | cut -d= -f2)
        if [ -n "$expiry_date" ]; then
            local expiry_epoch
            local now_epoch
            local days_left
            expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            
            if [ "$days_left" -gt 30 ]; then
                echo -e "${GREEN}✓ Valid certificate found (expires in ${days_left} days), skipping issuance${NC}"
                return 0
            else
                echo -e "${YELLOW}Certificate expires in ${days_left} days, renewing...${NC}"
            fi
        fi
    fi
    
    echo -e "${YELLOW}Issuing wildcard certificate for *.${base_domain}...${NC}"
      
    # Export Cloudflare API credentials
    export CF_Token="$cf_token"
    export CF_Account_ID=""  # Not required for token
    
    # Issue certificate with DNS-01 challenge (without --force to respect rate limits)
    /root/.acme.sh/acme.sh --home /root/.acme.sh --issue \
        -d "${base_domain}" \
        -d "*.${base_domain}" \
        --dns dns_cf \
        --server letsencrypt \
        --keylength ec-256
    
    local exit_code=$?
    
    # Clear credentials
    unset CF_Token
    unset CF_Account_ID
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ Wildcard certificate issued successfully${NC}"
        return 0
    elif [ $exit_code -eq 2 ]; then
        # Exit code 2 means cert not due for renewal
        echo -e "${GREEN}✓ Certificate already exists and is valid${NC}"
        return 0
    else
        echo -e "${RED}✗ Wildcard certificate issuance failed (exit code: $exit_code)${NC}"
        return 1
    fi
}

# Install wildcard certificate for HAProxy
install_wildcard_certificate() {
    local base_domain=$1
    local cert_dir="/etc/xray/cert"
    local reload_script="/etc/xray/cert/reload-services.sh"
    
    mkdir -p "$cert_dir"
    
    # Create reload script with certificate merge command
    cat > "$reload_script" << 'SCRIPT'
#!/bin/bash
# Certificate reload script - auto-generated
# This script is called by acme.sh when certificates are renewed
CERT_DIR="/etc/xray/cert"

# Regenerate combined PEM for HAProxy
cat "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem" > "$CERT_DIR/haproxy.pem"
chmod 644 "$CERT_DIR/haproxy.pem"

# Reload/restart services
systemctl reload haproxy 2>/dev/null || true
systemctl restart xray 2>/dev/null || true
systemctl reload nginx 2>/dev/null || true
SCRIPT
    chmod +x "$reload_script"
    
    # Install certificate directly to standard names (no copy needed after renewal)
    echo -e "${YELLOW}Installing certificate to $cert_dir...${NC}"
    
    if ! /root/.acme.sh/acme.sh --home /root/.acme.sh --install-cert \
        -d "${base_domain}" \
        --ecc --force \
        --fullchain-file "$cert_dir/fullchain.pem" \
        --key-file "$cert_dir/privkey.pem" \
        --reloadcmd "$reload_script"; then
        echo -e "${RED}✗ acme.sh --install-cert returned non-zero, but continuing...${NC}"
    fi
    
    # Verify certificate files exist
    if [ ! -f "$cert_dir/fullchain.pem" ]; then
        echo -e "${RED}✗ Certificate file not found after install${NC}"
        return 1
    fi
    
    # Create combined PEM for HAProxy (fullchain + key)
    cat "$cert_dir/fullchain.pem" "$cert_dir/privkey.pem" > "$cert_dir/haproxy.pem"
    
    # Set proper permissions (all files need to be readable by services)
    chmod 644 "$cert_dir/fullchain.pem"
    chmod 644 "$cert_dir/privkey.pem"
    chmod 644 "$cert_dir/haproxy.pem"
    
    echo -e "${GREEN}✓ Wildcard certificate installed to $cert_dir${NC}"
    echo -e "${YELLOW}  - Fullchain: fullchain.pem${NC}"
    echo -e "${YELLOW}  - Private key: privkey.pem${NC}"
    echo -e "${YELLOW}  - HAProxy combined: haproxy.pem${NC}"
    echo -e "${YELLOW}  - Reload script: $reload_script${NC}"
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
    
    # If wildcard is enabled, skip individual subdomain certificates
    # Wildcard certificate covers *.domain.com
    if [ "$wildcard_enabled" = "true" ]; then
        echo -e "${GREEN}✓ Wildcard certificate covers all subdomains, skipping individual certificates${NC}"
        return 0
    fi
    
    # Get subscription domain (only needed if wildcard is NOT enabled)
    local sub_domain
    sub_domain=$(echo "$config_json" | jq -r '.domains.subscription')
    
    # Process subscription domain certificate
    local domains=()
    [ "$sub_domain" != "null" ] && domains+=("$sub_domain")
    
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
