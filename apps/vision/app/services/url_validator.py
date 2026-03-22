import ipaddress
import socket
from urllib.parse import urlparse

from fastapi import HTTPException

# Block private/reserved IP ranges and internal hostnames
_BLOCKED_HOSTS = {
    "localhost",
    "0.0.0.0",
    "metadata.google.internal",
    "169.254.169.254",
}

_BLOCKED_SUFFIXES = [
    ".internal",
    ".local",
    ".localhost",
]


def validate_image_url(url: str) -> None:
    """Validate that an image URL is safe to fetch (no SSRF).

    Raises HTTPException(422) if the URL is unsafe.
    """
    parsed = urlparse(url)

    # Must be HTTP or HTTPS
    if parsed.scheme not in ("http", "https"):
        raise HTTPException(
            status_code=422,
            detail=f"URL scheme must be http or https, got: {parsed.scheme}",
        )

    hostname = parsed.hostname
    if not hostname:
        raise HTTPException(status_code=422, detail="URL has no hostname")

    # Block known dangerous hostnames
    hostname_lower = hostname.lower()
    if hostname_lower in _BLOCKED_HOSTS:
        raise HTTPException(status_code=422, detail="URL hostname is blocked")

    for suffix in _BLOCKED_SUFFIXES:
        if hostname_lower.endswith(suffix):
            raise HTTPException(status_code=422, detail="URL hostname is blocked")

    # Resolve hostname and check for private IPs
    try:
        resolved = socket.getaddrinfo(hostname, None)
        for _, _, _, _, addr in resolved:
            ip = ipaddress.ip_address(addr[0])
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
                raise HTTPException(
                    status_code=422,
                    detail="URL resolves to a private/reserved IP address",
                )
    except socket.gaierror as exc:
        raise HTTPException(status_code=422, detail="URL hostname could not be resolved") from exc
