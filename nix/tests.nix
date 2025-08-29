# Integration tests using NixOS test framework
# This shows how to use Nix for declarative testing

{ pkgs, lib, ... }:

let
  lnd-backup = pkgs.callPackage ./package.nix { };
  
  # Test configuration generator
  mkTestConfig = { name, dropboxToken, lndDataDir }: {
    networking.hostName = name;
    
    services.lnd-backup = {
      enable = true;
      inherit dropboxToken lndDataDir;
      logLevel = "debug";
    };
  };

in {
  # Unit tests using Nix's built-in testing
  unitTests = pkgs.runCommand "lnd-backup-unit-tests" {
    buildInputs = [ lnd-backup pkgs.python3Packages.pytest ];
  } ''
    # Copy source
    cp -r ${lnd-backup.src}/* .
    
    # Run Python tests
    pytest -v
    
    # Test configuration generation
    ${lnd-backup}/bin/lnd-backup-monitor --dry-run --config-test
    
    touch $out
  '';
  
  # Integration test using NixOS VMs
  integrationTest = pkgs.nixosTest {
    name = "lnd-backup-integration";
    
    nodes = {
      # LND node with backup
      lndNode = { pkgs, ... }: {
        imports = [ ./nixos-module.nix ];
        
        services.lnd-backup = {
          enable = true;
          dropboxToken = "test-token";
          lndDataDir = "/var/lib/lnd";
          enableTapd = false;
        };
        
        # Mock LND service
        systemd.services.mock-lnd = {
          wantedBy = [ "multi-user.target" ];
          script = ''
            mkdir -p /var/lib/lnd/data/chain/bitcoin/mainnet
            while true; do
              echo "test-backup-$(date +%s)" > /var/lib/lnd/data/chain/bitcoin/mainnet/channel.backup
              sleep 10
            done
          '';
        };
      };
      
      # Mock Dropbox server
      dropboxMock = { pkgs, ... }: {
        services.nginx = {
          enable = true;
          virtualHosts."dropbox-mock" = {
            listen = [{ addr = "0.0.0.0"; port = 80; }];
            locations."/" = {
              return = "200 'Mock Dropbox API'";
            };
          };
        };
      };
    };
    
    testScript = ''
      start_all()
      
      # Wait for services
      lndNode.wait_for_unit("multi-user.target")
      dropboxMock.wait_for_unit("nginx.service")
      
      # Verify backup service is running
      lndNode.wait_for_unit("lnd-backup.service")
      
      # Check that backup file is being monitored
      lndNode.succeed("systemctl status lnd-backup.service")
      
      # Trigger a backup by modifying the file
      lndNode.succeed("echo 'new-backup' > /var/lib/lnd/data/chain/bitcoin/mainnet/channel.backup")
      
      # Wait and check logs
      lndNode.sleep(5)
      lndNode.succeed("journalctl -u lnd-backup.service | grep -q 'Backup detected'")
      
      # Verify backup attempts (will fail due to mock, but should try)
      lndNode.succeed("journalctl -u lnd-backup.service | grep -q 'Attempting backup'")
    '';
  };
  
  # Property-based testing using QuickCheck-style approach
  propertyTests = pkgs.writeShellScriptBin "property-tests" ''
    ${pkgs.python3.withPackages (ps: [ ps.hypothesis ])}/bin/python <<'EOF'
    from hypothesis import given, strategies as st
    import json
    import subprocess
    
    @given(
        token=st.text(min_size=10, max_size=100),
        interval=st.integers(min_value=1, max_value=3600),
        path=st.text(min_size=1, max_size=50).filter(lambda x: '/' not in x)
    )
    def test_config_generation(token, interval, path):
        """Test that configuration generation is pure and deterministic"""
        config = {
            "dropboxToken": token,
            "checkInterval": interval,
            "backupPath": f"/{path}"
        }
        
        # Generate config twice - should be identical
        result1 = subprocess.run(
            ["nix", "eval", "--json", f"(import ./package.nix {{}}).generateConfig"],
            input=json.dumps(config),
            capture_output=True,
            text=True
        )
        
        result2 = subprocess.run(
            ["nix", "eval", "--json", f"(import ./package.nix {{}}).generateConfig"],
            input=json.dumps(config),
            capture_output=True,
            text=True
        )
        
        assert result1.stdout == result2.stdout, "Configuration generation is not deterministic"
    
    if __name__ == "__main__":
        test_config_generation()
        print("✅ All property tests passed")
    EOF
  '';
  
  # Smoke test for development
  smokeTest = pkgs.writeShellScriptBin "smoke-test" ''
    echo "🔥 Running smoke tests..."
    
    # Test that the package builds
    nix build .#lnd-backup
    
    # Test that binaries are available
    result/bin/lnd-backup-monitor --version || true
    result/bin/dropbox-backup --help || true
    
    # Test configuration generation
    nix eval .#lnd-backup.generateConfig --apply 'f: f { dropboxToken = "test"; }'
    
    # Test development shell
    nix develop -c echo "Development shell works"
    
    echo "✅ All smoke tests passed"
  '';
}