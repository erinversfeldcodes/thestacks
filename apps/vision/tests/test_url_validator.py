"""Tests for SSRF protection in URL validation."""

import socket
from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException

from app.services.url_validator import validate_image_url


class TestValidateImageUrl:
    """Test URL validation blocks SSRF vectors and allows safe URLs."""

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_https_url_passes(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET, None, None, None, ("93.184.216.34", 0))]
        await validate_image_url("https://example.com/image.jpg")

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_http_url_passes(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET, None, None, None, ("93.184.216.34", 0))]
        await validate_image_url("http://example.com/image.jpg")

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_r2_presigned_url_passes(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET, None, None, None, ("104.18.10.1", 0))]
        url = "https://52c8577081eb22019d5a36e0a0219fc3.r2.cloudflarestorage.com/uploads/abc"
        await validate_image_url(url)

    async def test_file_scheme_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("file:///etc/passwd")
        assert exc_info.value.status_code == 422
        assert "scheme" in exc_info.value.detail

    async def test_ftp_scheme_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("ftp://example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "scheme" in exc_info.value.detail

    async def test_aws_metadata_ip_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://169.254.169.254/latest/meta-data/")
        assert exc_info.value.status_code == 422
        assert "blocked" in exc_info.value.detail

    async def test_localhost_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://localhost/secret")
        assert exc_info.value.status_code == 422
        assert "blocked" in exc_info.value.detail

    async def test_fly_internal_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://core.internal:4000/api/auth/me")
        assert exc_info.value.status_code == 422
        assert "blocked" in exc_info.value.detail

    async def test_dot_local_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://anything.local/secret")
        assert exc_info.value.status_code == 422
        assert "blocked" in exc_info.value.detail

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_private_ip_10_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET, None, None, None, ("10.0.0.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_loopback_ip_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET, None, None, None, ("127.0.0.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_link_local_ip_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET, None, None, None, ("169.254.1.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_private_ip_172_16_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET, None, None, None, ("172.16.0.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_private_ip_192_168_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET, None, None, None, ("192.168.1.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_ipv6_loopback_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET6, None, None, None, ("::1", 0, 0, 0))]
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_ipv4_mapped_ipv6_private_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(socket.AF_INET6, None, None, None, ("::ffff:10.0.0.1", 0, 0, 0))]
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    async def test_public_ipv6_literal_passes(self) -> None:
        """A public IPv6 address literal bypasses DNS and is allowed."""
        await validate_image_url("http://[2606:2800:220:1:248:1893:25c8:1946]/image.jpg")

    @patch("app.services.url_validator.socket.getaddrinfo")
    async def test_carrier_grade_nat_blocked(self, mock_dns: MagicMock) -> None:
        """RFC 6598 CGN (100.64.0.0/10) must be blocked — used internally on Fly.io."""
        mock_dns.return_value = [(socket.AF_INET, None, None, None, ("100.64.0.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    async def test_carrier_grade_nat_ip_literal_blocked(self) -> None:
        """RFC 6598 CGN as an IP literal is blocked by the fast-path."""
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://100.64.0.1/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch(
        "app.services.url_validator.socket.getaddrinfo",
        side_effect=__import__("socket").gaierror("Name resolution failed"),
    )
    async def test_unresolvable_hostname_blocked(self, mock_dns: MagicMock) -> None:
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http://nonexistent.example.invalid/image.jpg")
        assert exc_info.value.status_code == 422
        assert "resolved" in exc_info.value.detail

    async def test_no_hostname_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            await validate_image_url("http:///path/only")
        assert exc_info.value.status_code == 422
        assert "no hostname" in exc_info.value.detail.lower()
