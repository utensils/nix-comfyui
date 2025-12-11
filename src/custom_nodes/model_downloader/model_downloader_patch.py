"""Model downloader patch for ComfyUI."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from http import HTTPStatus
from typing import TYPE_CHECKING, Any, TypedDict

import folder_paths  # type: ignore[import-not-found]
from aiohttp import ClientSession, ClientTimeout, web
from server import PromptServer  # type: ignore[import-not-found]

if TYPE_CHECKING:
    from aiohttp import ClientResponse

# Setup logging
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("model_downloader")


class DownloadInfo(TypedDict):
    """Type definition for download information."""

    url: str
    folder: str
    filename: str
    path: str
    total_size: int
    downloaded: int
    percent: int
    status: str
    error: str | None
    start_time: float
    download_id: str


class DownloadInfoOptional(TypedDict, total=False):
    """Optional fields for download information."""

    end_time: float
    content_type: str
    speed: float
    eta: int


# Combined type for active downloads (all fields)
DownloadData = dict[str, Any]  # Using Any for flexibility with TypedDict limitations

# Store active downloads with their progress information
active_downloads: dict[str, DownloadData] = {}


async def download_model(request: web.Request) -> web.Response:
    """
    Handle POST requests to download models.

    This function returns IMMEDIATELY after starting a background download.

    Args:
        request: The aiohttp request object.

    Returns:
        JSON response with download status.
    """
    try:
        data = await _parse_request_data(request)

        url = data.get("url")
        folder = data.get("folder")
        filename = data.get("filename")

        logger.info("Received download request for %s in folder %s", filename, folder)

        if not url or not folder or not filename:
            logger.error(
                "Missing required parameters: url=%s, folder=%s, filename=%s",
                url,
                folder,
                filename,
            )
            return web.json_response({"success": False, "error": "Missing required parameters"})

        # Get the model folder path
        folder_path = folder_paths.get_folder_paths(folder)

        if not folder_path:
            logger.error("Invalid folder: %s", folder)
            return web.json_response({"success": False, "error": f"Invalid folder: {folder}"})

        # Create the full path for the file
        full_path = os.path.join(folder_path[0], filename)

        logger.info("Will download model to %s", full_path)

        # Generate a unique download ID
        download_id = f"{folder}_{filename}_{int(time.time())}"

        # Create a download entry
        active_downloads[download_id] = {
            "url": url,
            "folder": folder,
            "filename": filename,
            "path": full_path,
            "total_size": 0,
            "downloaded": 0,
            "percent": 0,
            "status": "downloading",
            "error": None,
            "start_time": time.time(),
            "download_id": download_id,
        }

        # Start the download as a separate task (don't await)
        PromptServer.instance.loop.create_task(_start_download(download_id, url, full_path))

        logger.info("Download %s queued, returning immediately to client", download_id)
        return web.json_response(
            {
                "success": True,
                "download_id": download_id,
                "status": "queued",
                "message": "Download has been queued and will start automatically",
            }
        )

    except json.JSONDecodeError:
        logger.exception("Invalid JSON in request")
        return web.json_response({"success": False, "error": "Invalid JSON"})
    except (KeyError, TypeError) as e:
        logger.exception("Error processing download request")
        return web.json_response({"success": False, "error": str(e)})


async def _parse_request_data(request: web.Request) -> dict[str, Any]:
    """Parse request data from various content types."""
    content_type = request.headers.get("Content-Type", "")
    data: dict[str, Any] = {}

    if "application/json" in content_type:
        data = await request.json()
    elif "application/x-www-form-urlencoded" in content_type:
        form_data = await request.post()
        data = dict(form_data)
    else:
        body = await request.text()
        logger.info("Request body: %s...", body[:200])

        if request.query:
            for key, value in request.query.items():
                data[key] = value

        if not data and body:
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                for param in body.split("&"):
                    if "=" in param:
                        key, value = param.split("=", 1)
                        data[key] = value

    logger.info("Request headers: %s", request.headers)
    logger.info("Parsed data: %s", data)

    return data


async def _start_download(download_id: str, url: str, full_path: str) -> None:
    """Start a download in the background."""
    try:
        await download_file(download_id, url, full_path)
    except (OSError, TimeoutError) as e:
        logger.exception("Error in start_download")
        if download_id in active_downloads:
            active_downloads[download_id]["status"] = "error"
            active_downloads[download_id]["error"] = str(e)
            await send_download_update(download_id)


async def download_file(download_id: str, url: str, full_path: str) -> None:
    """
    Background task to download a file and update progress.

    Uses aiohttp for non-blocking downloads that won't starve the event loop.

    Args:
        download_id: Unique identifier for this download.
        url: URL to download from.
        full_path: Local path to save the file.
    """
    try:
        logger.info("Starting download task for %s from %s to %s", download_id, url, full_path)

        # Prepare destination directory
        prepared_path = await _prepare_download_path(download_id, full_path)
        if prepared_path is None:
            return

        # Create ClientTimeout with reasonable values
        timeout = ClientTimeout(total=None, connect=30, sock_connect=30, sock_read=30)

        async with ClientSession(timeout=timeout) as session:
            # Get file size via HEAD request
            await _fetch_content_length(session, download_id, url)

            # Download the file
            await _download_with_progress(session, download_id, url, prepared_path)

        # Keep download info for 60 seconds for frontend visibility
        await asyncio.sleep(60)
        active_downloads.pop(download_id, None)

    except (OSError, TimeoutError):
        logger.exception("Error downloading file")
        if download_id in active_downloads:
            active_downloads[download_id]["status"] = "error"
            active_downloads[download_id]["error"] = "Download failed"
            active_downloads[download_id]["end_time"] = time.time()
            await send_download_update(download_id)


async def _prepare_download_path(download_id: str, full_path: str) -> str | None:
    """Prepare the download path, creating directories and handling conflicts."""
    try:
        target_directory = os.path.dirname(full_path)
        if not os.path.exists(target_directory):
            os.makedirs(target_directory, exist_ok=True)
            logger.info("Created directory: %s", target_directory)

        # Handle existing file conflicts
        if os.path.exists(full_path):
            logger.warning("File already exists at %s. Adding timestamp.", full_path)
            filename_parts = os.path.splitext(os.path.basename(full_path))
            timestamped_filename = f"{filename_parts[0]}_{int(time.time())}{filename_parts[1]}"
            full_path = os.path.join(target_directory, timestamped_filename)

            if download_id in active_downloads:
                active_downloads[download_id]["path"] = full_path
                active_downloads[download_id]["filename"] = timestamped_filename
                logger.info("Updated download path to: %s", full_path)
    except OSError as e:
        logger.exception("Error preparing download directory")
        if download_id in active_downloads:
            active_downloads[download_id]["status"] = "error"
            active_downloads[download_id]["error"] = f"Failed to create directory: {e}"
            await send_download_update(download_id)
        return None
    else:
        return full_path


async def _fetch_content_length(
    session: ClientSession, download_id: str, url: str
) -> None:
    """Fetch content length via HEAD request."""
    try:
        async with session.head(url, allow_redirects=True) as head_response:
            if head_response.status == HTTPStatus.OK:
                content_length = head_response.headers.get("content-length")
                if content_length:
                    total_size = int(content_length)
                    content_type = head_response.headers.get("content-type", "")
                    size_mb = total_size / (1024 * 1024)
                    logger.info("File size from HEAD: %d bytes (%.2f MB)", total_size, size_mb)

                    if download_id in active_downloads:
                        active_downloads[download_id]["total_size"] = total_size
                        active_downloads[download_id]["content_type"] = content_type
            else:
                logger.warning("HEAD request returned status %d", head_response.status)
    except (OSError, TimeoutError) as e:
        logger.warning("HEAD request failed: %s", e)


async def _download_with_progress(
    session: ClientSession, download_id: str, url: str, full_path: str
) -> None:
    """Download file with progress tracking."""
    async with session.get(url, allow_redirects=True) as response:
        if response.status != HTTPStatus.OK:
            raise OSError(f"HTTP error {response.status}: {response.reason}")

        # Get or update file size
        total_size = _get_or_update_total_size(download_id, response)

        logger.info("Starting download of %.2f MB file", total_size / (1024 * 1024))

        downloaded = 0
        update_interval = 1.0
        last_update_time = 0.0
        percent_logged = -1
        filename = os.path.basename(full_path)
        start_time = time.time()

        logger.info("[%s] Beginning data transfer for %s", download_id, filename)

        with open(full_path, "wb") as f:
            async for chunk in response.content.iter_chunked(1024 * 1024):
                if not chunk:
                    break

                f.write(chunk)
                downloaded += len(chunk)

                _update_download_progress(
                    download_id, downloaded, total_size, start_time
                )

                # Log at 10% increments
                if download_id in active_downloads:
                    current_percent = active_downloads[download_id].get("percent", 0)
                    if (
                        current_percent > 0
                        and current_percent % 10 == 0
                        and current_percent != percent_logged
                    ):
                        percent_logged = current_percent
                        _log_progress(download_id, downloaded, total_size)

                    # Throttled WebSocket updates
                    current_time = time.time()
                    if current_time - last_update_time >= update_interval:
                        last_update_time = current_time
                        await send_download_update(download_id)

        # Mark download as completed
        _finalize_download(download_id, downloaded, total_size, full_path)
        await send_download_update(download_id)


def _get_or_update_total_size(download_id: str, response: ClientResponse) -> int:
    """Get total size from download info or response headers."""
    total_size = 0
    if download_id in active_downloads:
        total_size = active_downloads[download_id].get("total_size", 0)

    if total_size == 0:
        content_length = response.headers.get("content-length")
        if content_length:
            total_size = int(content_length)
            if download_id in active_downloads:
                active_downloads[download_id]["total_size"] = total_size
                active_downloads[download_id]["content_type"] = response.headers.get(
                    "content-type", ""
                )

    return total_size


def _update_download_progress(
    download_id: str, downloaded: int, total_size: int, start_time: float
) -> None:
    """Update download progress information."""
    if download_id not in active_downloads:
        return

    active_downloads[download_id]["downloaded"] = downloaded

    if total_size > 0:
        current_percent = int((downloaded / total_size) * 100)
        active_downloads[download_id]["percent"] = current_percent

    time_elapsed = time.time() - start_time
    if downloaded > 0 and time_elapsed > 0:
        speed_mbps = downloaded / (1024 * 1024) / time_elapsed
        active_downloads[download_id]["speed"] = round(speed_mbps, 2)

        if total_size > 0 and speed_mbps > 0:
            bytes_remaining = total_size - downloaded
            seconds_remaining = bytes_remaining / (speed_mbps * 1024 * 1024)
            active_downloads[download_id]["eta"] = int(seconds_remaining)


def _log_progress(download_id: str, downloaded: int, total_size: int) -> None:
    """Log download progress at intervals."""
    if download_id not in active_downloads:
        return

    speed = active_downloads[download_id].get("speed", 0)
    eta = active_downloads[download_id].get("eta", 0)
    percent = active_downloads[download_id].get("percent", 0)
    eta_str = f", ETA: {eta // 60}m {eta % 60}s" if eta else ""
    dl_mb = downloaded / (1024 * 1024)
    total_mb = total_size / (1024 * 1024)

    logger.info(
        "[%s] Download progress: %d%% (%.2f MB of %.2f MB, %s MB/s%s)",
        download_id,
        percent,
        dl_mb,
        total_mb,
        speed,
        eta_str,
    )


def _finalize_download(
    download_id: str, downloaded: int, total_size: int, full_path: str
) -> None:
    """Finalize download and log completion."""
    if download_id not in active_downloads:
        return

    elapsed_time = time.time() - active_downloads[download_id].get("start_time", time.time())
    download_speed = (downloaded / elapsed_time) / (1024 * 1024) if elapsed_time > 0 else 0

    dl_size_mb = downloaded / (1024 * 1024)
    logger.info(
        "[%s] Download completed: %.2f MB in %.1f seconds (%.2f MB/s)",
        download_id,
        dl_size_mb,
        elapsed_time,
        download_speed,
    )

    active_downloads[download_id]["status"] = "completed"
    active_downloads[download_id]["end_time"] = time.time()
    active_downloads[download_id]["downloaded"] = downloaded
    active_downloads[download_id]["percent"] = 100 if total_size > 0 else 0

    logger.info("[%s] Model downloaded successfully to %s", download_id, full_path)


async def send_download_update(download_id: str) -> None:
    """Send a WebSocket update to all clients about download status."""
    if download_id not in active_downloads:
        return

    download = active_downloads[download_id]

    if download["status"] == "completed":
        logger.info("Download complete: %s", download.get("filename", ""))
    elif download["status"] == "error":
        logger.info("Download error: %s", download.get("error", ""))

    try:
        PromptServer.instance.send_sync(
            "model_download_progress",
            {
                "download_id": download_id,
                "status": download["status"],
                "percent": download.get("percent", 0),
                "downloaded": download.get("downloaded", 0),
                "total_size": download.get("total_size", 0),
                "speed": download.get("speed", 0),
                "eta": download.get("eta", 0),
                "error": download.get("error"),
            },
        )
    except (OSError, RuntimeError):
        logger.exception("WebSocket error")


async def get_download_progress(request: web.Request) -> web.Response:
    """Get the progress of a download."""
    try:
        download_id = request.match_info.get("download_id")

        if download_id and download_id in active_downloads:
            return web.json_response({"success": True, "download": active_downloads[download_id]})
        return web.json_response({"success": False, "error": "Download not found"})
    except (KeyError, TypeError) as e:
        return web.json_response({"success": False, "error": str(e)})


async def list_downloads(request: web.Request) -> web.Response:
    """List all active downloads."""
    try:
        return web.json_response({"success": True, "downloads": active_downloads})
    except (TypeError, ValueError) as e:
        return web.json_response({"success": False, "error": str(e)})


def setup_js_api(app: Any, *args: Any, **kwargs: Any) -> Any:
    """
    Compatibility function for ComfyUI extension system.

    API endpoints are now registered in the __init__.py file to avoid duplicates.

    Args:
        app: The aiohttp application.
        *args: Additional positional arguments (unused).
        **kwargs: Additional keyword arguments (unused).

    Returns:
        The modified app.
    """
    logger.info("Model downloader API endpoints are now registered in __init__.py")
    return app
