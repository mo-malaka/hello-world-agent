import os

from fastapi import FastAPI
from fastapi import HTTPException
from pydantic import BaseModel, Field
from fastapi.responses import PlainTextResponse

from app.agent import AgentConfigError, invoke_agent

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


class InvokeRequest(BaseModel):
    input: str
    max_steps: int = 3


class InvokeResponse(BaseModel):
    output: str
    tool_results: list[dict] = Field(default_factory=list)


@app.post("/agent/invoke", response_model=InvokeResponse)
def agent_invoke(req: InvokeRequest) -> InvokeResponse:
    try:
        result = invoke_agent(req.input, req.max_steps)
        return InvokeResponse(**result)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except AgentConfigError as exc:
        raise HTTPException(status_code=500, detail=str(exc))
