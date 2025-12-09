# ComfyUI Nix Flake

**⚠️ NOTE: Model and workflow persistence should work but has not been thoroughly tested yet. Please report any issues.**

A Nix flake for installing and running [ComfyUI](https://github.com/comfyanonymous/ComfyUI) with Python 3.12. Supports both macOS (Intel/Apple Silicon) and Linux with automatic GPU detection.

![ComfyUI Demo](comfyui-demo.gif)

> **Note:** Pull requests are more than welcome! Contributions to this open project are appreciated.

## Quick Start

```bash
nix run github:utensils/nix-comfyui -- --open
```

## Features

- Provides ComfyUI packaged with Python 3.12
- Reproducible environment through Nix flakes
- Hybrid approach: Nix for environment management, pip for Python dependencies
- Cross-platform support: macOS (Intel/Apple Silicon) and Linux
- Automatic GPU detection: CUDA on Linux, MPS on Apple Silicon
- Configurable CUDA version via `CUDA_VERSION` environment variable
- Persistent user data directory with automatic version upgrades
- Includes ComfyUI-Manager for easy extension installation
- Improved model download experience with automatic backend downloads
- Flake checks for CI validation (`nix flake check`)
- Built-in formatter (`nix fmt`)
- Overlay for easy integration with other flakes

## Additional Options

```bash
# Run a specific version using a commit hash
nix run github:utensils/nix-comfyui/[commit-hash] -- --open
```

### Command Line Options

- `--open`: Automatically opens ComfyUI in your browser when the server is ready
- `--port=XXXX`: Run ComfyUI on a specific port (default: 8188)
- `--debug` or `--verbose`: Enable detailed debug logging

### Environment Variables

- `CUDA_VERSION`: CUDA version for PyTorch (default: `cu124`, options: `cu118`, `cu121`, `cu124`, `cpu`)
- `COMFY_USER_DIR`: Override the default user data directory (default: `~/.config/comfy-ui`)

```bash
# Example: Use CUDA 12.1
CUDA_VERSION=cu121 nix run github:utensils/nix-comfyui
```

### Development Shell

```bash
# Enter a development shell with all dependencies
nix develop
```

The development shell includes: Python 3.12, git, shellcheck, shfmt, nixfmt, ruff, jq, and curl.

### Flake Commands

```bash
# Format all Nix files
nix fmt

# Run CI checks (build, shellcheck, nixfmt)
nix flake check

# Check for ComfyUI updates
nix run .#update
```

### Installation

You can install ComfyUI to your profile:

```bash
nix profile install github:utensils/nix-comfyui
```

## Customization

The flake is designed to be simple and extensible. You can customize it by:

1. Adding Python packages in the `pythonEnv` definition
2. Modifying the launcher script in `scripts/launcher.sh`
3. Pinning to a specific ComfyUI version by changing the version variables at the top of `flake.nix`

### Using the Overlay

You can integrate this flake into your own Nix configuration using the overlay:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-comfyui.url = "github:utensils/nix-comfyui";
  };

  outputs = { self, nixpkgs, nix-comfyui }: {
    # Use in NixOS configuration
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ nix-comfyui.overlays.default ];
          environment.systemPackages = [ pkgs.comfy-ui ];
        })
      ];
    };
  };
}
```

### Project Structure

This flake uses a modular, multi-file approach for better maintainability:

- `flake.nix` - Main flake definition and package configuration
- `scripts/` - Modular launcher scripts:
  - `launcher.sh` - Main entry point that orchestrates the launching process
  - `config.sh` - Configuration variables and settings
  - `logger.sh` - Logging utilities with support for different verbosity levels
  - `install.sh` - Installation and setup procedures
  - `persistence.sh` - Symlink creation and data persistence management
  - `runtime.sh` - Runtime execution and process management

This modular structure makes the codebase much easier to maintain, debug, and extend as features are added. Each script has a single responsibility, improving code organization and readability.

## Data Persistence

User data is stored in `~/.config/comfy-ui` with the following structure:

- `app/` - ComfyUI application code (auto-updated when flake changes)
- `models/` - Stable Diffusion models and other model files
- `output/` - Generated images and other outputs
- `user/` - User configuration and custom nodes
- `input/` - Input files for processing

This structure ensures your models, outputs, and custom nodes persist between application updates.

## System Requirements

### macOS
- macOS 10.15+ (Intel or Apple Silicon)
- Nix package manager

### Linux
- x86_64 Linux distribution
- Nix package manager
- NVIDIA GPU with drivers (optional, for CUDA acceleration)
- glibc 2.27+

## Platform Support

### Apple Silicon Support

- Uses stable PyTorch releases with MPS (Metal Performance Shaders) support
- Enables FP16 precision mode for better performance
- Sets optimal memory management parameters for macOS

### Linux Support

- Automatic NVIDIA GPU detection and CUDA setup
- Configurable CUDA version (default: 12.4, supports 11.8, 12.1, 12.4)
- Automatic library path configuration for system libraries
- Falls back to CPU-only mode if no GPU is detected

### GPU Detection

The flake automatically detects your hardware and installs the appropriate PyTorch version:
- **Linux with NVIDIA GPU**: PyTorch with CUDA support (configurable via `CUDA_VERSION`)
- **macOS with Apple Silicon**: PyTorch with MPS acceleration
- **Other systems**: CPU-only PyTorch

## Version Information

This flake currently provides:

- ComfyUI v0.3.76
- Python 3.12
- PyTorch stable releases (with MPS support on Apple Silicon, CUDA on Linux)
- ComfyUI Frontend Package 1.34.7
- ComfyUI-Manager for extension management

To check for updates:
```bash
nix run .#update
```

## Model Downloading Patch

This flake includes a custom patch for the model downloading experience. Unlike the default ComfyUI implementation, our patch ensures that when models are selected in the UI, they are automatically downloaded in the background without requiring manual intervention. This significantly improves the user experience by eliminating the need to manually manage model downloads, especially for new users who may not be familiar with the process of obtaining and placing model files.

## Source Code Organization

The codebase follows a modular structure under the `src` directory to improve maintainability and organization:

```
src/
├── custom_nodes/           # Custom node implementations
│   ├── model_downloader/   # Automatic model downloading functionality
│   │   ├── js/             # Frontend JavaScript components
│   │   └── ...             # Backend implementation files
│   └── main.py             # Entry point for custom nodes
├── patches/                # Runtime patches for ComfyUI
│   ├── custom_node_init.py # Custom node initialization
│   └── main.py             # Entry point for patches
└── persistence/            # Data persistence implementation
    ├── persistence.py      # Core persistence logic
    └── main.py             # Persistence entry point
```

### Component Descriptions

- **custom_nodes**: Contains custom node implementations that extend ComfyUI's functionality
  - **model_downloader**: Provides automatic downloading of models when selected in the UI
    - **js**: Frontend components for download status and progress reporting
    - **model_downloader_patch.py**: Backend API endpoints for model downloading

- **patches**: Contains runtime patches that modify ComfyUI's behavior
  - **custom_node_init.py**: Initializes custom nodes and registers their API endpoints
  - **main.py**: Coordinates the loading and application of patches

- **persistence**: Manages data persistence across ComfyUI runs
  - **persistence.py**: Creates and maintains the directory structure and symlinks
  - **main.py**: Handles the persistence setup before launching ComfyUI

This structure ensures clear separation of concerns and makes the codebase easier to maintain and extend.

## Docker Support

This flake includes Docker support for running ComfyUI in a containerized environment while preserving all functionality. Both CPU and CUDA-enabled GPU images are available.

### Building the Docker Image

#### CPU Version

Use the included `buildDocker` command to create a Docker image:

```bash
# Build the Docker image
nix run .#buildDocker

# Or from remote
nix run github:utensils/nix-comfyui#buildDocker
```

This creates a Docker image named `comfy-ui:latest` in your local Docker daemon.

#### CUDA (GPU) Version

For Linux systems with NVIDIA GPUs, build the CUDA-enabled image:

```bash
# Build the CUDA-enabled Docker image
nix run .#buildDockerCuda

# Or from remote
nix run github:utensils/nix-comfyui#buildDockerCuda
```

This creates a Docker image named `comfy-ui:cuda` with GPU acceleration support.

### Running the Docker Container

#### CPU Version

Run the container with:

```bash
# Create a data directory for persistence
mkdir -p ./data

# Run the container
docker run -p 8188:8188 -v "$PWD/data:/data" comfy-ui:latest
```

#### CUDA (GPU) Version

For GPU-accelerated execution:

```bash
# Create a data directory for persistence
mkdir -p ./data

# Run with GPU support
docker run --gpus all -p 8188:8188 -v "$PWD/data:/data" comfy-ui:cuda
```

**Requirements for CUDA support:**
- NVIDIA GPU with CUDA support
- NVIDIA drivers installed on the host system
- `nvidia-container-toolkit` package installed
- Docker configured for GPU support

To install nvidia-container-toolkit on Ubuntu/Debian:
```bash
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker
```

### Docker Image Features

- **Full functionality**: Includes all the features of the regular ComfyUI installation
- **Persistence**: Data is stored in a mounted volume at `/data`
- **Port exposure**: Web UI available on port 8188
- **Essential utilities**: Includes bash, coreutils, git, and other necessary tools
- **Proper environment**: All environment variables set correctly for containerized operation
- **GPU support**: CUDA version includes proper environment variables for NVIDIA GPU access

The Docker image follows the same modular structure as the regular installation, ensuring consistency across deployment methods.

## License

This flake is provided under the MIT license. ComfyUI itself is licensed under GPL-3.0.
