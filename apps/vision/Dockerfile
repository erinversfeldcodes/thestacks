FROM python:3.15-slim@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928 AS builder
WORKDIR /app
# Install from the fully-resolved, hash-pinned lock (requirements.txt is the
# human-edited source Dependabot watches; regenerate with `just lock-vision`).
COPY requirements.lock .
RUN pip install --no-cache-dir --user --require-hashes -r requirements.lock

FROM python:3.15-slim@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928 AS runtime
RUN useradd -m -u 1000 appuser
WORKDIR /app
COPY --from=builder /root/.local /home/appuser/.local
COPY app/ ./app/
RUN chown -R appuser /app /home/appuser/.local
ENV PATH=/home/appuser/.local/bin:$PATH
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
