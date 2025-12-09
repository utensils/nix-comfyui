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
      comfyuiVersion = "0.3.76";
      comfyuiRev = "30c259cac8c08ff8d015f9aff3151cb525c9b702";
      comfyuiHash = "sha256-RBVmggtQKopoygsm3CiMSJt2PucO0ou2t7uXzASSZY8=";
      frontendVersion = "1.34.7";
      frontendHash = "sha256-K+xxz/fZsS5usLNpqFhfvJS+bwQ4yvhGJgSRVCRMYJE=";
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

        # ComfyUI frontend package
        comfyui-frontend-package = pkgs.python312Packages.buildPythonPackage {
          pname = "comfyui-frontend-package";
          version = frontendVersion;
          format = "wheel";

          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/15/76/4102b054d0d955472307dc572a47c9b22cab826da0a2ef0434160dca9646/comfyui_frontend_package-${frontendVersion}-py3-none-any.whl";
            hash = frontendHash;
          };

          doCheck = false;
        };

        # Model downloader custom node
        modelDownloaderDir = ./src/custom_nodes/model_downloader;

        # Python environment with minimal dependencies
        # Most dependencies will be installed via pip in the virtual environment
        pythonEnv = pkgs.python312.buildEnv.override {
          extraLibs = with pkgs.python312Packages; [
            setuptools
            wheel
            pip
            virtualenv
            requests
            rich
            comfyui-frontend-package
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
              inherit comfyui-src comfyui-frontend-package;
              version = comfyuiVersion;
              frontendVersion = frontendVersion;
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
              Labels = {
                "org.opencontainers.image.title" = "ComfyUI";
                "org.opencontainers.image.description" = "ComfyUI - The most powerful and modular diffusion model GUI";
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
        apps = {
          default = flake-utils.lib.mkApp {
            drv = packages.default;
            name = "comfy-ui";
          };

          # Add a buildDocker command
          buildDocker = flake-utils.lib.mkApp {
            drv = pkgs.writeShellScriptBin "build-docker" ''
              echo "Building Docker image for ComfyUI..."
              # Load the Docker image directly
              ${pkgs.docker}/bin/docker load < ${self.packages.${system}.dockerImage}
              echo "Docker image built successfully! You can now run it with:"
              echo "docker run -p 8188:8188 -v \$PWD/data:/data comfy-ui:latest"
            '';
            name = "build-docker";
          };

          # Add a buildDockerCuda command
          buildDockerCuda = flake-utils.lib.mkApp {
            drv = pkgs.writeShellScriptBin "build-docker-cuda" ''
              echo "Building Docker image for ComfyUI with CUDA support..."
              # Load the Docker image directly
              ${pkgs.docker}/bin/docker load < ${self.packages.${system}.dockerImageCuda}
              echo "CUDA-enabled Docker image built successfully! You can now run it with:"
              echo "docker run --gpus all -p 8188:8188 -v \$PWD/data:/data comfy-ui:cuda"
              echo ""
              echo "Note: Requires nvidia-container-toolkit and Docker GPU support."
            '';
            name = "build-docker-cuda";
          };
        };

        # Define development shell
        devShells.default = pkgs.mkShell {
          packages = [
            pythonEnv
            pkgs.stdenv.cc
            pkgs.libGL
            pkgs.libGLU
            # Development tools
            pkgs.git
            pkgs.shellcheck
            pkgs.shfmt
            pkgs.nixfmt-rfc-style
            pkgs.ruff
            pkgs.jq
            pkgs.curl
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            # macOS-specific tools
            pkgs.darwin.apple_sdk.frameworks.Metal
          ];

          shellHook = ''
            echo "ComfyUI development environment activated"
            echo "  ComfyUI version: ${comfyuiVersion}"
            echo "  Frontend version: ${frontendVersion}"
            export COMFY_USER_DIR="$HOME/.config/comfy-ui"
            mkdir -p "$COMFY_USER_DIR"
            echo "User data will be stored in $COMFY_USER_DIR"
            export PYTHONPATH="$PWD:$PYTHONPATH"
          '';
        };

        # Formatter for `nix fmt`
        formatter = pkgs.nixfmt-rfc-style;

        # Checks for CI
        checks = {
          # Verify the package builds
          package = packages.default;

          # Shell script linting
          shellcheck = pkgs.runCommand "shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck ${./scripts}/*.sh
            touch $out
          '';

          # Nix formatting check
          nixfmt = pkgs.runCommand "nixfmt-check" { nativeBuildInputs = [ pkgs.nixfmt-rfc-style ]; } ''
            nixfmt --check ${./flake.nix}
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

      # Update helper script (run with: nix run .#update)
      apps.x86_64-linux.update = self.apps.x86_64-darwin.update;
      apps.aarch64-linux.update = self.apps.aarch64-darwin.update;
      apps.x86_64-darwin.update = {
        type = "app";
        program = toString (
          nixpkgs.legacyPackages.x86_64-darwin.writeShellScript "update-comfyui" ''
            set -e
            echo "Fetching latest ComfyUI release..."
            LATEST=$(curl -s https://api.github.com/repos/comfyanonymous/ComfyUI/releases/latest | ${nixpkgs.legacyPackages.x86_64-darwin.jq}/bin/jq -r '.tag_name')
            echo "Latest version: $LATEST"
            echo ""
            echo "To update, modify these values in flake.nix:"
            echo "  comfyuiVersion = \"''${LATEST#v}\";"
            echo ""
            echo "Then run: nix flake update"
            echo "And update the hash with: nix build 2>&1 | grep 'got:' | awk '{print \$2}'"
          ''
        );
      };
      apps.aarch64-darwin.update = {
        type = "app";
        program = toString (
          nixpkgs.legacyPackages.aarch64-darwin.writeShellScript "update-comfyui" ''
            set -e
            echo "Fetching latest ComfyUI release..."
            LATEST=$(curl -s https://api.github.com/repos/comfyanonymous/ComfyUI/releases/latest | ${nixpkgs.legacyPackages.aarch64-darwin.jq}/bin/jq -r '.tag_name')
            echo "Latest version: $LATEST"
            echo ""
            echo "To update, modify these values in flake.nix:"
            echo "  comfyuiVersion = \"''${LATEST#v}\";"
            echo ""
            echo "Then run: nix flake update"
            echo "And update the hash with: nix build 2>&1 | grep 'got:' | awk '{print \$2}'"
          ''
        );
      };
    };
}
