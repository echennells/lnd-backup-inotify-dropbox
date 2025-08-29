{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.lnd-backup;
  
  lnd-backup = pkgs.callPackage ./package.nix { };
  
  # Type definitions for structured configuration
  backupInstanceType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Instance identifier";
      };
      
      lndDataDir = mkOption {
        type = types.path;
        description = "LND data directory for this instance";
      };
      
      backupPath = mkOption {
        type = types.str;
        description = "Dropbox path for this instance's backups";
      };
      
      enabled = mkOption {
        type = types.bool;
        default = true;
        description = "Whether this backup instance is enabled";
      };
    };
  };
  
  # Functional helpers for configuration management
  configHelpers = rec {
    # Generate environment file for an instance
    mkEnvFile = instance: token: pkgs.writeText "lnd-backup-${instance.name}.env" ''
      DROPBOX_TOKEN="${token}"
      LND_DATA_DIR="${instance.lndDataDir}"
      BACKUP_PATH="${instance.backupPath}"
      CHECK_INTERVAL="${toString cfg.checkInterval}"
      LOG_LEVEL="${cfg.logLevel}"
    '';
    
    # Create systemd user service for an instance
    mkServiceUnit = instance: {
      Unit = {
        Description = "LND Backup Monitor - ${instance.name}";
        After = [ "network.target" ];
      };
      
      Service = {
        Type = "simple";
        ExecStart = "${lnd-backup}/bin/lnd-backup-monitor";
        EnvironmentFile = mkEnvFile instance cfg.dropboxToken;
        Restart = "on-failure";
        RestartSec = "30s";
        
        # User-level service restrictions
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ 
          "%h/.config/lnd-backup"
          "%h/.cache/lnd-backup"
        ];
        ReadOnlyPaths = [ instance.lndDataDir ];
      };
      
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
    
    # Validate configuration consistency
    validateInstances = instances: 
      let
        names = map (i: i.name) instances;
        uniqueNames = unique names;
      in
        assert length names == length uniqueNames;
        instances;
  };

in {
  options.programs.lnd-backup = {
    enable = mkEnableOption "LND backup monitoring for user";
    
    package = mkOption {
      type = types.package;
      default = lnd-backup;
      description = "The lnd-backup package to use";
    };
    
    dropboxToken = mkOption {
      type = types.str;
      description = "Dropbox API token";
    };
    
    dropboxTokenCommand = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "pass show dropbox/lnd-backup";
      description = "Command to retrieve Dropbox token";
    };
    
    instances = mkOption {
      type = types.listOf backupInstanceType;
      default = [{
        name = "default";
        lndDataDir = "${config.home.homeDirectory}/.lnd";
        backupPath = "/LND-Backups/default";
        enabled = true;
      }];
      description = "LND instances to monitor";
    };
    
    checkInterval = mkOption {
      type = types.int;
      default = 300;
      description = "Backup check interval in seconds";
    };
    
    logLevel = mkOption {
      type = types.enum [ "debug" "info" "warning" "error" ];
      default = "info";
      description = "Logging level";
    };
    
    enableNotifications = mkOption {
      type = types.bool;
      default = false;
      description = "Enable desktop notifications for backup events";
    };
    
    notificationCommand = mkOption {
      type = types.nullOr types.str;
      default = if pkgs.stdenv.isLinux then 
        "${pkgs.libnotify}/bin/notify-send" 
      else 
        null;
      description = "Command to send notifications";
    };
    
    autoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically start backup monitoring on login";
    };
  };
  
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.dropboxToken != "" || cfg.dropboxTokenCommand != null;
        message = "Either dropboxToken or dropboxTokenCommand must be set";
      }
      {
        assertion = length cfg.instances > 0;
        message = "At least one backup instance must be configured";
      }
    ];
    
    # Install the package
    home.packages = [ cfg.package ];
    
    # Create configuration directory structure
    xdg.configFile = {
      "lnd-backup/config.nix".text = ''
        # Auto-generated LND backup configuration
        # Managed by Home Manager - do not edit directly
        {
          instances = ${builtins.toJSON cfg.instances};
          checkInterval = ${toString cfg.checkInterval};
          logLevel = "${cfg.logLevel}";
        }
      '';
    } // listToAttrs (map (instance: {
      name = "lnd-backup/instances/${instance.name}.conf";
      value = {
        text = ''
          # Configuration for ${instance.name}
          LND_DATA_DIR="${instance.lndDataDir}"
          BACKUP_PATH="${instance.backupPath}"
          ENABLED="${if instance.enabled then "true" else "false"}"
        '';
      };
    }) cfg.instances);
    
    # Create systemd user services for each instance
    systemd.user.services = listToAttrs (
      map (instance: {
        name = "lnd-backup-${instance.name}";
        value = configHelpers.mkServiceUnit instance;
      }) (filter (i: i.enabled) cfg.instances)
    );
    
    # Create activation script for token management
    home.activation.lnd-backup-setup = lib.hm.dag.entryAfter ["writeBoundary"] ''
      # Set up secure token storage
      TOKEN_FILE="$HOME/.config/lnd-backup/.dropbox-token"
      mkdir -p "$(dirname "$TOKEN_FILE")"
      chmod 700 "$(dirname "$TOKEN_FILE")"
      
      # Retrieve token using command if specified
      ${optionalString (cfg.dropboxTokenCommand != null) ''
        echo "Retrieving Dropbox token..."
        ${cfg.dropboxTokenCommand} > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
      ''}
      
      # Or use direct token
      ${optionalString (cfg.dropboxTokenCommand == null) ''
        echo "${cfg.dropboxToken}" > "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
      ''}
      
      # Set up logging directory
      mkdir -p "$HOME/.local/share/lnd-backup/logs"
      
      # Enable services if autoStart is true
      ${optionalString cfg.autoStart (
        concatMapStringsSep "\n" (instance: ''
          systemctl --user enable lnd-backup-${instance.name}.service
          systemctl --user start lnd-backup-${instance.name}.service
        '') (filter (i: i.enabled) cfg.instances)
      )}
    '';
    
    # Add shell aliases for management
    programs.bash.shellAliases = mkIf cfg.enable {
      lnd-backup-status = "systemctl --user status 'lnd-backup-*'";
      lnd-backup-logs = "journalctl --user -u 'lnd-backup-*' -f";
      lnd-backup-restart = "systemctl --user restart 'lnd-backup-*'";
    };
    
    programs.zsh.shellAliases = mkIf cfg.enable {
      lnd-backup-status = "systemctl --user status 'lnd-backup-*'";
      lnd-backup-logs = "journalctl --user -u 'lnd-backup-*' -f";
      lnd-backup-restart = "systemctl --user restart 'lnd-backup-*'";
    };
    
    # Optional: Add notification integration
    systemd.user.services = mkIf cfg.enableNotifications (
      listToAttrs (map (instance: {
        name = "lnd-backup-notify-${instance.name}";
        value = {
          Unit = {
            Description = "LND Backup Notifications - ${instance.name}";
            BindsTo = [ "lnd-backup-${instance.name}.service" ];
          };
          
          Service = {
            Type = "simple";
            ExecStart = pkgs.writeShellScript "notify-${instance.name}" ''
              #!/usr/bin/env bash
              journalctl --user -u lnd-backup-${instance.name} -f | while read line; do
                if echo "$line" | grep -q "Backup uploaded successfully"; then
                  ${cfg.notificationCommand} "LND Backup" "Channel backup uploaded for ${instance.name}"
                elif echo "$line" | grep -q "ERROR"; then
                  ${cfg.notificationCommand} -u critical "LND Backup Error" "Backup failed for ${instance.name}"
                fi
              done
            '';
          };
          
          Install = {
            WantedBy = [ "lnd-backup-${instance.name}.service" ];
          };
        };
      }) (filter (i: i.enabled) cfg.instances))
    );
  };
}