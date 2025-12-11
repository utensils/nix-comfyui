{
  description = "A Nix flake for ComfyUI with Python 3.12";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      # Version configuration - single source of truth
      comfyuiVersion = "0.4.0";
      comfyuiRev = "fc657f471a29d07696ca16b566000e8e555d67d1";
      comfyuiHash = "sha256-gq7/CfKqXGD/ti9ZeBVsHFPid+LTkpP4nTzt6NE/Jfo=";
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        # Allow unfree packages
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            allowUnsupportedSystem = true;
          };
        };

        # ComfyUI source
        comfyui-src = pkgs.fetchFromGitHub {
          owner = "comfyanonymous";
          repo = "ComfyUI";
          rev = comfyuiRev;
          hash = comfyuiHash;
        };

        # Model downloader custom node
        modelDownloaderDir = ./src/custom_nodes/model_downloader;

        # Python environment with minimal dependencies for bootstrapping
        # All ComfyUI dependencies are installed via pip in the virtual environment
        pythonEnv = pkgs.python312.buildEnv.override {
          extraLibs = with pkgs.python312Packages; [
            setuptools
            wheel
            pip
          ];
          ignoreCollisions = true;
        };

        # Copy our persistence scripts to the nix store
        persistenceScript = ./src/persistence/persistence.py;
        persistenceMainScript = ./src/persistence/main.py;

        # Process each script file individually
        configScript = pkgs.substituteAll {
          src = ./scripts/config.sh;
          pythonEnv = pythonEnv;
          comfyuiSrc = comfyui-src;
          modelDownloaderDir = modelDownloaderDir;
          persistenceScript = persistenceScript;
          persistenceMainScript = persistenceMainScript;
        };

        loggerScript = pkgs.substituteAll {
          src = ./scripts/logger.sh;
          pythonEnv = pythonEnv;
        };

        installScript = pkgs.substituteAll {
          src = ./scripts/install.sh;
          pythonEnv = pythonEnv;
        };

        persistenceShScript = pkgs.substituteAll {
          src = ./scripts/persistence.sh;
          pythonEnv = pythonEnv;
        };

        runtimeScript = pkgs.substituteAll {
          src = ./scripts/runtime.sh;
          pythonEnv = pythonEnv;
        };

        # Main launcher script with substitutions
        launcherScript = pkgs.substituteAll {
          src = ./scripts/launcher.sh;
          pythonEnv = pythonEnv;
          comfyuiSrc = comfyui-src;
          modelDownloaderDir = modelDownloaderDir;
          persistenceScript = persistenceScript;
          persistenceMainScript = persistenceMainScript;
          libPath = "${pkgs.stdenv.cc.cc.lib}/lib";
        };

        # Create a directory with all scripts
        scriptDir = pkgs.runCommand "comfy-ui-scripts" { } ''
          mkdir -p $out
          cp ${configScript} $out/config.sh
          cp ${loggerScript} $out/logger.sh
          cp ${installScript} $out/install.sh
          cp ${persistenceShScript} $out/persistence.sh
          cp ${runtimeScript} $out/runtime.sh
          cp ${launcherScript} $out/launcher.sh
          chmod +x $out/*.sh
        '';

        # Define all packages in one attribute set
        packages = rec {
          default = pkgs.stdenv.mkDerivation {
            pname = "comfy-ui";
            version = comfyuiVersion;

            src = comfyui-src;

            # Passthru for scripting and testing
            passthru = {
              inherit comfyui-src;
              version = comfyuiVersion;
            };

            nativeBuildInputs = [
              pkgs.makeWrapper
              pythonEnv
            ];
            buildInputs = [
              pkgs.libGL
              pkgs.libGLU
              pkgs.stdenv.cc.cc.lib
            ];

            # Skip build and configure phases
            dontBuild = true;
            dontConfigure = true;

            installPhase = ''
              # Create directories
              mkdir -p "$out/bin"
              mkdir -p "$out/share/comfy-ui"

              # Copy ComfyUI files
              cp -r ${comfyui-src}/* "$out/share/comfy-ui/"

              # Create scripts directory
              mkdir -p "$out/share/comfy-ui/scripts"

              # Copy all script files
              cp -r ${scriptDir}/* "$out/share/comfy-ui/scripts/"

              # Install the launcher script
              ln -s "$out/share/comfy-ui/scripts/launcher.sh" "$out/bin/comfy-ui-launcher"
              chmod +x "$out/bin/comfy-ui-launcher"

              # Create a symlink to the launcher
              ln -s "$out/bin/comfy-ui-launcher" "$out/bin/comfy-ui"
            '';

            meta = with pkgs.lib; {
              description = "ComfyUI with Python 3.12";
              homepage = "https://github.com/comfyanonymous/ComfyUI";
              license = licenses.gpl3;
              platforms = platforms.all;
              mainProgram = "comfy-ui";
            };
          };

          # Docker image for ComfyUI (CPU)
          dockerImage = pkgs.dockerTools.buildImage {
            name = "comfy-ui";
            tag = "latest";

            # Include essential utilities and core dependencies
            copyToRoot = pkgs.buildEnv {
              name = "root";
              paths = [
                pkgs.bash
                pkgs.coreutils
                pkgs.netcat
                pkgs.git
                pkgs.curl
                pkgs.cacert
                pkgs.libGL
                pkgs.libGLU
                pkgs.stdenv.cc.cc.lib
                default
              ];
              pathsToLink = [
                "/bin"
                "/etc"
                "/lib"
                "/share"
              ];
            };

            # Set up volumes and ports
            config = {
              Cmd = [
                "/bin/bash"
                "-c"
                "export COMFY_USER_DIR=/data && mkdir -p /data && /bin/comfy-ui --listen 0.0.0.0"
              ];
              Env = [
                "COMFY_USER_DIR=/data"
                "PATH=/bin:/usr/bin"
                "PYTHONUNBUFFERED=1"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "LD_LIBRARY_PATH=${pkgs.stdenv.cc.cc.lib}/lib"
                "CUDA_VERSION=cpu"
              ];
              ExposedPorts = {
                "8188/tcp" = { };
              };
              WorkingDir = "/data";
              Volumes = {
                "/data" = { };
              };
              Healthcheck = {
                Test = [
                  "CMD"
                  "nc"
                  "-z"
                  "localhost"
                  "8188"
                ];
                Interval = 30000000000; # 30 seconds in nanoseconds
                Timeout = 5000000000; # 5 seconds in nanoseconds
                Retries = 3;
                StartPeriod = 60000000000; # 60 seconds grace period for startup
              };
              Labels = {
                "org.opencontainers.image.title" = "ComfyUI";
                "org.opencontainers.image.description" =
                  "ComfyUI - The most powerful and modular diffusion model GUI";
                "org.opencontainers.image.version" = comfyuiVersion;
                "org.opencontainers.image.source" = "https://github.com/utensils/nix-comfyui";
                "org.opencontainers.image.licenses" = "GPL-3.0";
              };
            };
          };

          # Docker image for ComfyUI with CUDA support
          dockerImageCuda = pkgs.dockerTools.buildImage {
            name = "comfy-ui";
            tag = "cuda";

            # Include essential utilities, core dependencies, and CUDA libraries
            copyToRoot = pkgs.buildEnv {
              name = "root";
              paths = [
                pkgs.bash
                pkgs.coreutils
                pkgs.netcat
                pkgs.git
                pkgs.curl
                pkgs.cacert
                pkgs.libGL
                pkgs.libGLU
                pkgs.stdenv.cc.cc.lib
                default
              ];
              pathsToLink = [
                "/bin"
                "/etc"
                "/lib"
                "/share"
              ];
            };

            # Set up volumes and ports
            config = {
              Cmd = [
                "/bin/bash"
                "-c"
                "export COMFY_USER_DIR=/data && mkdir -p /data && /bin/comfy-ui --listen 0.0.0.0"
              ];
              Env = [
                "COMFY_USER_DIR=/data"
                "PATH=/bin:/usr/bin"
                "PYTHONUNBUFFERED=1"
                "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
                "LD_LIBRARY_PATH=${pkgs.stdenv.cc.cc.lib}/lib"
                "NVIDIA_VISIBLE_DEVICES=all"
                "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
                "CUDA_VERSION=cu124"
              ];
              ExposedPorts = {
                "8188/tcp" = { };
              };
              WorkingDir = "/data";
              Volumes = {
                "/data" = { };
              };
              Healthcheck = {
                Test = [
                  "CMD"
                  "nc"
                  "-z"
                  "localhost"
                  "8188"
                ];
                Interval = 30000000000; # 30 seconds in nanoseconds
                Timeout = 5000000000; # 5 seconds in nanoseconds
                Retries = 3;
                StartPeriod = 60000000000; # 60 seconds grace period for startup
              };
              Labels = {
                "org.opencontainers.image.title" = "ComfyUI CUDA";
                "org.opencontainers.image.description" = "ComfyUI with CUDA support for GPU acceleration";
                "org.opencontainers.image.version" = comfyuiVersion;
                "org.opencontainers.image.source" = "https://github.com/utensils/nix-comfyui";
                "org.opencontainers.image.licenses" = "GPL-3.0";
                "com.nvidia.volumes.needed" = "nvidia_driver";
              };
            };
          };
        };
      in
      {
        # Export packages
        inherit packages;

        # Define apps
        apps = rec {
          default = {
            type = "app";
            program = "${packages.default}/bin/comfy-ui";
            meta = {
              description = "Run ComfyUI with Nix";
            };
          };

          # Add a buildDocker command
          buildDocker =
            let
              script = pkgs.writeShellScriptBin "build-docker" ''
                echo "Building Docker image for ComfyUI..."
                # Load the Docker image directly
                ${pkgs.docker}/bin/docker load < ${self.packages.${system}.dockerImage}
                echo "Docker image built successfully! You can now run it with:"
                echo "docker run -p 8188:8188 -v \$PWD/data:/data comfy-ui:latest"
              '';
            in
            {
              type = "app";
              program = "${script}/bin/build-docker";
              meta = {
                description = "Build ComfyUI Docker image (CPU)";
              };
            };

          # Add a buildDockerCuda command
          buildDockerCuda =
            let
              script = pkgs.writeShellScriptBin "build-docker-cuda" ''
                echo "Building Docker image for ComfyUI with CUDA support..."
                # Load the Docker image directly
                ${pkgs.docker}/bin/docker load < ${self.packages.${system}.dockerImageCuda}
                echo "CUDA-enabled Docker image built successfully! You can now run it with:"
                echo "docker run --gpus all -p 8188:8188 -v \$PWD/data:/data comfy-ui:cuda"
                echo ""
                echo "Note: Requires nvidia-container-toolkit and Docker GPU support."
              '';
            in
            {
              type = "app";
              program = "${script}/bin/build-docker-cuda";
              meta = {
                description = "Build ComfyUI Docker image with CUDA support";
              };
            };

          # Update helper script
          update = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "update-comfyui" ''
                set -e
                echo "Fetching latest ComfyUI release..."
                LATEST=$(curl -s https://api.github.com/repos/comfyanonymous/ComfyUI/releases/latest | ${pkgs.jq}/bin/jq -r '.tag_name')
                echo "Latest version: $LATEST"
                echo ""
                echo "To update, modify these values in flake.nix:"
                echo "  comfyuiVersion = \"''${LATEST#v}\";"
                echo ""
                echo "Then run: nix flake update"
                echo "And update the hash with: nix build 2>&1 | grep 'got:' | awk '{print \$2}'"
              ''
            );
            meta = {
              description = "Check for ComfyUI updates";
            };
          };

          # Linting and formatting apps
          lint =
            let
              script = pkgs.writeShellScriptBin "lint" ''
                echo "Running ruff linter..."
                ${pkgs.ruff}/bin/ruff check --no-cache src/
              '';
            in
            {
              type = "app";
              program = "${script}/bin/lint";
              meta = {
                description = "Run ruff linter on Python code";
              };
            };

          format =
            let
              script = pkgs.writeShellScriptBin "format" ''
                echo "Formatting code with ruff..."
                ${pkgs.ruff}/bin/ruff format --no-cache src/
              '';
            in
            {
              type = "app";
              program = "${script}/bin/format";
              meta = {
                description = "Format Python code with ruff";
              };
            };

          lint-fix =
            let
              script = pkgs.writeShellScriptBin "lint-fix" ''
                echo "Running ruff linter with auto-fix..."
                ${pkgs.ruff}/bin/ruff check --no-cache --fix src/
              '';
            in
            {
              type = "app";
              program = "${script}/bin/lint-fix";
              meta = {
                description = "Run ruff linter with auto-fix";
              };
            };

          type-check =
            let
              script = pkgs.writeShellScriptBin "type-check" ''
                echo "Running pyright type checker..."
                ${pkgs.pyright}/bin/pyright src/
              '';
            in
            {
              type = "app";
              program = "${script}/bin/type-check";
              meta = {
                description = "Run pyright type checker on Python code";
              };
            };

          check-all =
            let
              script = pkgs.writeShellScriptBin "check-all" ''
                echo "Running all checks..."
                echo ""
                echo "==> Running ruff linter..."
                ${pkgs.ruff}/bin/ruff check --no-cache src/
                RUFF_EXIT=$?
                echo ""
                echo "==> Running pyright type checker..."
                ${pkgs.pyright}/bin/pyright src/
                PYRIGHT_EXIT=$?
                echo ""
                if [ $RUFF_EXIT -eq 0 ] && [ $PYRIGHT_EXIT -eq 0 ]; then
                  echo "All checks passed!"
                  exit 0
                else
                  echo "Some checks failed."
                  exit 1
                fi
              '';
            in
            {
              type = "app";
              program = "${script}/bin/check-all";
              meta = {
                description = "Run all Python code checks (ruff + pyright)";
              };
            };
        };

        # Define development shell
        devShells.default = pkgs.mkShell {
          packages =
            [
              pythonEnv
              pkgs.stdenv.cc
              pkgs.libGL
              pkgs.libGLU
              # Development tools
              pkgs.git
              pkgs.shellcheck
              pkgs.shfmt
              pkgs.nixfmt-rfc-style
              # Python linting and type checking
              pkgs.ruff
              pkgs.pyright
              # Utilities
              pkgs.jq
              pkgs.curl
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              # macOS-specific tools
              pkgs.darwin.apple_sdk.frameworks.Metal
            ];

          shellHook = ''
            echo "ComfyUI development environment activated"
            echo "  ComfyUI version: ${comfyuiVersion}"
            export COMFY_USER_DIR="$HOME/.config/comfy-ui"
            mkdir -p "$COMFY_USER_DIR"
            echo "User data will be stored in $COMFY_USER_DIR"
            export PYTHONPATH="$PWD:$PYTHONPATH"
          '';
        };

        # Formatter for `nix fmt`
        formatter = pkgs.nixfmt-rfc-style;

        # Checks for CI (run with `nix flake check`)
        checks = {
          # Verify the package builds
          package = packages.default;

          # Python linting with ruff
          ruff-check =
            pkgs.runCommand "ruff-check"
              {
                nativeBuildInputs = [ pkgs.ruff ];
                src = ./.;
              }
              ''
                cp -r $src source
                chmod -R u+w source
                cd source
                # Disable cache to avoid permission issues in Nix sandbox
                ${pkgs.ruff}/bin/ruff check --no-cache src/
                touch $out
              '';

          # Python type checking with pyright
          pyright-check =
            pkgs.runCommand "pyright-check"
              {
                nativeBuildInputs = [ pkgs.pyright ];
                src = ./.;
              }
              ''
                cp -r $src source
                chmod -R u+w source
                cd source
                ${pkgs.pyright}/bin/pyright src/
                touch $out
              '';

          # Shell script linting with cross-file analysis
          shellcheck =
            pkgs.runCommand "shellcheck"
              {
                nativeBuildInputs = [ pkgs.shellcheck ];
                src = ./.;
              }
              ''
                cp -r $src source
                chmod -R u+w source
                cd source/scripts
                # Check launcher.sh with -x to follow all source statements
                # This allows shellcheck to see variables defined in config.sh and used in install.sh
                shellcheck -x launcher.sh
                # Also check individual utility scripts
                shellcheck logger.sh runtime.sh persistence.sh
                touch $out
              '';

          # Nix formatting check
          nixfmt =
            pkgs.runCommand "nixfmt-check"
              {
                nativeBuildInputs = [ pkgs.nixfmt-rfc-style ];
                src = ./.;
              }
              ''
                cp -r $src source
                chmod -R u+w source
                cd source
                nixfmt --check flake.nix
                touch $out
              '';
        };
      }
    )
    // {
      # Overlay for integrating with other flakes
      overlays.default = final: prev: {
        comfy-ui = self.packages.${final.system}.default;
      };
    };
}
