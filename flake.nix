{
  description = "LND Channel Backup System with inotify and Dropbox";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        python-env = pkgs.python3.withPackages (ps: with ps; [
          dropbox
          python-dotenv
        ]);

        lnd-backup = pkgs.stdenv.mkDerivation rec {
          pname = "lnd-backup-inotify-dropbox";
          version = "1.0.0";
          
          src = ./.;
          
          nativeBuildInputs = [ pkgs.makeWrapper ];
          
          buildInputs = [
            python-env
            pkgs.inotify-tools
            pkgs.bash
            pkgs.coreutils
          ];
          
          installPhase = ''
            # Create output directories
            mkdir -p $out/bin
            mkdir -p $out/lib/systemd/system
            mkdir -p $out/share/lnd-backup
            
            # Install Python script with proper shebang
            cp dropbox_backup.py $out/bin/lnd-backup-dropbox
            chmod +x $out/bin/lnd-backup-dropbox
            
            # Wrap Python script to use Nix Python
            wrapProgram $out/bin/lnd-backup-dropbox \
              --set PYTHONPATH ${python-env}/${python-env.sitePackages} \
              --prefix PATH : ${pkgs.lib.makeBinPath [ python-env ]}
            
            # Install monitoring script
            cp channel-backup-monitor.sh $out/bin/lnd-backup-monitor
            chmod +x $out/bin/lnd-backup-monitor
            
            # Wrap monitoring script with dependencies
            wrapProgram $out/bin/lnd-backup-monitor \
              --prefix PATH : ${pkgs.lib.makeBinPath [ 
                pkgs.inotify-tools 
                pkgs.coreutils 
                pkgs.bash
                python-env
              ]} \
              --set LND_BACKUP_DROPBOX_BIN $out/bin/lnd-backup-dropbox
            
            # Install systemd service
            substitute lnd-backup.service $out/lib/systemd/system/lnd-backup.service \
              --replace "/home/ubuntu/lnd-backup-inotify-dropbox/channel-backup-monitor.sh" "$out/bin/lnd-backup-monitor" \
              --replace "/home/ubuntu/lnd-backup-inotify-dropbox" "$out/share/lnd-backup"
            
            # Copy configuration examples
            cp .env.example $out/share/lnd-backup/
            cp README.md $out/share/lnd-backup/
            
            # Create setup helper script
            cat > $out/bin/lnd-backup-setup << 'EOF'
            #!/usr/bin/env bash
            set -e
            
            CONFIG_DIR="$HOME/.config/lnd-backup"
            
            echo "LND Backup System Setup"
            echo "----------------------"
            
            # Create config directory
            mkdir -p "$CONFIG_DIR"
            
            # Copy example env if not exists
            if [ ! -f "$CONFIG_DIR/.env" ]; then
                cp ${placeholder "out"}/share/lnd-backup/.env.example "$CONFIG_DIR/.env"
                echo "Created config file at: $CONFIG_DIR/.env"
                echo "Please edit this file and add your Dropbox token"
            else
                echo "Config file already exists at: $CONFIG_DIR/.env"
            fi
            
            # Provide systemd service installation instructions
            echo ""
            echo "To install systemd service (requires root):"
            echo "  sudo cp ${placeholder "out"}/lib/systemd/system/lnd-backup.service /etc/systemd/system/"
            echo "  sudo systemctl daemon-reload"
            echo "  sudo systemctl enable lnd-backup"
            echo "  sudo systemctl start lnd-backup"
            echo ""
            echo "To check service status:"
            echo "  sudo systemctl status lnd-backup"
            echo "  sudo journalctl -fu lnd-backup"
            EOF
            
            chmod +x $out/bin/lnd-backup-setup
          '';
          
          meta = with pkgs.lib; {
            description = "Automated LND channel backup system using inotify and Dropbox";
            homepage = "https://github.com/echennells/lnd-backup-inotify-dropbox";
            license = licenses.mit;
            maintainers = [ ];
            platforms = platforms.linux;
          };
        };
        
      in {
        packages.default = lnd-backup;
        
        apps.default = {
          type = "app";
          program = "${lnd-backup}/bin/lnd-backup-setup";
        };
        
        # Development shell with all dependencies
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            python3
            python3Packages.dropbox
            python3Packages.python-dotenv
            inotify-tools
            git
          ];
          
          shellHook = ''
            echo "LND Backup Development Environment"
            echo "Run 'python3 dropbox_backup.py' to test"
          '';
        };
        
        # NixOS module for declarative configuration
        nixosModules.default = { config, lib, pkgs, ... }:
          with lib;
          let
            cfg = config.services.lnd-backup;
          in {
            options.services.lnd-backup = {
              enable = mkEnableOption "LND channel backup service";
              
              dropboxToken = mkOption {
                type = types.str;
                description = "Dropbox API access token";
              };
              
              lndPath = mkOption {
                type = types.str;
                default = "/var/lib/lnd";
                description = "Path to LND data directory";
              };
              
              backupDir = mkOption {
                type = types.str;
                default = "/lightning-backups";
                description = "Dropbox directory for backups";
              };
              
              localBackupDir = mkOption {
                type = types.str;
                default = "/var/backup/lnd";
                description = "Local directory for backup copies";
              };
              
              keepBackups = mkOption {
                type = types.int;
                default = 30;
                description = "Number of backups to retain";
              };
              
              user = mkOption {
                type = types.str;
                default = "lnd";
                description = "User to run the backup service as";
              };
              
              group = mkOption {
                type = types.str;
                default = "lnd";
                description = "Group to run the backup service as";
              };
            };
            
            config = mkIf cfg.enable {
              systemd.services.lnd-backup = {
                description = "LND Channel Backup Monitor";
                after = [ "network.target" ];
                wantedBy = [ "multi-user.target" ];
                
                environment = {
                  DROPBOX_ACCESS_TOKEN = cfg.dropboxToken;
                  LND_CHANNEL_BACKUP_PATH = "${cfg.lndPath}/data/chain/bitcoin/mainnet/channel.backup";
                  DROPBOX_BACKUP_DIR = cfg.backupDir;
                  LOCAL_BACKUP_DIR = cfg.localBackupDir;
                  KEEP_LAST_N_BACKUPS = toString cfg.keepBackups;
                };
                
                serviceConfig = {
                  Type = "simple";
                  User = cfg.user;
                  Group = cfg.group;
                  ExecStart = "${lnd-backup}/bin/lnd-backup-monitor";
                  Restart = "always";
                  RestartSec = "10s";
                  
                  # Security hardening
                  PrivateTmp = true;
                  ProtectSystem = "strict";
                  ProtectHome = true;
                  NoNewPrivileges = true;
                  ReadWritePaths = [ cfg.localBackupDir "/tmp" ];
                  ReadOnlyPaths = [ cfg.lndPath ];
                };
                
                preStart = ''
                  mkdir -p ${cfg.localBackupDir}
                  chown ${cfg.user}:${cfg.group} ${cfg.localBackupDir}
                '';
              };
              
              # Create backup user if it doesn't exist
              users.users.${cfg.user} = {
                isSystemUser = true;
                group = cfg.group;
                home = cfg.localBackupDir;
              };
              
              users.groups.${cfg.group} = {};
            };
          };
      }
    );
}