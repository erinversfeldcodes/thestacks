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
    log_level: str = "info"
    hmac_secret: str = "change_me_in_dev"
    # ⚠️ A REPORTING value, and it must track modal_app.py's MODEL_NAME default
    # — two defaults, one truth. They diverged once (front door reporting the
    # 7B while the T4 ran the 4B) and the first `--record` after the swap
    # stamped the new baseline with the OLD model's name. The single-dispatch
    # path now prefers the GPU container's own claim from the response; this
    # default is the fallback for the paths that never reach a GPU.
    model_name: str = "Qwen/Qwen3-VL-4B-Instruct"
    request_timeout_seconds: int = 180
    max_image_size_bytes: int = 10_485_760  # 10 MB
    local_ocr_enabled: bool = True

    # Read cover text on CPU. Independent of `ocr_short_circuit` on purpose:
    # the pass is worth running for measurement long before it is trusted to
    # answer, and one flag for both would make "measure it" and "ship it" the
    # same decision.
    cover_text_enabled: bool = True

    # Let a confident cover-text read ANSWER, skipping the VLM entirely.
    # ⛔ Off by default. Promotion is a measured decision, not a deployment
    # detail — the eval has to show the hit rate and the false-accept rate
    # before this becomes True anywhere.
    ocr_short_circuit: bool = False

    # ⬛ R0: run classify + extract as ONE Modal dispatch on one container
    # instead of two separate .remote() calls. ON by default since 2026-11-17,
    # validated on T4+4B: accuracy IDENTICAL (84/122, every stratum matches the
    # two-call path) and cold p95 ~13% lower under concurrency (25.6s vs 29.3s),
    # a rarer over-cap two-cold-start tail removed outright. The two-call path
    # stays behind the flag as a fallback; set VISION_SINGLE_DISPATCH=0 to use it.
    single_dispatch: bool = True

    # Minimum mean word confidence for a read to be allowed to answer, when
    # short-circuiting is on at all. Deliberately high: a wrong identification
    # costs more than a fall-through to the VLM, which is merely expensive.
    ocr_short_circuit_min_confidence: float = 0.80

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
        return self


settings = Settings()
