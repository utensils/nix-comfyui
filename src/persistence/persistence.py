#!/usr/bin/env python3

"""
Persistence module for ComfyUI.

This script ensures models and other user data persist across runs.
"""

from __future__ import annotations

import logging
import os
import shutil
import sys
from pathlib import Path

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("persistence")


class _PersistenceState:
    """Module-level state holder for persistence configuration."""

    def __init__(self) -> None:
        self.initialized: bool = False
        self.base_dir: str | None = None


# Single instance for module state
_state = _PersistenceState()


def ensure_dir(path: str | Path) -> None:
    """Ensure a directory exists."""
    os.makedirs(path, exist_ok=True)


def create_symlink(source: str | Path, target: str | Path) -> None:
    """Create a symlink, removing target first if it exists."""
    target_path = Path(target)
    source_path = Path(source)

    if target_path.exists() or target_path.is_symlink():
        if target_path.is_dir() and not target_path.is_symlink():
            shutil.rmtree(target_path)
        else:
            target_path.unlink()

    # Create parent dirs if needed
    target_path.parent.mkdir(parents=True, exist_ok=True)

    # Create the symlink
    os.symlink(source_path, target_path, target_is_directory=source_path.is_dir())
    logger.info("Created symlink: %s -> %s", source, target)


def patch_model_downloader() -> None:
    """Minimal patch for model_downloader to ensure it works with our folder paths."""
    try:
        # Ensure the model_downloader_patch.py is properly loaded
        app_dir = os.environ.get("COMFY_APP_DIR")
        if app_dir:
            patch_file = os.path.join(app_dir, "model_downloader_patch.py")
            if not os.path.exists(patch_file):
                custom_node_patch = os.path.join(
                    app_dir, "custom_nodes", "model_downloader", "model_downloader_patch.py"
                )
                if os.path.exists(custom_node_patch):
                    try:
                        os.symlink(custom_node_patch, patch_file)
                        logger.info(
                            "Created symlink for model_downloader_patch.py: %s -> %s",
                            custom_node_patch,
                            patch_file,
                        )
                    except OSError:
                        shutil.copy2(custom_node_patch, patch_file)
                        logger.info(
                            "Copied model_downloader_patch.py to app directory: %s -> %s",
                            custom_node_patch,
                            patch_file,
                        )

        logger.info("Model downloader will use patched folder paths")
    except OSError:
        logger.exception("Error preparing model downloader")


def patch_folder_paths(base_dir: str) -> None:
    """Patch the folder_paths module to use our persistent directories."""
    try:
        import folder_paths  # type: ignore[import-not-found]

        # Store the original get_folder_paths function
        original_get_folder_paths = folder_paths.get_folder_paths

        def patched_get_folder_paths(folder_name: str) -> tuple[list[str], list[str]]:
            """Get folder paths with persistent directory override."""
            original_paths = original_get_folder_paths(folder_name)
            persistent_path = os.path.join(base_dir, "models", folder_name)

            if os.path.exists(persistent_path):
                logger.info("Using persistent path for %s: %s", folder_name, persistent_path)
                if len(original_paths) > 1:
                    return ([persistent_path], original_paths[1])
                return ([persistent_path], [])

            return original_paths

        # Store original function for direct access
        folder_paths.get_folder_paths_original = original_get_folder_paths

        def get_first_folder_path(folder_name: str) -> str | None:
            """Get the first path from a folder."""
            paths = folder_paths.get_folder_paths(folder_name)
            if paths and len(paths) > 0 and len(paths[0]) > 0:
                return paths[0][0]
            return None

        folder_paths.get_first_folder_path = get_first_folder_path
        folder_paths.get_folder_paths = patched_get_folder_paths

        # Set output and input directories
        output_dir = os.path.join(base_dir, "output")
        if os.path.exists(output_dir):
            logger.info("Setting output directory to: %s", output_dir)
            folder_paths.set_output_directory(output_dir)

        input_dir = os.path.join(base_dir, "input")
        if os.path.exists(input_dir):
            logger.info("Setting input directory to: %s", input_dir)
            folder_paths.set_input_directory(input_dir)

        # Set the temp directory
        temp_dir = os.path.join(base_dir, "temp")
        os.makedirs(temp_dir, exist_ok=True)
        folder_paths.set_temp_directory(temp_dir)

        # Set user directory
        user_dir = os.path.join(base_dir, "user")
        if os.path.exists(user_dir):
            logger.info("Setting user directory to: %s", user_dir)
            folder_paths.set_user_directory(user_dir)

        # Override paths in the module
        folder_paths.output_directory = output_dir
        folder_paths.input_directory = input_dir
        folder_paths.temp_directory = temp_dir
        folder_paths.user_directory = user_dir

        logger.info("Path patching complete")
    except ImportError:
        logger.warning("Could not import folder_paths module, skipping patching")
    except AttributeError:
        logger.exception("Error patching folder_paths - missing expected attributes")


def _migrate_existing_data(src_path: Path, dst_path: Path) -> None:
    """Migrate existing data from source to destination if needed."""
    if not src_path.is_dir() or not os.listdir(src_path):
        return

    for item in os.listdir(src_path):
        src = src_path / item
        dst = dst_path / item
        if not dst.exists():
            if src.is_dir():
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)


def _create_directory_symlink(
    persistent_path: Path, app_path: Path, dir_name: str
) -> None:
    """Create a symlink from app_path to persistent_path."""
    try:
        persistent_path.mkdir(parents=True, exist_ok=True)

        if app_path.exists() or app_path.is_symlink():
            if app_path.is_symlink():
                app_path.unlink()
            else:
                _migrate_existing_data(app_path, persistent_path)
                shutil.rmtree(app_path)

        os.symlink(persistent_path, app_path)
        logger.info("Created symlink: %s -> %s", persistent_path, app_path)
    except PermissionError:
        logger.exception("Permission denied creating symlink for %s", dir_name)
    except OSError:
        logger.exception("Error creating symlink for %s", dir_name)


def setup_persistence() -> str:
    """
    Set up the persistence for ComfyUI.

    Creates symlinks between the app directory and persistent storage.

    Returns:
        The base directory path used for persistence.
    """
    if _state.initialized and _state.base_dir is not None:
        return _state.base_dir

    # Create the persistent directory if it doesn't exist
    base_dir = os.environ.get(
        "COMFY_USER_DIR", os.path.join(os.path.expanduser("~"), ".config", "comfy-ui")
    )
    logger.info("Using persistent directory: %s", base_dir)

    # Get ComfyUI path
    app_dir = os.environ.get("COMFY_APP_DIR")
    if not app_dir:
        current_dir = os.path.dirname(os.path.realpath(__file__))
        if os.path.basename(current_dir) == "persistence":
            parent_dir = os.path.dirname(current_dir)
            if os.path.basename(parent_dir) == "src":
                app_dir = os.path.join(os.path.dirname(parent_dir), "app")
            else:
                app_dir = parent_dir
        else:
            app_dir = current_dir

    if not os.path.exists(app_dir):
        logger.warning("App directory not found at %s, using current directory", app_dir)
        app_dir = os.getcwd()

    logger.info("Using app directory: %s", app_dir)
    os.environ["COMFY_APP_DIR"] = app_dir

    # Model directories
    model_dirs = [
        "checkpoints",
        "loras",
        "vae",
        "controlnet",
        "embeddings",
        "upscale_models",
        "clip",
        "diffusers",
    ]

    # User data directories
    user_dirs = ["output", "input", "user", "temp"]

    # Create base directories
    os.makedirs(base_dir, exist_ok=True)
    os.makedirs(os.path.join(base_dir, "models"), exist_ok=True)

    # Create model symlinks
    for model_dir in model_dirs:
        persistent_path = Path(base_dir) / "models" / model_dir
        app_path = Path(app_dir) / "models" / model_dir
        _create_directory_symlink(persistent_path, app_path, model_dir)

    # Create user directory symlinks
    for user_dir in user_dirs:
        persistent_path = Path(base_dir) / user_dir
        app_path = Path(app_dir) / user_dir
        _create_directory_symlink(persistent_path, app_path, user_dir)

    # Set up environment
    os.environ["COMFY_SAVE_PATH"] = os.path.join(base_dir, "user")

    # Set command line args if needed
    if "--base-directory" not in sys.argv:
        sys.argv.extend(["--base-directory", base_dir])

    # Patch folder_paths module
    patch_folder_paths(base_dir)

    # Patch model downloader
    try:
        patch_model_downloader()
    except OSError:
        logger.exception("Error patching model downloader")

    logger.info("Persistence setup complete using %s", base_dir)

    _state.initialized = True
    _state.base_dir = base_dir
    return base_dir


def get_base_dir() -> str:
    """
    Get the base directory, initializing persistence if needed.

    Returns:
        The base directory path.
    """
    if _state.base_dir is None:
        return setup_persistence()
    return _state.base_dir


def is_initialized() -> bool:
    """Check if persistence has been initialized."""
    return _state.initialized


# This allows direct execution for testing
if __name__ == "__main__":
    setup_persistence()
    print("Persistence setup complete")
