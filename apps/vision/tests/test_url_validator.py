"""Tests for SSRF protection in URL validation."""

from unittest.mock import MagicMock, patch

import pytest
from fastapi import HTTPException

from app.services.url_validator import validate_image_url


class TestValidateImageUrl:
    """Test URL validation blocks SSRF vectors and allows safe URLs."""

    # --- Allowed URLs ---

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_https_url_passes(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("93.184.216.34", 0))]
        validate_image_url("https://example.com/image.jpg")

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_http_url_passes(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("93.184.216.34", 0))]
        validate_image_url("http://example.com/image.jpg")

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_r2_presigned_url_passes(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("104.18.10.1", 0))]
        url = "https://52c8577081eb22019d5a36e0a0219fc3.r2.cloudflarestorage.com/uploads/abc"
        validate_image_url(url)

    # --- Blocked schemes ---

    def test_file_scheme_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("file:///etc/passwd")
        assert exc_info.value.status_code == 422
        assert "scheme" in exc_info.value.detail

    def test_ftp_scheme_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("ftp://example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "scheme" in exc_info.value.detail

    # --- Blocked hostnames ---

    def test_aws_metadata_ip_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://169.254.169.254/latest/meta-data/")
        assert exc_info.value.status_code == 422
        assert "blocked" in exc_info.value.detail

    def test_localhost_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://localhost/secret")
        assert exc_info.value.status_code == 422
        assert "blocked" in exc_info.value.detail

    def test_fly_internal_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://core.internal:4000/api/auth/me")
        assert exc_info.value.status_code == 422
        assert "blocked" in exc_info.value.detail

    def test_dot_local_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://anything.local/secret")
        assert exc_info.value.status_code == 422
        assert "blocked" in exc_info.value.detail

    # --- Private/reserved IPs ---

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_private_ip_10_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("10.0.0.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_loopback_ip_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("127.0.0.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_link_local_ip_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("169.254.1.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_private_ip_172_16_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("172.16.0.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_private_ip_192_168_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("192.168.1.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_ipv6_loopback_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("::1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    @patch("app.services.url_validator.socket.getaddrinfo")
    def test_ipv4_mapped_ipv6_private_blocked(self, mock_dns: MagicMock) -> None:
        mock_dns.return_value = [(None, None, None, None, ("::ffff:10.0.0.1", 0))]
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://sneaky.example.com/image.jpg")
        assert exc_info.value.status_code == 422
        assert "private" in exc_info.value.detail.lower()

    # --- DNS resolution failure ---

    @patch(
        "app.services.url_validator.socket.getaddrinfo",
        side_effect=__import__("socket").gaierror("Name resolution failed"),
    )
    def test_unresolvable_hostname_blocked(self, mock_dns: MagicMock) -> None:
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http://nonexistent.example.invalid/image.jpg")
        assert exc_info.value.status_code == 422
        assert "resolved" in exc_info.value.detail

    # --- No hostname ---

    def test_no_hostname_blocked(self) -> None:
        with pytest.raises(HTTPException) as exc_info:
            validate_image_url("http:///path/only")
        assert exc_info.value.status_code == 422
        assert "no hostname" in exc_info.value.detail.lower()
