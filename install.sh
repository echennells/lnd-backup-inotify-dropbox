#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect LND configuration
detect_lnd_config() {
    local lnd_dir="${LND_DATA_DIR:-$HOME/.lnd}"
    local lnd_conf="$lnd_dir/lnd.conf"
    local network="mainnet"
    
    if [[ -f "$lnd_conf" ]]; then
        if grep -q "bitcoin.network=testnet" "$lnd_conf"; then
            network="testnet"
        elif grep -q "bitcoin.network=signet" "$lnd_conf"; then
            network="signet"
        elif grep -q "bitcoin.network=regtest" "$lnd_conf"; then
            network="regtest"
        fi
    fi
    
    # Check for mutinynet
    if [[ -f "${BITCOIN_DATA_DIR:-$HOME/.bitcoin}/bitcoin.conf" ]]; then
        if grep -q "signetchallenge=512102f7561d208dd9ae99bf497273e16f389bdbd6c4742ddb8e6b216e64fa2928ad8f51ae" "${BITCOIN_DATA_DIR:-$HOME/.bitcoin}/bitcoin.conf"; then
            network="signet-mutinynet"
            log_info "Detected Mutinynet configuration"
        fi
    fi
    
    echo "$network"
}

# Get channel.backup path based on network
get_backup_path() {
    local lnd_dir="${LND_DATA_DIR:-$HOME/.lnd}"
    local network="$1"
    
    case "$network" in
        mainnet)
            echo "$lnd_dir/data/chain/bitcoin/mainnet/channel.backup"
            ;;
        testnet)
            echo "$lnd_dir/data/chain/bitcoin/testnet/channel.backup"
            ;;
        signet|signet-mutinynet)
            echo "$lnd_dir/data/chain/bitcoin/signet/channel.backup"
            ;;
        regtest)
            echo "$lnd_dir/data/chain/bitcoin/regtest/channel.backup"
            ;;
        *)
            log_error "Unknown network: $network"
            exit 1
            ;;
    esac
}

# Setup directories based on scope
if [[ $EUID -eq 0 ]]; then
    SYSTEMD_SCOPE="system"
    SYSTEMD_DIR="/etc/systemd/system"
    SERVICE_USER="${SERVICE_USER:-lnd}"
    CONFIG_DIR="/etc/lnd-backup"
    CRED_DIR="/etc/credstore/lnd-backup"
    INSTALL_DIR="/usr/local/bin"
    WANTED_BY="multi-user.target"
else
    SYSTEMD_SCOPE="user"
    SYSTEMD_DIR="$HOME/.config/systemd/user"
    SERVICE_USER="$USER"
    CONFIG_DIR="$HOME/.config/lnd-backup"
    CRED_DIR="$HOME/.config/lnd-backup/credentials"
    INSTALL_DIR="$HOME/.local/bin"
    WANTED_BY="default.target"
fi

log_info "Installing LND Backup Monitor"
log_info "Scope: $SYSTEMD_SCOPE"
log_info "User: $SERVICE_USER"

# Detect network
NETWORK=$(detect_lnd_config)
BACKUP_PATH=$(get_backup_path "$NETWORK")
LND_DATA_DIR="${LND_DATA_DIR:-$HOME/.lnd}"

log_info "Detected network: $NETWORK"
log_info "Channel backup path: $BACKUP_PATH"

# Check dependencies
log_info "Checking dependencies..."
MISSING_DEPS=()

if ! command -v inotifywait &> /dev/null; then
    MISSING_DEPS+=("inotify-tools")
fi

if ! command -v python3 &> /dev/null; then
    MISSING_DEPS+=("python3")
fi

if ! command -v pip3 &> /dev/null; then
    MISSING_DEPS+=("python3-pip")
fi

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    log_error "Missing dependencies: ${MISSING_DEPS[*]}"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        log_info "Install with: sudo apt install ${MISSING_DEPS[*]}"
    fi
    exit 1
fi

# Install Python dependencies
log_info "Installing Python dependencies..."
pip3 install --user -r "$SCRIPT_DIR/requirements.txt"

# Create directories
log_info "Creating directories..."
mkdir -p "$CONFIG_DIR"
mkdir -p "$SYSTEMD_DIR"
mkdir -p "$CRED_DIR"
mkdir -p "$INSTALL_DIR"

if [[ $EUID -eq 0 ]]; then
    chmod 700 "$CRED_DIR"
fi

# Handle storage connection string
if [[ -z "${STORAGE_CONNECTION_STRING:-}" ]]; then
    log_warn "STORAGE_CONNECTION_STRING not set in environment"
    echo "Supported formats:"
    echo "  dropbox:TOKEN"
    echo "  azure:CONNECTION_STRING"
    echo
    read -p "Enter your storage connection string: " STORAGE_CONNECTION_STRING
fi

# Store credentials securely
if command -v systemd-creds &> /dev/null && systemctl --version | grep -q "systemd 24[6-9]\|systemd 25[0-9]"; then
    log_info "Using systemd-creds for secure credential storage..."
    echo -n "$STORAGE_CONNECTION_STRING" | systemd-creds encrypt - "$CRED_DIR/storage.connection" 2>/dev/null || {
        log_warn "systemd-creds failed, using restricted file"
        echo -n "$STORAGE_CONNECTION_STRING" > "$CRED_DIR/storage.connection"
        chmod 600 "$CRED_DIR/storage.connection"
    }
    CREDENTIAL_SECTION="LoadCredential=storage.connection:$CRED_DIR/storage.connection
Environment=\"CREDENTIALS_DIRECTORY=%d/credentials\""
else
    log_info "Storing connection string in restricted file..."
    echo -n "$STORAGE_CONNECTION_STRING" > "$CRED_DIR/storage.connection"
    chmod 600 "$CRED_DIR/storage.connection"
    CREDENTIAL_SECTION="Environment=\"STORAGE_CONNECTION_STRING_FILE=$CRED_DIR/storage.connection\""
fi

# Copy and configure templates
log_info "Installing configuration..."

# Process config template
sed -e "s|%NETWORK%|$NETWORK|g" \
    -e "s|%DATE%|$(date)|g" \
    -e "s|%HOSTNAME%|${HOSTNAME:-unknown}|g" \
    -e "s|%LND_DATA_DIR%|$LND_DATA_DIR|g" \
    -e "s|%CHANNEL_BACKUP_PATH%|$BACKUP_PATH|g" \
    -e "s|%CHECK_INTERVAL%|${CHECK_INTERVAL:-300}|g" \
    -e "s|%TAPD_DATA_DIR%|${TAPD_DATA_DIR:-$HOME/.tapd}|g" \
    -e "s|%ENABLE_TAPD%|${ENABLE_TAPD:-false}|g" \
    -e "s|%LOG_LEVEL%|${LOG_LEVEL:-info}|g" \
    "$SCRIPT_DIR/templates/config" > "$CONFIG_DIR/config"

# Install scripts
log_info "Installing scripts..."
cp "$SCRIPT_DIR/templates/lnd-backup-monitor.sh" "$INSTALL_DIR/lnd-backup-monitor"
cp "$SCRIPT_DIR/backup.py" "$INSTALL_DIR/backup.py"
cp "$SCRIPT_DIR/storage_providers.py" "$INSTALL_DIR/storage_providers.py"
cp "$SCRIPT_DIR/dropbox_provider.py" "$INSTALL_DIR/dropbox_provider.py"
cp "$SCRIPT_DIR/azure_provider.py" "$INSTALL_DIR/azure_provider.py"

# Process and install wrapper script
sed -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
    "$SCRIPT_DIR/templates/lnd-backup-wrapper.sh" > "$INSTALL_DIR/lnd-backup-wrapper"

chmod +x "$INSTALL_DIR/lnd-backup-monitor"
chmod +x "$INSTALL_DIR/lnd-backup-wrapper"
chmod +x "$INSTALL_DIR/backup.py"

# Process systemd service template
if [[ $SYSTEMD_SCOPE == "system" ]]; then
    USER_GROUP_SECTION="User=$SERVICE_USER
Group=$SERVICE_USER"
else
    USER_GROUP_SECTION=""
fi

sed -e "s|%NETWORK%|$NETWORK|g" \
    -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
    -e "s|%CONFIG_DIR%|$CONFIG_DIR|g" \
    -e "s|%LND_DATA_DIR%|$LND_DATA_DIR|g" \
    -e "s|%WANTED_BY%|$WANTED_BY|g" \
    -e "s|%USER_GROUP_SECTION%|$USER_GROUP_SECTION|g" \
    -e "s|%CREDENTIAL_SECTION%|$CREDENTIAL_SECTION|g" \
    "$SCRIPT_DIR/templates/lnd-backup.service" > "$SYSTEMD_DIR/lnd-backup.service"

# Process and install uninstall script
sed -e "s|%SYSTEMD_SCOPE%|$SYSTEMD_SCOPE|g" \
    -e "s|%SYSTEMD_DIR%|$SYSTEMD_DIR|g" \
    -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
    -e "s|%CONFIG_DIR%|$CONFIG_DIR|g" \
    -e "s|%CRED_DIR%|$CRED_DIR|g" \
    "$SCRIPT_DIR/templates/uninstall.sh" > "$CONFIG_DIR/uninstall.sh"
chmod +x "$CONFIG_DIR/uninstall.sh"

# Reload systemd
log_info "Reloading systemd..."
if [[ $SYSTEMD_SCOPE == "system" ]]; then
    systemctl daemon-reload
else
    systemctl --user daemon-reload
fi

# Summary
echo
log_info "Installation complete!"
echo
echo "Configuration: $CONFIG_DIR/config"
echo "Service: $SYSTEMD_DIR/lnd-backup.service"
echo "Network: $NETWORK"
echo
echo "To start the service:"
if [[ $SYSTEMD_SCOPE == "system" ]]; then
    echo "  sudo systemctl enable --now lnd-backup"
    echo "  sudo systemctl status lnd-backup"
    echo "  sudo journalctl -fu lnd-backup"
else
    echo "  systemctl --user enable --now lnd-backup"
    echo "  systemctl --user status lnd-backup"
    echo "  journalctl --user -fu lnd-backup"
fi
echo
echo "To uninstall:"
echo "  $CONFIG_DIR/uninstall.sh"