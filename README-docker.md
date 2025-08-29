# LND Backup Monitor - Docker

Run the LND backup monitor in Docker using the same configuration templates as the bash installer.

## Quick Start

1. Copy the environment file:
   ```bash
   cp .env.example .env
   ```

2. Edit `.env` with your Dropbox token:
   ```bash
   DROPBOX_TOKEN=your_actual_token_here
   LND_DATA_DIR=/path/to/your/lnd/data
   ```

3. Run with Docker Compose:
   ```bash
   docker-compose up -d
   ```

## Configuration

The Docker container uses the same template system as the bash installer:

- **Templates**: Same `templates/` directory 
- **Environment detection**: Automatically detects network from LND config
- **Credential handling**: Uses environment variables instead of systemd credentials

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DROPBOX_TOKEN` | *required* | Dropbox API token |
| `NETWORK` | `mainnet` | Bitcoin network (auto-detected if not set) |
| `LND_DATA_DIR` | `/lnd` | LND data directory path |
| `CHECK_INTERVAL` | `300` | Backup check interval (seconds) |
| `LOG_LEVEL` | `info` | Logging level |
| `ENABLE_TAPD` | `false` | Enable TAP daemon backup |

### Network Detection

The container automatically detects your network by reading mounted LND configuration:

- **Mainnet**: `/lnd/data/chain/bitcoin/mainnet/channel.backup`
- **Testnet**: `/lnd/data/chain/bitcoin/testnet/channel.backup` 
- **Signet**: `/lnd/data/chain/bitcoin/signet/channel.backup`
- **Mutinynet**: Detected by signetchallenge in bitcoin.conf

## Volume Mounts

Mount your LND data directory as read-only:

```yaml
volumes:
  - "/var/lib/lnd:/lnd:ro"
  - "/var/lib/tapd:/tapd:ro"  # optional
```

## Monitoring

Check the container status:

```bash
# Service status
docker-compose ps

# Logs
docker-compose logs -f lnd-backup

# Health check
docker inspect lnd-backup-monitor | grep -A5 Health
```

## Security

The container runs as a non-root user (1000:1000) with:

- Read-only filesystem
- Minimal resource limits
- Health checks
- No network access except for Dropbox API

## Build Arguments

Customize the build:

```bash
docker build --build-arg NETWORK=signet --build-arg LOG_LEVEL=debug .
```

Available build args:
- `NETWORK`, `LND_DATA_DIR`, `CHECK_INTERVAL`
- `TAPD_DATA_DIR`, `ENABLE_TAPD`, `LOG_LEVEL`