from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    environment: str = "development"
    core_url: str = "http://core.internal:4000"
    log_level: str = "info"

    model_config = {"env_prefix": "VISION_"}


settings = Settings()
