from enum import Enum

from pydantic import BaseModel, Field


class Classification(str, Enum):
    book = "book"
    not_book = "not_book"
    ambiguous = "ambiguous"


class ClassificationRequest(BaseModel):
    image: str = Field(..., description="Base64-encoded image")


class ClassificationResponse(BaseModel):
    classification: Classification
    confidence: float = Field(ge=0.0, le=1.0)
    model_used: str
