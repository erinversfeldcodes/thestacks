from pydantic import model_validator
from pydantic_settings import BaseSettings
from typing import Self

_INSECURE_DEFAULTS = {"change_me_in_dev", "change_me", "secret", ""}


class Settings(BaseSettings):
    environment: str = "development"
    core_url: str = "http://core.internal:4000"
    log_level: str = "info"
    hmac_secret: str = "change_me_in_dev"
    together_api_key: str = ""
    model_name: str = "Qwen/Qwen2.5-VL-7B-Instruct"
    model_provider: str = "together"
    request_timeout_seconds: int = 30
    max_image_size_bytes: int = 10_485_760  # 10 MB

    model_config = {"env_prefix": "VISION_"}

    @model_validator(mode="after")
    def hmac_secret_must_not_be_default(self) -> Self:
        if self.environment != "test" and self.hmac_secret in _INSECURE_DEFAULTS:
            raise ValueError(
                "VISION_HMAC_SECRET is set to an insecure default value. "
                "Set it to a strong random secret before starting the service."
            )
        return self


settings = Settings()
