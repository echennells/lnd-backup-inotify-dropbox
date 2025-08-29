{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.lnd-backup;
  
  lnd-backup = pkgs.callPackage ./package.nix { };
  
  # Configuration file generation using Nix's type system
  configFile = pkgs.writeText "lnd-backup-config" ''
    DROPBOX_TOKEN="${cfg.dropboxToken}"
    LND_DATA_DIR="${cfg.lndDataDir}"
    TAPD_DATA_DIR="${cfg.tapdDataDir}"
    BACKUP_PATH="${cfg.backupPath}"
    CHECK_INTERVAL="${toString cfg.checkInterval}"
    ENABLE_TAPD="${if cfg.enableTapd then "true" else "false"}"
  '';
  
  # Service environment with proper isolation
  serviceEnvironment = {
    HOME = cfg.dataDir;
    CONFIG_FILE = configFile;
  };

in {
  options.services.lnd-backup = {
    enable = mkEnableOption "LND channel backup monitoring service";
    
    user = mkOption {
      type = types.str;
      default = "lnd";
      description = "User under which the backup service runs";
    };
    
    group = mkOption {
      type = types.str;
      default = "lnd";
      description = "Group under which the backup service runs";
    };
    
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/lnd-backup";
      description = "Directory for backup service state";
    };
    
    dropboxToken = mkOption {
      type = types.str;
      description = "Dropbox API token for backup uploads";
    };
    
    dropboxTokenFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "File containing the Dropbox API token (alternative to dropboxToken)";
    };
    
    lndDataDir = mkOption {
      type = types.path;
      default = "/var/lib/lnd";
      description = "LND data directory containing channel.backup";
    };
    
    tapdDataDir = mkOption {
      type = types.path;
      default = "/var/lib/tapd";
      description = "TAP daemon data directory";
    };
    
    backupPath = mkOption {
      type = types.str;
      default = "/LND-Backups";
      description = "Dropbox path for storing backups";
    };
    
    checkInterval = mkOption {
      type = types.int;
      default = 300;
      description = "Interval in seconds between backup checks";
    };
    
    enableTapd = mkOption {
      type = types.bool;
      default = false;
      description = "Enable TAP daemon backup monitoring";
    };
    
    logLevel = mkOption {
      type = types.enum [ "debug" "info" "warning" "error" ];
      default = "info";
      description = "Logging verbosity level";
    };
    
    restartOnFailure = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically restart service on failure";
    };
    
    startAt = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "*:0/5";
      description = "Optional systemd timer specification for periodic runs";
    };
  };
  
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dropboxToken != "" || cfg.dropboxTokenFile != null;
        message = "Either dropboxToken or dropboxTokenFile must be set";
      }
      {
        assertion = cfg.user != "root";
        message = "Running lnd-backup as root is not recommended";
      }
    ];
    
    # Create system user if it doesn't exist
    users.users = mkIf (cfg.user == "lnd") {
      lnd = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
        createHome = true;
        description = "LND backup service user";
      };
    };
    
    users.groups = mkIf (cfg.group == "lnd") {
      lnd = { };
    };
    
    # Main backup monitoring service
    systemd.services.lnd-backup = {
      description = "LND Channel Backup Monitor";
      after = [ "network.target" "lnd.service" ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        
        ExecStartPre = let
          setupScript = pkgs.writeShellScript "lnd-backup-setup" ''
            # Load token from file if specified
            if [ -n "${toString cfg.dropboxTokenFile}" ]; then
              export DROPBOX_TOKEN="$(cat ${cfg.dropboxTokenFile})"
            else
              export DROPBOX_TOKEN="${cfg.dropboxToken}"
            fi
            
            # Ensure directories exist with proper permissions
            mkdir -p ${cfg.dataDir}
            
            # Verify LND directory is accessible
            if ! [ -d "${cfg.lndDataDir}" ]; then
              echo "LND directory ${cfg.lndDataDir} does not exist"
              exit 1
            fi
          '';
        in "${setupScript}";
        
        ExecStart = "${lnd-backup}/bin/lnd-backup-monitor";
        
        Environment = [
          "LOG_LEVEL=${cfg.logLevel}"
        ] ++ mapAttrsToList (n: v: "${n}=${toString v}") serviceEnvironment;
        
        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.dataDir cfg.backupPath ];
        ReadOnlyPaths = [ cfg.lndDataDir ];
        
        # Restart configuration
        Restart = mkIf cfg.restartOnFailure "on-failure";
        RestartSec = "10s";
        
        # Resource limits
        LimitNOFILE = 65536;
        MemoryMax = "256M";
        CPUQuota = "20%";
      };
    };
    
    # Optional TAP daemon backup service
    systemd.services.tapd-backup = mkIf cfg.enableTapd {
      description = "TAP Daemon Backup Service";
      after = [ "network.target" "tapd.service" ];
      wants = [ "network.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        
        ExecStart = "${lnd-backup}/bin/tapd-backup";
        
        Environment = mapAttrsToList (n: v: "${n}=${toString v}") serviceEnvironment;
        
        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.dataDir ];
        ReadOnlyPaths = [ cfg.tapdDataDir ];
      };
    };
    
    # Timer for TAP daemon backups
    systemd.timers.tapd-backup = mkIf (cfg.enableTapd && cfg.startAt != null) {
      description = "TAP Daemon Backup Timer";
      wantedBy = [ "timers.target" ];
      
      timerConfig = {
        OnCalendar = cfg.startAt;
        Persistent = true;
        RandomizedDelaySec = "30s";
      };
    };
    
    # Ensure log directory exists
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.dataDir}/logs 0750 ${cfg.user} ${cfg.group} -"
    ];
    
    # Add package to system environment if needed
    environment.systemPackages = [ lnd-backup ];
  };
}