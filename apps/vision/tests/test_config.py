"""Tests for Settings validation in config.py.

⚠️ Three tests were removed on 2026-10-15 along with the settings they covered.
`core_url`, `core_api_url` and the `effective_core_api_url` property existed so
the sidecar could call Phoenix back after an asynchronous cover association;
that endpoint and its callback are gone, and nothing else in the service ever
dialled core. The production validator branch requiring `VISION_CORE_API_URL`
went with them — a required setting for a call that no longer happens is a
deploy that fails for no reason.

What remains is the HMAC secret check, which is the one that matters: it is the
only thing standing between a production boot and an unauthenticated sidecar.
"""

import pytest
from pydantic import ValidationError

from app.config import Settings


def _production_base() -> dict[str, str]:
    """Minimum valid production settings."""
    return {
        "environment": "production",
        "hmac_secret": "a-strong-secret-value",
    }


def test_valid_production_settings_pass() -> None:
    s = Settings.model_validate(_production_base())
    assert s.environment == "production"
    assert s.hmac_secret == "a-strong-secret-value"


def test_insecure_hmac_raises_in_production() -> None:
    cfg = {**_production_base(), "hmac_secret": "change_me"}
    with pytest.raises(ValidationError, match="VISION_HMAC_SECRET"):
        Settings.model_validate(cfg)


def test_empty_hmac_raises_in_production() -> None:
    """An unset secret is an insecure default, not a special case.

    Worth its own test because "" reaches the check by a different route from
    "change_me": one is a forgotten environment variable, the other a copied
    example file, and both must fail the same way.
    """
    cfg = {**_production_base(), "hmac_secret": ""}
    with pytest.raises(ValidationError, match="VISION_HMAC_SECRET"):
        Settings.model_validate(cfg)


def test_test_environment_skips_validation() -> None:
    """In test mode all secret checks are bypassed."""
    s = Settings.model_validate({"environment": "test", "hmac_secret": ""})
    assert s.environment == "test"


def test_development_environment_still_enforces_the_hmac_secret() -> None:
    """Only `test` is exempt — development is not.

    The validator returns early for `environment == "test"` and for nothing
    else, so a developer running with the example secret gets the same refusal
    production does. Pinned because the early return is one line and an extra
    environment name added to it would silently widen the exemption.
    """
    cfg = {"environment": "development", "hmac_secret": "change_me_in_dev"}
    with pytest.raises(ValidationError, match="VISION_HMAC_SECRET"):
        Settings.model_validate(cfg)
