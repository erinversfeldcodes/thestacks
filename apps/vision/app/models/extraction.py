from typing import Self

from pydantic import BaseModel, Field, HttpUrl, model_validator


class ExtractionRequest(BaseModel):
    images: list[str] | None = Field(
        default=None,
        min_length=1,
        max_length=3,
        description="Base64-encoded images (mutually exclusive with image_url)",
    )
    image_url: HttpUrl | None = Field(
        default=None,
        description=(
            "URL of a remote image to download and extract (mutually exclusive with images)"
        ),
    )

    @model_validator(mode="after")
    def validate_input_source(self) -> Self:
        has_images = self.images is not None
        has_url = self.image_url is not None
        if has_images and has_url:
            raise ValueError("Provide either 'images' or 'image_url', not both")
        if not has_images and not has_url:
            raise ValueError("Either 'images' or 'image_url' must be provided")
        return self


class ExtractedBook(BaseModel):
    title: str | None = None
    author: str | None = None
    potential_isbns: list[str] = Field(default_factory=list)
    raw_text: str | None = None
    confidence: float = Field(ge=0.0, le=1.0, default=0.0)


class ExtractionResponse(BaseModel):
    books: list[ExtractedBook]
    model_used: str
