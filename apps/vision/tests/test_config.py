"""Tests for Settings validation in config.py."""

import pytest
from pydantic import ValidationError

from app.config import Settings


def _production_base() -> dict:
    """Minimum valid production settings."""
    return {
        "environment": "production",
        "hmac_secret": "a-strong-secret-value",
        "core_api_url": "https://thestacks.fly.dev",
    }


def test_valid_production_settings_pass() -> None:
    s = Settings.model_validate(_production_base())
    assert s.environment == "production"
    assert s.core_api_url == "https://thestacks.fly.dev"


def test_missing_core_api_url_raises_in_production() -> None:
    cfg = {**_production_base(), "core_api_url": ""}
    with pytest.raises(ValidationError, match="VISION_CORE_API_URL must be set"):
        Settings.model_validate(cfg)


def test_insecure_hmac_raises_in_production() -> None:
    cfg = {**_production_base(), "hmac_secret": "change_me"}
    with pytest.raises(ValidationError, match="VISION_HMAC_SECRET"):
        Settings.model_validate(cfg)


def test_test_environment_skips_validation() -> None:
    """In test mode all secret checks are bypassed."""
    s = Settings.model_validate({"environment": "test", "core_api_url": "", "hmac_secret": ""})
    assert s.environment == "test"


def test_effective_core_api_url_falls_back_to_core_url_in_dev() -> None:
    """In non-production environments the fallback property still works."""
    s = Settings.model_validate(
        {"environment": "development", "core_url": "http://core.internal:4000", "core_api_url": ""}
    )
    assert s.effective_core_api_url == "http://core.internal:4000"


def test_effective_core_api_url_uses_explicit_value_when_set() -> None:
    s = Settings.model_validate(
        {
            **_production_base(),
            "core_url": "http://fallback",
            "core_api_url": "https://explicit.fly.dev",
        }
    )
    assert s.effective_core_api_url == "https://explicit.fly.dev"
