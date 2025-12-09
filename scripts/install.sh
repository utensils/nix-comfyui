#!/usr/bin/env bash
# install.sh: Installation steps for ComfyUI

# Source shared libraries
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
source "$SCRIPT_DIR/logger.sh"

# Create directory structures
create_directories() {
    log_section "Creating directory structure"
    
    # Add debugging to see what's in DIRECTORIES
    log_debug "Directory types: ${!DIRECTORIES[*]}"
    
    for dir_type in "${!DIRECTORIES[@]}"; do
        log_debug "Creating $dir_type directories: ${DIRECTORIES[$dir_type]}"
        for dir in ${DIRECTORIES[$dir_type]}; do
            mkdir -p "$dir"
            log_debug "Created: $dir"
        done
    done
    
    log_info "All directories created successfully"
}

# Install ComfyUI core
install_comfyui() {
    log_section "Installing ComfyUI $COMFY_VERSION"

    # Remove existing directory (but keep symlinked content safe)
    log_info "Preparing fresh installation in $CODE_DIR"
    rm -rf "$CODE_DIR"
    mkdir -p "$CODE_DIR"

    # Copy the ComfyUI source
    log_info "Copying ComfyUI source code"
    cp -r "$COMFYUI_SRC"/* "$CODE_DIR/"
    echo "$COMFY_VERSION" > "$CODE_DIR/VERSION"

    # Copy persistence scripts
    cp -f "$PERSISTENCE_MAIN_SCRIPT" "$CODE_DIR/persistent_main.py" 2>/dev/null || true

    # Ensure proper permissions
    chmod -R u+rw "$CODE_DIR"

    # Initialize a git repo to satisfy ComfyUI-Manager's version check
    # Nix manages the actual version, but Manager expects a git repo
    # Note: Manager expects 'master' branch, not 'main'
    log_info "Initializing git repo for ComfyUI-Manager compatibility"
    (
        cd "$CODE_DIR"
        git init -q -b master
        git config user.email "nix@localhost"
        git config user.name "Nix Build"
        git add -A
        git commit -q -m "ComfyUI v$COMFY_VERSION (managed by nix-comfyui)"
        git tag -a "v$COMFY_VERSION" -m "Version $COMFY_VERSION"
    ) 2>/dev/null || log_warn "Could not initialize git repo"

    # Ensure model directories exist in the CODE_DIR for symlinks
    mkdir -p "$CODE_DIR/models"

    log_info "ComfyUI core installed successfully"
}

# Install/update ComfyUI-Manager
install_comfyui_manager() {
    log_section "Setting up ComfyUI-Manager"
    
    if [ ! -d "$COMFY_MANAGER_DIR" ]; then
        log_info "Installing ComfyUI-Manager..."
        git -c commit.gpgsign=false clone https://github.com/Comfy-Org/ComfyUI-Manager.git "$COMFY_MANAGER_DIR"
    elif [ -z "$(find "$COMFY_MANAGER_DIR" -name ".git" -mtime -7 2>/dev/null)" ]; then
        log_info "Updating ComfyUI-Manager (last updated > 7 days ago)"
        cd "$COMFY_MANAGER_DIR" && git -c commit.gpgsign=false pull
    else
        log_info "ComfyUI-Manager is up to date"
    fi
    
    # Create ComfyUI-Manager config
    # Note: ComfyUI version is managed by Nix, so we disable some update features
    mkdir -p "$CODE_DIR/user/default/ComfyUI-Manager"
    cat > "$CODE_DIR/user/default/ComfyUI-Manager/config.ini" << 'CONFIG_EOF'
[default]
config_version=0.7

[manager]
# Model directories (relative to ComfyUI root)
control_net_model_dir=\models\controlnet
upscale_model_dir=\models\upscale_models
lora_model_dir=\models\loras
vae_model_dir=\models\vae
gligen_model_dir=\models\gligen
checkpoint_dir=\models\checkpoints
custom_nodes_dir=custom_nodes
clip_vision_dir=\models\clip_vision
embedding_dir=\models\embeddings
loras_dir=\models\loras

# Security and hosting
# Security levels: strict, normal, middle, weak, normal-
# 'middle' allows custom node management while maintaining reasonable security
security_level=middle
prevent_direct_install=False
privileged_hosting=False

# Nix-managed installation settings
# ComfyUI core updates are handled by nix-comfyui flake
# Custom nodes can still be managed through ComfyUI-Manager
skip_update_check=True
file_logging=True
CONFIG_EOF

    log_info "ComfyUI-Manager setup completed"
}

# Install model downloader extension
install_model_downloader() {
    log_section "Setting up model downloader"
    
    # Ensure fresh installation
    if [ -d "$MODEL_DOWNLOADER_PERSISTENT_DIR" ]; then
        log_info "Removing existing model downloader for fresh install"
        rm -rf "$MODEL_DOWNLOADER_PERSISTENT_DIR"
    fi
    
    # Create directories
    mkdir -p "$MODEL_DOWNLOADER_PERSISTENT_DIR/js"
    
    # Install model downloader to persistent directory
    log_info "Copying model downloader files"
    cp -r "$MODEL_DOWNLOADER_DIR"/* "$MODEL_DOWNLOADER_PERSISTENT_DIR/"
    
    # Backward compatibility
    cp "$MODEL_DOWNLOADER_PERSISTENT_DIR/model_downloader_patch.py" "$CODE_DIR/model_downloader_patch.py"
    
    # Ensure frontend integration works through custom node approach
    if [ -d "$CUSTOM_NODE_DIR/model_downloader" ]; then
        log_info "Model downloader extension installed successfully"
    else
        log_warn "Model downloader extension could not be verified"
    fi
}

# Detect GPU and determine PyTorch installation
# Uses stable PyTorch releases instead of nightly builds for production stability
# CUDA version can be configured via CUDA_VERSION environment variable
detect_pytorch_version() {
    local TORCH_INSTALL=""
    local cuda_ver="${CUDA_VERSION:-cu124}"

    # Check for NVIDIA GPU
    if command -v nvidia-smi &> /dev/null; then
        log_info "NVIDIA GPU detected"
        if nvidia-smi &> /dev/null; then
            log_info "NVIDIA driver is functional"
            log_info "Using CUDA version: $cuda_ver (override with CUDA_VERSION env var)"
            # Install stable PyTorch with CUDA support
            TORCH_INSTALL="torch torchvision torchaudio --index-url https://download.pytorch.org/whl/${cuda_ver}"
        else
            log_warn "NVIDIA driver not functioning properly, falling back to CPU"
            TORCH_INSTALL="torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]] && [[ $(uname -m) == "arm64" ]]; then
        log_info "Apple Silicon detected, using MPS acceleration"
        # On macOS, use default PyPI packages which include MPS support
        TORCH_INSTALL="torch torchvision torchaudio"
    else
        log_info "No GPU detected, using CPU-only PyTorch"
        TORCH_INSTALL="torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cpu"
    fi

    echo "$TORCH_INSTALL"
}

# Setup Python virtual environment
setup_venv() {
    log_section "Setting up Python environment"

    local version_file="$COMFY_VENV/.comfyui_version"
    local needs_requirements_update=false

    if [ ! -d "$COMFY_VENV" ]; then
        log_info "Creating virtual environment for ComfyUI at $COMFY_VENV"
        "$PYTHON_ENV" -m venv "$COMFY_VENV"
        needs_requirements_update=true
    else
        log_info "Using existing Python environment"
        # Check if ComfyUI version changed - if so, we need to update requirements
        if [ -f "$version_file" ]; then
            local installed_version=$(cat "$version_file")
            if [ "$installed_version" != "$COMFY_VERSION" ]; then
                log_info "ComfyUI version changed ($installed_version -> $COMFY_VERSION)"
                needs_requirements_update=true
            fi
        else
            # No version file means old installation, needs update
            log_info "Upgrading venv for new ComfyUI version"
            needs_requirements_update=true
        fi
    fi

    if [ "$needs_requirements_update" = true ]; then
        log_info "Installing/updating Python dependencies for ComfyUI $COMFY_VERSION"
        "$COMFY_VENV/bin/pip" install --upgrade pip

        # Install from requirements.txt (primary method)
        log_info "Installing from requirements.txt..."
        "$COMFY_VENV/bin/pip" install -r "$CODE_DIR/requirements.txt" || {
            log_warn "Some requirements.txt packages failed, continuing..."
        }

        # Install base packages
        "$COMFY_VENV/bin/pip" install $BASE_PACKAGES

        # Detect and install appropriate PyTorch version
        local TORCH_INSTALL=$(detect_pytorch_version)
        log_info "Installing PyTorch: $TORCH_INSTALL"
        "$COMFY_VENV/bin/pip" install $TORCH_INSTALL

        # Install additional packages (includes pydantic, alembic for v0.3.76+)
        "$COMFY_VENV/bin/pip" install $ADDITIONAL_PACKAGES

        # Record installed version
        echo "$COMFY_VERSION" > "$version_file"
        log_info "Python environment setup complete for ComfyUI $COMFY_VERSION"

        # Clear CUDA check file to re-verify after update
        rm -f "$COMFY_VENV/.cuda_checked"
    fi

    # Check if we need to upgrade PyTorch for GPU support
    local cuda_check_file="$COMFY_VENV/.cuda_checked"
    if [ ! -f "$cuda_check_file" ] && command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
        # Test CUDA availability with proper library paths
        local cuda_test_result=1
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" "$COMFY_VENV/bin/python" -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null && cuda_test_result=0
        else
            "$COMFY_VENV/bin/python" -c "import torch; exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null && cuda_test_result=0
        fi

        if [ $cuda_test_result -ne 0 ]; then
            log_warn "CUDA not available in current PyTorch installation"
            log_info "Reinstalling PyTorch with CUDA support..."
            local TORCH_INSTALL=$(detect_pytorch_version)
            "$COMFY_VENV/bin/pip" uninstall -y torch torchvision torchaudio
            "$COMFY_VENV/bin/pip" install $TORCH_INSTALL
            touch "$cuda_check_file"
        else
            log_info "PyTorch already has CUDA support"
            touch "$cuda_check_file"
        fi
    else
        log_debug "Skipping CUDA check (already verified)"
    fi
}

# Setup persistence scripts
setup_persistence_scripts() {
    log_section "Setting up persistence scripts"
    
    # Copy our persistence scripts to ensure directory paths are persistent
    cp -f "$PERSISTENCE_SCRIPT" "$CODE_DIR/persistent.py" 2>/dev/null || true
    cp -f "$PERSISTENCE_MAIN_SCRIPT" "$CODE_DIR/persistent_main.py" 2>/dev/null || true
    chmod +x "$CODE_DIR/persistent.py"
    chmod +x "$CODE_DIR/persistent_main.py"
    
    log_info "Persistence scripts installed"
}

# Main installation function
install_all() {
    create_directories
    install_comfyui
    install_comfyui_manager
    install_model_downloader
    setup_venv
    setup_persistence_scripts
    
    # Now set up the actual symlinks
    source "$SCRIPT_DIR/persistence.sh"
    setup_persistence
    
    log_section "Installation complete"
    log_info "ComfyUI $COMFY_VERSION has been successfully installed"
}
