from pathlib import Path
from typing import Self

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


def _env_files() -> list[Path]:
    here = Path(__file__).resolve()
    try:
        root = here.parents[3]
        return [root / ".env", root / ".env.local"]
    except IndexError:
        return []


_INSECURE_DEFAULTS = {"change_me_in_dev", "change_me", "secret", ""}


class Settings(BaseSettings):
    environment: str = "development"
    core_url: str = "http://core.internal:4000"
    core_api_url: str = ""
    log_level: str = "info"
    hmac_secret: str = "change_me_in_dev"
    model_name: str = "Qwen/Qwen2.5-VL-7B-Instruct"
    request_timeout_seconds: int = 180
    max_image_size_bytes: int = 10_485_760  # 10 MB
    local_ocr_enabled: bool = True
    local_ocr_confidence_threshold: float = 0.9

    @property
    def effective_core_api_url(self) -> str:
        """Return VISION_CORE_API_URL if set, else fall back to VISION_CORE_URL."""
        return self.core_api_url if self.core_api_url else self.core_url

    model_config = SettingsConfigDict(
        env_prefix="VISION_",
        env_file=_env_files(),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    @model_validator(mode="after")
    def validate_secrets(self) -> Self:
        if self.environment == "test":
            return self
        if self.hmac_secret in _INSECURE_DEFAULTS:
            raise ValueError(
                "VISION_HMAC_SECRET is set to an insecure default value. "
                "Set it to a strong random secret before starting the service."
            )
        if self.environment == "production" and self.core_api_url in _INSECURE_DEFAULTS:
            raise ValueError(
                "VISION_CORE_API_URL must be set to the base URL of the Phoenix core "
                "service (no trailing slash). Example: https://thestacks.fly.dev"
            )
        return self


settings = Settings()
