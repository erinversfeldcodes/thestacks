import asyncio
import ipaddress
import socket
from urllib.parse import urlparse

from fastapi import HTTPException

_BLOCKED_HOSTS = {
    "localhost",
    "0.0.0.0",  # kept for defence-in-depth before IP fast-path; harmless if redundant
    "metadata.google.internal",
    "169.254.169.254",
}

_BLOCKED_SUFFIXES = [
    ".internal",
    ".local",
    ".localhost",
]


def _is_globally_routable(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    """Return True only if `ip` is a globally routable public address.

    Blocks private, loopback, link-local, reserved, and carrier-grade NAT
    (RFC 6598 100.64.0.0/10) ranges. `is_global` in Python's ipaddress module
    returns False for all of these, so a single negated check is sufficient.
    The CGN range is the key addition over the individual `is_private` /
    `is_reserved` checks: 100.64.x.x is used internally on Fly.io and is not
    caught by `is_private` or `is_reserved` alone.
    """
    return ip.is_global


async def validate_image_url(url: str) -> None:
    """Validate that an image URL is safe to fetch (no SSRF).

    Raises HTTPException(422) if the URL is unsafe.
    """
    parsed = urlparse(url)

    if parsed.scheme not in ("http", "https"):
        raise HTTPException(
            status_code=422,
            detail=f"URL scheme must be http or https, got: {parsed.scheme}",
        )

    hostname = parsed.hostname
    if not hostname:
        raise HTTPException(status_code=422, detail="URL has no hostname")

    hostname_lower = hostname.lower()
    if hostname_lower in _BLOCKED_HOSTS:
        raise HTTPException(status_code=422, detail="URL hostname is blocked")

    for suffix in _BLOCKED_SUFFIXES:
        if hostname_lower.endswith(suffix):
            raise HTTPException(status_code=422, detail="URL hostname is blocked")

    try:
        ip_literal = ipaddress.ip_address(hostname_lower)
        if not _is_globally_routable(ip_literal):
            raise HTTPException(
                status_code=422, detail="URL resolves to a private/reserved IP address"
            )
        return
    except ValueError:
        pass  # Not an IP literal; proceed to DNS resolution below.

    loop = asyncio.get_running_loop()
    try:
        resolved = await loop.run_in_executor(None, socket.getaddrinfo, hostname_lower, None)
        validated_count = 0
        for af, _, _, _, addr in resolved:
            if af not in (socket.AF_INET, socket.AF_INET6):
                continue
            ip = ipaddress.ip_address(addr[0])
            if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
                ip = ip.ipv4_mapped
            if not _is_globally_routable(ip):
                raise HTTPException(
                    status_code=422,
                    detail="URL resolves to a private/reserved IP address",
                )
            validated_count += 1
        if validated_count == 0:
            raise HTTPException(status_code=422, detail="URL hostname could not be resolved")
    except socket.gaierror as exc:
        raise HTTPException(status_code=422, detail="URL hostname could not be resolved") from exc
    # NOTE: TOCTOU risk — httpx will re-resolve the hostname on connect. A DNS rebinding
    # attack can return a different IP at fetch time. Mitigating this fully requires a
    # custom httpx transport that reuses the pre-validated resolution; deferred to a
    # follow-up issue. The current check eliminates the most common SSRF vectors.
