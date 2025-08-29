{ lib
, stdenv
, python3
, makeWrapper
, inotify-tools
, jq
, curl
, coreutils
, bash
}:

let
  pythonEnv = python3.withPackages (ps: with ps; [
    requests
    python-dotenv
    dropbox
  ]);
  
  backupLib = rec {
    configDir = "$HOME/.config/lnd-backup";
    defaultConfig = {
      dropboxToken = "";
      lndDataDir = "$HOME/.lnd";
      tapdDataDir = "$HOME/.tapd";
      backupPath = "/LND-Backups";
      checkInterval = 300;
      enableTapd = false;
    };
    
    mkConfig = attrs: lib.attrsets.recursiveUpdate defaultConfig attrs;
    
    validateConfig = config: 
      assert config.dropboxToken != "" -> true;
      assert lib.pathIsDirectory config.lndDataDir -> true;
      config;
  };

in stdenv.mkDerivation rec {
  pname = "lnd-backup-monitor";
  version = "1.0.0";
  
  src = lib.cleanSource ../.;
  
  nativeBuildInputs = [ makeWrapper ];
  
  buildInputs = [
    pythonEnv
    inotify-tools
    jq
    curl
    coreutils
    bash
  ];
  
  dontBuild = true;
  
  installPhase = ''
    runHook preInstall
    
    # Install scripts
    install -Dm755 channel-backup-monitor.sh $out/bin/lnd-backup-monitor
    install -Dm755 dropbox_backup.py $out/bin/dropbox-backup
    install -Dm755 tapd_backup.py $out/bin/tapd-backup
    
    # Install systemd units as data files
    install -Dm644 lnd-backup.service $out/share/systemd/user/lnd-backup.service
    install -Dm644 tapd-backup.service $out/share/systemd/user/tapd-backup.service
    install -Dm644 tapd-backup.timer $out/share/systemd/user/tapd-backup.timer
    
    # Wrap scripts with dependencies
    wrapProgram $out/bin/lnd-backup-monitor \
      --prefix PATH : ${lib.makeBinPath [ 
        inotify-tools 
        pythonEnv 
        coreutils 
        bash 
      ]} \
      --set PYTHONPATH ${pythonEnv}/${python3.sitePackages}
    
    wrapProgram $out/bin/dropbox-backup \
      --prefix PATH : ${lib.makeBinPath [ pythonEnv ]} \
      --set PYTHONPATH ${pythonEnv}/${python3.sitePackages}
    
    wrapProgram $out/bin/tapd-backup \
      --prefix PATH : ${lib.makeBinPath [ pythonEnv curl jq ]} \
      --set PYTHONPATH ${pythonEnv}/${python3.sitePackages}
    
    runHook postInstall
  '';
  
  passthru = {
    inherit backupLib pythonEnv;
    
    # Pure function to generate configuration
    generateConfig = { dropboxToken, lndDataDir ? null, tapdDataDir ? null, ... }@attrs:
      let
        config = backupLib.mkConfig attrs;
      in ''
        DROPBOX_TOKEN="${config.dropboxToken}"
        LND_DATA_DIR="${config.lndDataDir}"
        TAPD_DATA_DIR="${config.tapdDataDir}"
        BACKUP_PATH="${config.backupPath}"
        CHECK_INTERVAL="${toString config.checkInterval}"
        ENABLE_TAPD="${if config.enableTapd then "true" else "false"}"
      '';
  };
  
  meta = with lib; {
    description = "Automated LND channel backup system with Dropbox integration";
    homepage = "https://github.com/yourusername/lnd-backup-monitor";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "lnd-backup-monitor";
  };
}