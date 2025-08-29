# Nix overlay for integrating lnd-backup into nixpkgs
# This demonstrates how to properly extend nixpkgs with custom packages

final: prev: {
  # Add our package to the overlay
  lnd-backup = final.callPackage ./package.nix { };
  
  # Override python packages to include our custom requirements
  python3 = prev.python3.override {
    packageOverrides = python-self: python-super: {
      # Custom Dropbox integration with better error handling
      dropbox-extended = python-super.dropbox.overridePythonAttrs (oldAttrs: {
        propagatedBuildInputs = oldAttrs.propagatedBuildInputs ++ [
          python-self.tenacity
          python-self.backoff
        ];
      });
    };
  };
  
  # Compose multiple backup strategies using Nix functions
  backupStrategies = {
    # S3 backup strategy
    s3 = { bucket, region ? "us-east-1", ... }: final.writeShellScriptBin "backup-s3" ''
      ${final.awscli2}/bin/aws s3 cp "$1" "s3://${bucket}/lnd-backups/" --region ${region}
    '';
    
    # IPFS backup strategy
    ipfs = { gateway ? "http://localhost:5001", ... }: final.writeShellScriptBin "backup-ipfs" ''
      ${final.curl}/bin/curl -X POST -F "file=@$1" "${gateway}/api/v0/add"
    '';
    
    # Multiple backup destinations
    multi = strategies: final.writeShellScriptBin "backup-multi" ''
      for strategy in ${lib.concatStringsSep " " strategies}; do
        $strategy "$1" || echo "Warning: $strategy failed"
      done
    '';
  };
  
  # LND with backup integration
  lndWithBackup = final.lnd.overrideAttrs (oldAttrs: {
    postInstall = (oldAttrs.postInstall or "") + ''
      # Add backup hook
      wrapProgram $out/bin/lnd \
        --run '${final.lnd-backup}/bin/lnd-backup-monitor &'
    '';
  });
}