FROM alpine:3.19

# Install system dependencies
RUN apk add --no-cache \
    python3 \
    py3-pip \
    py3-virtualenv \
    inotify-tools \
    bash \
    curl

# Create virtual environment (the proper way)
RUN python3 -m venv /opt/lnd-backup
ENV PATH="/opt/lnd-backup/bin:$PATH"

# Copy requirements and install Python dependencies in virtual environment
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Create app user
RUN adduser -D -u 1000 -h /app -s /bin/bash lndbackup

# Set working directory
WORKDIR /app

# Copy source files
COPY backup.py /app/
COPY storage_providers.py /app/
COPY azure_provider.py /app/
COPY templates/ /app/templates/

# Process templates at build time using environment defaults
ARG NETWORK=mainnet
ARG LND_DATA_DIR=/lnd
ARG CHECK_INTERVAL=300
ARG TAPD_DATA_DIR=/tapd
ARG ENABLE_TAPD=false
ARG LOG_LEVEL=info

# Process config template
RUN sed -e "s|%NETWORK%|${NETWORK}|g" \
        -e "s|%DATE%|$(date)|g" \
        -e "s|%HOSTNAME%|container|g" \
        -e "s|%LND_DATA_DIR%|${LND_DATA_DIR}|g" \
        -e "s|%CHANNEL_BACKUP_PATH%|${LND_DATA_DIR}/data/chain/bitcoin/${NETWORK}/channel.backup|g" \
        -e "s|%CHECK_INTERVAL%|${CHECK_INTERVAL}|g" \
        -e "s|%TAPD_DATA_DIR%|${TAPD_DATA_DIR}|g" \
        -e "s|%ENABLE_TAPD%|${ENABLE_TAPD}|g" \
        -e "s|%LOG_LEVEL%|${LOG_LEVEL}|g" \
        /app/templates/config > /app/config.default

# Process monitor script template
RUN sed -e 's|source "${CONFIG_DIR}/config"|source "/app/config"|g' \
        -e 's|"$(dirname "$0")/dropbox_backup.py"|"/app/backup.py"|g' \
        /app/templates/lnd-backup-monitor.sh > /app/lnd-backup-monitor \
    && chmod +x /app/lnd-backup-monitor

# Create entrypoint script that handles runtime config
RUN cat > /app/entrypoint.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Runtime configuration override
CONFIG_FILE="/app/config"

# Copy default config
cp /app/config.default "$CONFIG_FILE"

# Override with runtime environment variables
if [[ -n "${NETWORK:-}" ]]; then
    sed -i "s|^NETWORK=.*|NETWORK=${NETWORK}|" "$CONFIG_FILE"
    # Update channel backup path based on network
    case "$NETWORK" in
        mainnet)
            BACKUP_PATH="${LND_DATA_DIR}/data/chain/bitcoin/mainnet/channel.backup"
            ;;
        testnet)
            BACKUP_PATH="${LND_DATA_DIR}/data/chain/bitcoin/testnet/channel.backup"
            ;;
        signet|signet-mutinynet)
            BACKUP_PATH="${LND_DATA_DIR}/data/chain/bitcoin/signet/channel.backup"
            ;;
        regtest)
            BACKUP_PATH="${LND_DATA_DIR}/data/chain/bitcoin/regtest/channel.backup"
            ;;
    esac
    sed -i "s|^CHANNEL_BACKUP_PATH=.*|CHANNEL_BACKUP_PATH=${BACKUP_PATH}|" "$CONFIG_FILE"
fi

if [[ -n "${LND_DATA_DIR:-}" ]]; then
    sed -i "s|^LND_DATA_DIR=.*|LND_DATA_DIR=${LND_DATA_DIR}|" "$CONFIG_FILE"
fi

if [[ -n "${CHECK_INTERVAL:-}" ]]; then
    sed -i "s|^CHECK_INTERVAL=.*|CHECK_INTERVAL=${CHECK_INTERVAL}|" "$CONFIG_FILE"
fi

if [[ -n "${TAPD_DATA_DIR:-}" ]]; then
    sed -i "s|^TAPD_DATA_DIR=.*|TAPD_DATA_DIR=${TAPD_DATA_DIR}|" "$CONFIG_FILE"
fi

if [[ -n "${ENABLE_TAPD:-}" ]]; then
    sed -i "s|^ENABLE_TAPD=.*|ENABLE_TAPD=${ENABLE_TAPD}|" "$CONFIG_FILE"
fi

if [[ -n "${LOG_LEVEL:-}" ]]; then
    sed -i "s|^LOG_LEVEL=.*|LOG_LEVEL=${LOG_LEVEL}|" "$CONFIG_FILE"
fi

# Update hostname in backup path
HOSTNAME=${HOSTNAME:-$(hostname)}
sed -i "s|%HOSTNAME%|${HOSTNAME}|g" "$CONFIG_FILE"

# Validate required environment variables for storage provider
if [[ -z "${STORAGE_CONNECTION_STRING:-}" ]]; then
    echo "ERROR: STORAGE_CONNECTION_STRING environment variable is required"
    exit 1
fi

echo "Starting LND Backup Monitor in container"
echo "Configuration:"
cat "$CONFIG_FILE"
echo "===================="

# Start the monitor
exec /app/lnd-backup-monitor
EOF

RUN chmod +x /app/entrypoint.sh

# Create volumes for persistence
VOLUME ["/lnd", "/tapd"]

# Set ownership
RUN chown -R lndbackup:lndbackup /app

# Switch to app user
USER lndbackup

# Health check
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD pgrep -f lnd-backup-monitor || exit 1

# Default environment variables
ENV NETWORK=mainnet \
    LND_DATA_DIR=/lnd \
    CHECK_INTERVAL=300 \
    LOG_LEVEL=info \
    ENABLE_TAPD=false

ENTRYPOINT ["/app/entrypoint.sh"]