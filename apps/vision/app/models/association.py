from pydantic import BaseModel, Field, HttpUrl


class AssociateRequest(BaseModel):
    isbn: str = Field(..., description="ISBN-10 or ISBN-13 (digits only, hyphens stripped)")
    book_id: str = Field(..., description="UUID of the work record in the core DB")
    edition_id: str = Field(..., description="UUID of the edition record (idempotency key)")
    cover_image_url: HttpUrl = Field(..., description="URL of the cover image to download")


class AssociateResponse(BaseModel):
    job_id: str = Field(..., description="Unique identifier for this async job")
