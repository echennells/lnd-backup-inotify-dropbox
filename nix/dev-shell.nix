{ pkgs }:

let
  # Development Python environment with additional tools
  pythonDev = pkgs.python3.withPackages (ps: with ps; [
    # Runtime dependencies
    requests
    python-dotenv
    dropbox
    
    # Development dependencies
    pytest
    pytest-cov
    pytest-mock
    black
    pylint
    mypy
    types-requests
    ipython
    
    # Documentation
    sphinx
    sphinx-rtd-theme
  ]);
  
  # Custom shell hooks using Nix functions
  shellHooks = {
    setupDev = ''
      echo "🚀 LND Backup Development Environment"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "Available commands:"
      echo "  run-tests      - Run the test suite"
      echo "  format-code    - Format Python code with black"
      echo "  lint-code      - Run linting checks"
      echo "  type-check     - Run mypy type checking"
      echo "  dev-monitor    - Start backup monitor in dev mode"
      echo "  mock-dropbox   - Start mock Dropbox server for testing"
      echo ""
      echo "Nix-specific commands:"
      echo "  nix build      - Build the package"
      echo "  nix run        - Run the backup monitor"
      echo "  nix flake check - Validate the flake"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    '';
    
    createDevConfig = ''
      if [ ! -f .env.dev ]; then
        cat > .env.dev <<EOF
      # Development configuration
      DROPBOX_TOKEN=dev_token_here
      LND_DATA_DIR=$PWD/test-data/lnd
      TAPD_DATA_DIR=$PWD/test-data/tapd
      BACKUP_PATH=/dev-backups
      CHECK_INTERVAL=10
      LOG_LEVEL=debug
      EOF
        echo "✅ Created .env.dev - Please update with your settings"
      fi
    '';
    
    setupTestData = ''
      mkdir -p test-data/lnd/data/chain/bitcoin/mainnet
      mkdir -p test-data/tapd
      
      # Create mock channel.backup file if it doesn't exist
      if [ ! -f test-data/lnd/data/chain/bitcoin/mainnet/channel.backup ]; then
        echo "mock backup data" > test-data/lnd/data/chain/bitcoin/mainnet/channel.backup
        echo "✅ Created mock channel.backup for testing"
      fi
    '';
  };
  
  # Testing utilities as Nix functions
  testUtils = pkgs.writeShellScriptBin "test-utils" ''
    case "$1" in
      setup)
        ${shellHooks.setupTestData}
        ;;
      clean)
        rm -rf test-data
        echo "🧹 Cleaned test data"
        ;;
      *)
        echo "Usage: test-utils {setup|clean}"
        ;;
    esac
  '';

in pkgs.mkShell {
  name = "lnd-backup-dev";
  
  buildInputs = with pkgs; [
    # Python environment
    pythonDev
    
    # System tools
    inotify-tools
    jq
    curl
    git
    
    # Nix development tools
    nixpkgs-fmt
    nil  # Nix LSP
    statix  # Nix static analyzer
    deadnix  # Find dead Nix code
    
    # Documentation tools
    mdbook
    pandoc
    
    # Testing infrastructure
    testUtils
    tmux  # For running multiple services
    httpie  # For API testing
    
    # Container tools (if needed)
    podman
    skopeo
  ];
  
  shellHook = ''
    ${shellHooks.setupDev}
    ${shellHooks.createDevConfig}
    ${shellHooks.setupTestData}
    
    # Set up Python path
    export PYTHONPATH="$PWD:$PYTHONPATH"
    
    # Development aliases using Nix derivations
    alias run-tests='${pkgs.writeShellScript "run-tests" ''
      echo "🧪 Running tests..."
      ${pythonDev}/bin/pytest -v --cov=. --cov-report=term-missing
    ''}'
    
    alias format-code='${pkgs.writeShellScript "format-code" ''
      echo "🎨 Formatting code..."
      ${pythonDev}/bin/black *.py
    ''}'
    
    alias lint-code='${pkgs.writeShellScript "lint-code" ''
      echo "🔍 Linting code..."
      ${pythonDev}/bin/pylint *.py
    ''}'
    
    alias type-check='${pkgs.writeShellScript "type-check" ''
      echo "📝 Type checking..."
      ${pythonDev}/bin/mypy *.py
    ''}'
    
    alias dev-monitor='${pkgs.writeShellScript "dev-monitor" ''
      echo "👁️ Starting development monitor..."
      source .env.dev
      ./channel-backup-monitor.sh
    ''}'
    
    # Mock Dropbox server for testing
    alias mock-dropbox='${pkgs.writeShellScript "mock-dropbox" ''
      echo "🎭 Starting mock Dropbox server on port 8080..."
      ${pythonDev}/bin/python -m http.server 8080 --directory test-data
    ''}'
    
    # Nix-specific development helpers
    alias nix-fmt='nixpkgs-fmt .'
    alias nix-check='statix check && deadnix'
    alias nix-lsp='nil'
    
    # Create development session with tmux
    dev-session() {
      tmux new-session -d -s lnd-backup-dev
      tmux send-keys -t lnd-backup-dev "dev-monitor" C-m
      tmux split-window -h -t lnd-backup-dev
      tmux send-keys -t lnd-backup-dev "mock-dropbox" C-m
      tmux split-window -v -t lnd-backup-dev
      tmux send-keys -t lnd-backup-dev "watch -n 1 'ls -la test-data/lnd/data/chain/bitcoin/mainnet/'" C-m
      tmux attach -t lnd-backup-dev
    }
    
    echo ""
    echo "💡 Tip: Run 'dev-session' to start a tmux session with all services"
  '';
  
  # Environment variables for development
  env = {
    DEVELOPMENT = "true";
    PYTEST_ADDOPTS = "--color=yes";
    BLACK_CONFIG = "pyproject.toml";
  };
  
  # Nix-specific attributes for better IDE support
  passthru = {
    inherit pythonDev;
    python = pythonDev;
  };
}