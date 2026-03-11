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
    log_level: str = "info"
    hmac_secret: str = "change_me_in_dev"
    together_api_key: str = ""
    model_name: str = "Qwen/Qwen3-VL-8B-Instruct"
    model_provider: str = "together"  # Reserved for future multi-provider support (e.g. Replicate)
    request_timeout_seconds: int = 30
    max_image_size_bytes: int = 10_485_760  # 10 MB

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
        if not self.together_api_key:
            raise ValueError(
                "VISION_TOGETHER_API_KEY is not set. "
                "Provide a valid Together AI API key before starting the service."
            )
        return self


settings = Settings()
