#!/usr/bin/env python3
"""Custom main.py to ensure path persistence in ComfyUI."""

from __future__ import annotations

import logging
import os
import sys
from typing import NoReturn

# Configure logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("persistence")


def get_persistent_dir() -> str:
    """Get or initialize the persistent directory."""
    try:
        # Try relative import first (when run as part of a package)
        try:
            from .persistence import setup_persistence
        except ImportError:
            # Fall back to absolute import based on file location
            script_dir = os.path.dirname(os.path.realpath(__file__))
            sys.path.insert(0, script_dir)
            from persistence import setup_persistence

        return setup_persistence()
    except ImportError:
        logger.exception("Could not import persistence module, falling back to basic setup")
        return os.environ.get(
            "COMFY_USER_DIR", os.path.join(os.path.expanduser("~"), ".config", "comfy-ui")
        )


def setup_command_line_args(persistent_dir: str) -> None:
    """Configure command line arguments for persistence."""
    # Force the base directory in command line arguments
    if "--base-directory" not in sys.argv:
        sys.argv.append("--base-directory")
        sys.argv.append(persistent_dir)
    else:
        # Find the index and replace its value
        try:
            index = sys.argv.index("--base-directory")
            if index + 1 < len(sys.argv):
                sys.argv[index + 1] = persistent_dir
        except ValueError:
            pass

    # Ensure the --persistent flag is set (filtered out before execution)
    if "--persistent" not in sys.argv:
        sys.argv.append("--persistent")


def ensure_utils_package(app_dir: str) -> None:
    """Ensure utils is recognized as a package if it exists."""
    utils_dir = os.path.join(app_dir, "utils")
    utils_init = os.path.join(utils_dir, "__init__.py")
    if os.path.exists(utils_dir) and os.path.isdir(utils_dir) and not os.path.exists(utils_init):
        try:
            with open(utils_init, "w") as f:
                f.write("# Auto-generated __init__.py for utils package\n")
        except OSError:
            logger.warning("Could not create utils __init__.py")


def run_comfyui() -> NoReturn:
    """Run the ComfyUI main.py with persistence enabled."""
    # Initialize persistence
    persistent_dir = get_persistent_dir()
    logger.info("Using persistent directory: %s", persistent_dir)

    # Setup command line args
    setup_command_line_args(persistent_dir)

    # Log current arguments for debugging
    logger.info("Command line arguments: %s", sys.argv)

    # Set environment variables
    os.environ["COMFY_USER_DIR"] = persistent_dir
    os.environ["COMFY_SAVE_PATH"] = os.path.join(persistent_dir, "user")

    # Get app directory
    app_dir = os.path.dirname(os.path.realpath(__file__))
    original_main = os.path.join(app_dir, "main.py")

    logger.info("Executing original main.py: %s", original_main)

    # Ensure app directory is in Python path
    sys.path.insert(0, app_dir)

    # Set current directory for relative imports
    os.chdir(app_dir)

    # Set environment variable for the app directory
    os.environ["COMFY_APP_DIR"] = app_dir

    # Ensure utils package exists
    ensure_utils_package(app_dir)

    # Build command, filtering out --persistent which main.py doesn't recognize
    filtered_args = [arg for arg in sys.argv[1:] if arg != "--persistent"]
    cmd = [sys.executable, original_main, *filtered_args]

    logger.info("Running command: %s", " ".join(cmd))

    # Execute and replace current process
    os.execve(sys.executable, cmd, os.environ)


if __name__ == "__main__":
    run_comfyui()
