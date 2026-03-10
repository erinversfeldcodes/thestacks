from pydantic import BaseModel, Field


class ExtractionRequest(BaseModel):
    images: list[str] = Field(..., min_length=1, max_length=3, description="Base64-encoded images")


class ExtractedBook(BaseModel):
    title: str | None = None
    author: str | None = None
    potential_isbns: list[str] = Field(default_factory=list)
    raw_text: str | None = None
    confidence: float = Field(ge=0.0, le=1.0, default=0.0)


class ExtractionResponse(BaseModel):
    books: list[ExtractedBook]
    model_used: str
