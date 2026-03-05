from fastapi import FastAPI

from app.config import settings

app = FastAPI(title="The Stacks Vision Sidecar", version="0.1.0")


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "service": "vision", "environment": settings.environment}
