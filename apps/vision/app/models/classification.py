from enum import Enum
from typing import Self

from pydantic import BaseModel, Field, HttpUrl, model_validator


class Classification(str, Enum):
    book = "book"
    not_book = "not_book"
    ambiguous = "ambiguous"


class ClassificationRequest(BaseModel):
    image: str | None = Field(
        default=None,
        description="Base64-encoded image (mutually exclusive with image_url)",
    )
    image_url: HttpUrl | None = Field(
        default=None,
        description=(
            "URL of a remote image to download and classify (mutually exclusive with image)"
        ),
    )

    @model_validator(mode="after")
    def validate_input_source(self) -> Self:
        has_image = self.image is not None
        has_url = self.image_url is not None
        if has_image and has_url:
            raise ValueError("Provide either 'image' or 'image_url', not both")
        if not has_image and not has_url:
            raise ValueError("Either 'image' or 'image_url' must be provided")
        return self


class ClassificationResponse(BaseModel):
    classification: Classification
    confidence: float = Field(ge=0.0, le=1.0)
    model_used: str
