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
          rev = "30c259cac8c08ff8d015f9aff3151cb525c9b702"; # v0.3.76
          hash = "sha256-RBVmggtQKopoygsm3CiMSJt2PucO0ou2t7uXzASSZY8=";
        };

        # ComfyUI frontend package
        comfyui-frontend-package = pkgs.python312Packages.buildPythonPackage {
          pname = "comfyui-frontend-package";
          version = "1.34.7";
          format = "wheel";

          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/15/76/4102b054d0d955472307dc572a47c9b22cab826da0a2ef0434160dca9646/comfyui_frontend_package-1.34.7-py3-none-any.whl";
            hash = "sha256-K+xxz/fZsS5usLNpqFhfvJS+bwQ4yvhGJgSRVCRMYJE=";
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
            version = "0.1.0";

            src = comfyui-src;

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
                "org.opencontainers.image.version" = "0.3.76";
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
                "org.opencontainers.image.version" = "0.3.76";
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
          ];

          shellHook = ''
            echo "ComfyUI development environment activated"
            export COMFY_USER_DIR="$HOME/.config/comfy-ui"
            mkdir -p "$COMFY_USER_DIR"
            echo "User data will be stored in $COMFY_USER_DIR"
            export PYTHONPATH="$PWD:$PYTHONPATH"
          '';
        };
      }
    );
}
