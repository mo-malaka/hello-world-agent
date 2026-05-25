import os

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

SERVICE_NAME = os.environ.get("SERVICE_NAME", "hello-world-agent")
VERSION = os.environ.get("VERSION", "0.1.0")
CLOUD_PROVIDER = os.environ.get("CLOUD_PROVIDER", "local")

app = FastAPI(title=SERVICE_NAME, version=VERSION)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/", response_class=PlainTextResponse)
def hello():
    return "Hello, World!"


@app.get("/agent")
def agent_info():
    return {
        "service": SERVICE_NAME,
        "version": VERSION,
        "cloud_provider": CLOUD_PROVIDER,
    }
