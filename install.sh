#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env file if it exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    log_info "Loading environment from .env file..."
    # Use set -a/+a to export all variables defined in .env
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
    log_info "Environment variables loaded from .env file"
else
    if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
        log_info "No .env file found, but .env.example exists. Copy it to .env and configure STORAGE_CONNECTION_STRING"
    fi
fi

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

# Create lndbackup user if running as root
create_backup_user() {
    if [[ $EUID -eq 0 ]]; then
        # Create lndbackup group if it doesn't exist
        if ! getent group lndbackup >/dev/null 2>&1; then
            log_info "Creating lndbackup group..."
            if ! groupadd --system lndbackup; then
                log_error "Failed to create lndbackup group"
                return 1
            fi
        fi

        # Create lndbackup user if it doesn't exist
        if ! getent passwd lndbackup >/dev/null 2>&1; then
            log_info "Creating lndbackup user..."
            if ! useradd --system --shell /bin/false --home-dir /var/lib/lndbackup \
                        --create-home --gid lndbackup lndbackup; then
                log_error "Failed to create lndbackup user"
                return 1
            fi
        fi
    fi
    return 0
}

# Setup directories based on scope
if [[ $EUID -eq 0 ]]; then
    create_backup_user
    SYSTEMD_SCOPE="system"
    SYSTEMD_DIR="/etc/systemd/system"
    SERVICE_USER="lndbackup"
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

# Detect network (allow override from environment)
if [[ -n "${NETWORK:-}" ]]; then
    log_info "Using specified network: $NETWORK"
else
    NETWORK=$(detect_lnd_config)
fi
BACKUP_PATH=$(get_backup_path "$NETWORK")
LND_DATA_DIR="${LND_DATA_DIR:-$HOME/.lnd}"

log_info "Detected network: $NETWORK"
log_info "Channel backup path: $BACKUP_PATH"

# Check if we can access the backup path or its directory
# NOTE: We need to check accessibility for the SERVICE_USER (lndbackup), not current user
NEEDS_PERMISSION_SETUP=false
if [[ -f "$BACKUP_PATH" ]]; then
    if [[ $EUID -eq 0 ]] && [[ "$SERVICE_USER" != "$USER" ]]; then
        # When running as root but service will run as different user, check if that user can access
        if ! sudo -u "$SERVICE_USER" test -r "$BACKUP_PATH" 2>/dev/null; then
            log_warn "Service user ($SERVICE_USER) cannot read channel backup file at $BACKUP_PATH"
            NEEDS_PERMISSION_SETUP=true
        fi
    elif ! [[ -r "$BACKUP_PATH" ]]; then
        log_warn "Cannot read channel backup file at $BACKUP_PATH"
        NEEDS_PERMISSION_SETUP=true
    fi
elif [[ -d "$(dirname "$BACKUP_PATH")" ]]; then
    if [[ $EUID -eq 0 ]] && [[ "$SERVICE_USER" != "$USER" ]]; then
        # When running as root but service will run as different user, check if that user can access
        if ! sudo -u "$SERVICE_USER" test -r "$(dirname "$BACKUP_PATH")" 2>/dev/null; then
            log_warn "Service user ($SERVICE_USER) cannot access LND data directory at $(dirname "$BACKUP_PATH")"
            NEEDS_PERMISSION_SETUP=true
        fi
    elif ! [[ -r "$(dirname "$BACKUP_PATH")" ]]; then
        log_warn "Cannot access LND data directory"
        NEEDS_PERMISSION_SETUP=true
    fi
else
    # Check if parent directories exist but aren't accessible
    PARENT_DIR="$LND_DATA_DIR"
    if [[ -d "$PARENT_DIR" ]]; then
        if [[ $EUID -eq 0 ]] && [[ "$SERVICE_USER" != "$USER" ]]; then
            # Check if service user can access the data subdirectory
            if ! sudo -u "$SERVICE_USER" test -r "$PARENT_DIR/data" 2>/dev/null; then
                log_warn "Service user ($SERVICE_USER) cannot access LND data directory at $PARENT_DIR/data"
                NEEDS_PERMISSION_SETUP=true
            fi
        elif ! [[ -r "$PARENT_DIR/data" ]] 2>/dev/null; then
            log_warn "LND data directory exists but is not accessible"
            NEEDS_PERMISSION_SETUP=true
        fi
    fi
fi

# Check dependencies BEFORE trying to use them
log_info "Checking dependencies..."
MISSING_DEPS=()

if ! command -v inotifywait &> /dev/null; then
    MISSING_DEPS+=("inotify-tools")
fi

if ! command -v python3 &> /dev/null; then
    MISSING_DEPS+=("python3")
fi

if ! command -v curl &> /dev/null; then
    MISSING_DEPS+=("curl")
fi

if ! command -v setfacl &> /dev/null; then
    MISSING_DEPS+=("acl")
fi

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    log_warn "Missing dependencies: ${MISSING_DEPS[*]}"
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        log_info "Installing missing dependencies..."
        if command -v apt &> /dev/null; then
            sudo apt update && sudo apt install -y ${MISSING_DEPS[*]} || {
                log_error "Failed to install dependencies"
                exit 1
            }
        else
            log_error "Package manager not found. Please install manually: ${MISSING_DEPS[*]}"
            exit 1
        fi
    else
        log_error "Unsupported OS. Please install manually: ${MISSING_DEPS[*]}"
        exit 1
    fi
fi

# Handle permission setup if needed
if [[ "$NEEDS_PERMISSION_SETUP" == "true" ]]; then
    log_info "Setting up permissions for LND data access..."

    # Create lndbackup group if it doesn't exist
    if ! getent group lndbackup >/dev/null 2>&1; then
        if [[ $EUID -eq 0 ]]; then
            groupadd lndbackup
        else
            log_info "Creating lndbackup group (requires sudo)..."
            sudo groupadd lndbackup || {
                log_error "Failed to create lndbackup group"
                log_info "You may need to manually set up permissions"
            }
        fi
    fi

        # Add service user to lndbackup group (usermod -a handles existing membership)
        if getent group lndbackup >/dev/null 2>&1; then
            if [[ $EUID -eq 0 ]]; then
                usermod -a -G lndbackup "$SERVICE_USER" && log_info "Added $SERVICE_USER to lndbackup group"
            else
                log_info "Adding $SERVICE_USER to lndbackup group (requires sudo)..."
                sudo usermod -a -G lndbackup "$SERVICE_USER" && log_info "Added $SERVICE_USER to lndbackup group"
            fi
        fi

        # Try to set group permissions on LND data
        if [[ -d "$LND_DATA_DIR/data" ]]; then
            log_info "Setting group permissions on LND data (may require sudo)..."
            PERMISSION_SUCCESS=true

            if [[ $EUID -eq 0 ]]; then
                if ! chgrp -R lndbackup "$LND_DATA_DIR/data"; then
                    log_error "Failed to set group ownership on $LND_DATA_DIR/data"
                    PERMISSION_SUCCESS=false
                fi

                if ! chmod -R g+rX "$LND_DATA_DIR/data"; then
                    log_error "Failed to set group permissions on $LND_DATA_DIR/data"
                    PERMISSION_SUCCESS=false
                fi

                # If LND_DATA_DIR is under a home directory, grant traverse permission
                if [[ "$LND_DATA_DIR" =~ ^/home/ ]]; then
                    # Extract the home directory path (e.g., /home/ubuntu from /home/ubuntu/volumes/.lnd)
                    HOME_DIR=$(echo "$LND_DATA_DIR" | grep -oE "^/home/[^/]+")
                    log_info "Granting traverse permissions through $HOME_DIR..."

                    # Grant only execute (traverse) permission, not read
                    if ! setfacl -m u:lndbackup:x "$HOME_DIR"; then
                        log_error "Failed to set ACL traverse permission on $HOME_DIR"
                        PERMISSION_SUCCESS=false
                    fi

                    # Grant traverse on intermediate directories if needed
                    CURRENT_PATH="$HOME_DIR"
                    REMAINING_PATH="${LND_DATA_DIR#$HOME_DIR/}"
                    IFS='/' read -ra DIRS <<< "$REMAINING_PATH"
                    for dir in "${DIRS[@]}"; do
                        CURRENT_PATH="$CURRENT_PATH/$dir"
                        if [[ -d "$CURRENT_PATH" ]]; then
                            if ! setfacl -m u:lndbackup:x "$CURRENT_PATH"; then
                                log_error "Failed to set ACL traverse permission on $CURRENT_PATH"
                                PERMISSION_SUCCESS=false
                            fi
                        fi
                    done
                fi

                # Set default ACL so new files created by LND are readable by lndbackup group
                for network_dir in "$LND_DATA_DIR"/data/chain/bitcoin/*/; do
                    if [[ -d "$network_dir" ]]; then
                        if ! setfacl -d -m g:lndbackup:r "$network_dir"; then
                            log_error "Failed to set default ACL on $network_dir"
                            PERMISSION_SUCCESS=false
                        fi
                    fi
                done
            else
                if ! sudo chgrp -R lndbackup "$LND_DATA_DIR/data"; then
                    log_error "Failed to set group ownership on $LND_DATA_DIR/data (sudo required)"
                    PERMISSION_SUCCESS=false
                fi

                if ! sudo chmod -R g+rX "$LND_DATA_DIR/data"; then
                    log_error "Failed to set group permissions on $LND_DATA_DIR/data (sudo required)"
                    PERMISSION_SUCCESS=false
                fi

                # If LND_DATA_DIR is under a home directory, grant traverse permission
                if [[ "$LND_DATA_DIR" =~ ^/home/ ]]; then
                    # Extract the home directory path (e.g., /home/ubuntu from /home/ubuntu/volumes/.lnd)
                    HOME_DIR=$(echo "$LND_DATA_DIR" | grep -oE "^/home/[^/]+")
                    log_info "Granting traverse permissions through $HOME_DIR..."

                    # Grant only execute (traverse) permission, not read
                    if ! sudo setfacl -m u:lndbackup:x "$HOME_DIR"; then
                        log_error "Failed to set ACL traverse permission on $HOME_DIR"
                        PERMISSION_SUCCESS=false
                    fi

                    # Grant traverse on intermediate directories if needed
                    CURRENT_PATH="$HOME_DIR"
                    REMAINING_PATH="${LND_DATA_DIR#$HOME_DIR/}"
                    IFS='/' read -ra DIRS <<< "$REMAINING_PATH"
                    for dir in "${DIRS[@]}"; do
                        CURRENT_PATH="$CURRENT_PATH/$dir"
                        if [[ -d "$CURRENT_PATH" ]]; then
                            if ! sudo setfacl -m u:lndbackup:x "$CURRENT_PATH"; then
                                log_error "Failed to set ACL traverse permission on $CURRENT_PATH"
                                PERMISSION_SUCCESS=false
                            fi
                        fi
                    done
                fi

                # Set default ACL so new files created by LND are readable by lndbackup group
                for network_dir in "$LND_DATA_DIR"/data/chain/bitcoin/*/; do
                    if [[ -d "$network_dir" ]]; then
                        if ! sudo setfacl -d -m g:lndbackup:r "$network_dir"; then
                            log_error "Failed to set default ACL on $network_dir"
                            PERMISSION_SUCCESS=false
                        fi
                    fi
                done
            fi

            if [[ "$PERMISSION_SUCCESS" != "true" ]]; then
                log_error "Critical permission setup failed - manual intervention required"
                log_error "Please check that you have sudo permissions and proper directory access"
                exit 1
            fi
        fi

        # Force system service for permission handling
        if [[ "$SYSTEMD_SCOPE" == "user" ]]; then
            log_info "Switching to system service for permission handling..."
            SYSTEMD_SCOPE="system"
            SYSTEMD_DIR="/etc/systemd/system"
            SERVICE_USER="lndbackup"
            CONFIG_DIR="/etc/lnd-backup"
            CRED_DIR="/etc/lnd-backup/credentials"
            INSTALL_DIR="/usr/local/bin"
            WANTED_BY="multi-user.target"
            USE_GROUP="lndbackup"
            # Update venv path for system scope
            VENV_DIR="/opt/lnd-backup-venv"
        fi
fi


# Check Python version
if command -v python3 &> /dev/null; then
    PYTHON_VERSION=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    log_info "Python version: $PYTHON_VERSION"
    if python3 -c 'import sys; sys.exit(1) if sys.version_info < (3, 8) else sys.exit(0)'; then
        log_info "Python version >= 3.8 - OK"
    else
        log_error "Python 3.8 or higher is required, found $PYTHON_VERSION"
        exit 1
    fi
fi

# Set up venv path based on scope
if [[ $EUID -eq 0 ]]; then
    VENV_DIR="/opt/lnd-backup-venv"
else
    VENV_DIR="$HOME/.local/share/lnd-backup-venv"
fi

# Install uv if not available
if ! command -v uv &> /dev/null; then
    log_info "Installing uv package manager..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

# Create virtual environment and install Python dependencies
log_info "Creating virtual environment at $VENV_DIR..."
uv venv "$VENV_DIR"

log_info "Installing Python dependencies in virtual environment..."
uv pip install --python "$VENV_DIR/bin/python" -r "$SCRIPT_DIR/requirements.txt" || {
    log_error "Failed to install Python dependencies"
    exit 1
}

# Create directories
log_info "Creating directories..."
mkdir -p "$CONFIG_DIR"
mkdir -p "$SYSTEMD_DIR"
mkdir -p "$CRED_DIR"
mkdir -p "$INSTALL_DIR"

if [[ $EUID -eq 0 ]]; then
    chmod 700 "$CRED_DIR"
fi


# Validate storage connection string format
validate_storage_connection() {
    local conn="$1"
    
    if [[ "$conn" =~ ^dropbox: ]]; then
        log_info "Valid Dropbox connection string format"
    elif [[ "$conn" =~ ^azure://[^/]+\.blob\.core\.windows\.net/ ]]; then
        # Check Azure permissions
        if [[ ! "$conn" =~ sp=racwl ]]; then
            log_error "Azure connection string has insufficient permissions"
            log_error "Required permissions: sp=racwl (read, add, create, write, list)"
            log_error "Current permissions: $(echo "$conn" | grep -o 'sp=[^&]*' || echo 'none found')"
            return 1
        fi
        log_info "Valid Azure connection string format with proper permissions"
    else
        log_error "Invalid connection string format"
        log_error "Supported formats:"
        log_error "  dropbox:TOKEN"
        log_error "  azure://account.blob.core.windows.net/container?sp=racwl&..."
        log_error "Got: ${conn:0:50}..."
        return 1
    fi
    
    echo "$conn"
}

# Handle storage connection string
while true; do
    if [[ -z "${STORAGE_CONNECTION_STRING:-}" ]]; then
        # Provide more helpful debug information
        if [[ -f "$SCRIPT_DIR/.env" ]]; then
            log_warn "STORAGE_CONNECTION_STRING not set - check your .env file at $SCRIPT_DIR/.env"
            log_info "Make sure STORAGE_CONNECTION_STRING is properly defined in .env (not commented out)"
        elif [[ -f "$SCRIPT_DIR/.env.example" ]]; then
            log_warn "STORAGE_CONNECTION_STRING not set - copy .env.example to .env and set STORAGE_CONNECTION_STRING"
            log_info "Run: cp $SCRIPT_DIR/.env.example $SCRIPT_DIR/.env"
        else
            log_warn "STORAGE_CONNECTION_STRING not set in environment"
        fi

        echo "Supported formats:"
        echo "  dropbox:TOKEN"
        echo "  azure://account.blob.core.windows.net/container?sp=racwl&..."
        echo
        read -p "Enter your storage connection string: " STORAGE_CONNECTION_STRING
    fi

    # Fix Azure connection string format if needed
    if [[ "$STORAGE_CONNECTION_STRING" =~ ^azure:https:// ]]; then
        log_info "Converting Azure connection string to correct format..."
        STORAGE_CONNECTION_STRING="${STORAGE_CONNECTION_STRING/azure:https:\/\//azure://}"
    fi

    # Validate the connection string
    if STORAGE_CONNECTION_STRING=$(validate_storage_connection "$STORAGE_CONNECTION_STRING"); then
        break
    else
        log_error "Please enter a valid connection string"
        STORAGE_CONNECTION_STRING=""
    fi
done

# Store credentials securely
if command -v systemd-creds &> /dev/null && systemctl --version | grep -q "systemd 24[6-9]\|systemd 25[0-9]"; then
    log_info "Using systemd-creds for secure credential storage..."
    echo -n "$STORAGE_CONNECTION_STRING" | systemd-creds encrypt - "$CRED_DIR/storage.connection" 2>/dev/null || {
        log_warn "systemd-creds failed, using restricted file"
        echo -n "$STORAGE_CONNECTION_STRING" > "$CRED_DIR/storage.connection"
        chmod 600 "$CRED_DIR/storage.connection"
    }
    CREDENTIAL_SECTION="LoadCredentialEncrypted=storage.connection:$CRED_DIR/storage.connection
Environment=\"CREDENTIALS_DIRECTORY=%d\""
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

# Only copy provider files that exist
[[ -f "$SCRIPT_DIR/dropbox_provider.py" ]] && cp "$SCRIPT_DIR/dropbox_provider.py" "$INSTALL_DIR/dropbox_provider.py"
[[ -f "$SCRIPT_DIR/azure_provider.py" ]] && cp "$SCRIPT_DIR/azure_provider.py" "$INSTALL_DIR/azure_provider.py"

# Process and install wrapper script with venv path
sed -e "s|%INSTALL_DIR%|$INSTALL_DIR|g" \
    -e "s|%VENV_DIR%|$VENV_DIR|g" \
    "$SCRIPT_DIR/templates/lnd-backup-wrapper.sh" > "$INSTALL_DIR/lnd-backup-wrapper"

chmod +x "$INSTALL_DIR/lnd-backup-monitor"
chmod +x "$INSTALL_DIR/lnd-backup-wrapper"
chmod +x "$INSTALL_DIR/backup.py"

# Process systemd service template
if [[ $SYSTEMD_SCOPE == "system" ]]; then
    if [[ -n "${USE_GROUP:-}" ]]; then
        USER_GROUP_SECTION="User=$SERVICE_USER
Group=$USE_GROUP"
    else
        USER_GROUP_SECTION="User=$SERVICE_USER
Group=$SERVICE_USER"
    fi
else
    USER_GROUP_SECTION=""
fi

# Create temporary file for service
cp "$SCRIPT_DIR/templates/lnd-backup.service" "$SYSTEMD_DIR/lnd-backup.service.tmp"

# Process service template with safe replacements
sed -i "s|%NETWORK%|$NETWORK|g" "$SYSTEMD_DIR/lnd-backup.service.tmp"
sed -i "s|%INSTALL_DIR%|$INSTALL_DIR|g" "$SYSTEMD_DIR/lnd-backup.service.tmp"
sed -i "s|%CONFIG_DIR%|$CONFIG_DIR|g" "$SYSTEMD_DIR/lnd-backup.service.tmp"
sed -i "s|%LND_DATA_DIR%|$LND_DATA_DIR|g" "$SYSTEMD_DIR/lnd-backup.service.tmp"
sed -i "s|%WANTED_BY%|$WANTED_BY|g" "$SYSTEMD_DIR/lnd-backup.service.tmp"

# Handle multi-line replacements using awk
awk -v user_group="$USER_GROUP_SECTION" -v cred="$CREDENTIAL_SECTION" \
    '{gsub("%USER_GROUP_SECTION%", user_group); gsub("%CREDENTIAL_SECTION%", cred); print}' \
    "$SYSTEMD_DIR/lnd-backup.service.tmp" > "$SYSTEMD_DIR/lnd-backup.service"

# Clean up temp file
rm -f "$SYSTEMD_DIR/lnd-backup.service.tmp"

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
echo "Scope: $SYSTEMD_SCOPE"
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
echo "Important notes:"
echo "- If permission setup was required, you may need to log out and back in for group changes to take effect"
echo "- Ensure your storage provider credentials are properly configured"
echo "- Check the service logs if backups don't work as expected"
echo
echo "To uninstall:"
echo "  $CONFIG_DIR/uninstall.sh"
