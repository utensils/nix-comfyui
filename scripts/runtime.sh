#!/usr/bin/env bash
# runtime.sh: Runtime functions for ComfyUI

# Guard against multiple sourcing
[[ -n "${_RUNTIME_SH_SOURCED:-}" ]] && return
_RUNTIME_SH_SOURCED=1

# Source shared libraries
[ -z "$SCRIPT_DIR" ] && SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
source "$SCRIPT_DIR/logger.sh"

# Check if port is already in use
check_port() {
    log_section "Checking port availability"

    if nc -z localhost "$COMFY_PORT" 2>/dev/null; then
        log_warn "Port $COMFY_PORT is in use. ComfyUI may already be running."
        display_options "1. Open browser to existing ComfyUI" "2. Try a different port" "3. Kill the process using port $COMFY_PORT"

        echo -n "Enter choice (1-3, default=1): "
        read -r choice
        
        case "$choice" in
            "3")
                free_port
                ;;
            "2")
                log_info "To use a different port, restart with --port option."
                exit 0
                ;;
            *)
                log_info "Opening browser to existing ComfyUI"
                open_browser "http://127.0.0.1:$COMFY_PORT"
                exit 0
                ;;
        esac
    else
        log_info "Port $COMFY_PORT is available"
    fi
}

# Free up the port by killing processes
free_port() {
    log_info "Attempting to free up port $COMFY_PORT"

    PIDS=$(lsof -t -i:"$COMFY_PORT" 2>/dev/null || netstat -anv | grep ".$COMFY_PORT " | awk '{print $9}' | sort -u)
    if [ -n "$PIDS" ]; then
        for PID in $PIDS; do
            log_info "Killing process $PID"
            kill -9 "$PID" 2>/dev/null
        done

        sleep 2
        if nc -z localhost "$COMFY_PORT" 2>/dev/null; then
            log_error "Failed to free up port $COMFY_PORT. Try a different port."
            exit 1
        else
            log_info "Successfully freed port $COMFY_PORT"
        fi
    else
        log_warn "Could not find any process using port $COMFY_PORT"
    fi
}

# Display final startup information
display_startup_info() {
    display_url_info
    display_notices
}

# Start ComfyUI with browser opening if requested
start_with_browser() {
    log_section "Starting ComfyUI with browser"

    # Set up a trap to kill the child process when this script receives a signal
    trap 'kill "$PID" 2>/dev/null' INT TERM

    # Start ComfyUI in the background using our persistent_main.py wrapper
    cd "$CODE_DIR" || exit 1
    log_info "Starting ComfyUI in background..."

    # Ensure library paths are preserved for the Python subprocess
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" "$COMFY_VENV/bin/python" "$CODE_DIR/persistent_main.py" --port "$COMFY_PORT" --force-fp16 "${ARGS[@]}" &
    else
        "$COMFY_VENV/bin/python" "$CODE_DIR/persistent_main.py" --port "$COMFY_PORT" --force-fp16 "${ARGS[@]}" &
    fi
    PID=$!

    # Wait for server to start
    log_info "Waiting for ComfyUI to start..."
    until nc -z localhost "$COMFY_PORT" 2>/dev/null; do
        sleep 1
        # Check if process is still running
        if ! kill -0 "$PID" 2>/dev/null; then
            log_error "ComfyUI process exited unexpectedly"
            exit 1
        fi
    done

    log_info "ComfyUI started! Opening browser..."
    open_browser "http://127.0.0.1:$COMFY_PORT"

    # Wait for the process to finish
    while kill -0 "$PID" 2>/dev/null; do
        wait "$PID" 2>/dev/null || break
    done

    # Make sure to clean up any remaining process
    kill "$PID" 2>/dev/null || true
    log_info "ComfyUI has shut down"
    exit 0
}

# Start ComfyUI normally without browser opening
start_normal() {
    log_section "Starting ComfyUI"

    cd "$CODE_DIR" || exit 1
    log_info "Starting ComfyUI... Press Ctrl+C to exit"

    # Ensure library paths are preserved for the Python subprocess
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}" exec "$COMFY_VENV/bin/python" "$CODE_DIR/persistent_main.py" --port "$COMFY_PORT" --force-fp16 "${ARGS[@]}"
    else
        exec "$COMFY_VENV/bin/python" "$CODE_DIR/persistent_main.py" --port "$COMFY_PORT" --force-fp16 "${ARGS[@]}"
    fi
}

# Start ComfyUI with appropriate mode
start_comfyui() {
    check_port
    display_startup_info
    
    if [ "$OPEN_BROWSER" = true ]; then
        start_with_browser
    else
        start_normal
    fi
}
