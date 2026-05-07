#!/usr/bin/env python3
"""
FastAPI Web UI for AI Studio Film Workflow
"""
import sys
import os

# Add ui/ dir to path so routers can be imported
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from jinja2 import Environment, FileSystemLoader

# Paths
UI_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(UI_DIR, "static")
TEMPLATES_DIR = os.path.join(UI_DIR, "templates")

# Ensure dirs exist
os.makedirs(STATIC_DIR, exist_ok=True)
os.makedirs(TEMPLATES_DIR, exist_ok=True)

# Jinja2 directly (avoids starlette/starlette templating version conflict)
_jinja_env = Environment(loader=FileSystemLoader(TEMPLATES_DIR), autoescape=True)

# Setup
app = FastAPI(title="AI Studio Film UI")
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

# Routes
@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """Dashboard als Startseite."""
    template = _jinja_env.get_template("dashboard.html")
    return HTMLResponse(template.render(request=request))

@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard_page(request: Request):
    """Dashboard Seite."""
    template = _jinja_env.get_template("dashboard.html")
    return HTMLResponse(template.render(request=request))

@app.get("/images", response_class=HTMLResponse)
async def images_page(request: Request):
    template = _jinja_env.get_template("images.html")
    return HTMLResponse(template.render(request=request))

@app.get("/training", response_class=HTMLResponse)
async def training_page(request: Request):
    template = _jinja_env.get_template("training.html")
    return HTMLResponse(template.render(request=request))

@app.get("/stacks", response_class=HTMLResponse)
async def stacks_page(request: Request):
    template = _jinja_env.get_template("stacks.html")
    return HTMLResponse(template.render(request=request))

@app.get("/film", response_class=HTMLResponse)
async def film_page(request: Request):
    template = _jinja_env.get_template("film.html")
    return HTMLResponse(template.render(request=request))

@app.get("/text", response_class=HTMLResponse)
async def text_page(request: Request):
    template = _jinja_env.get_template("text.html")
    return HTMLResponse(template.render(request=request))

# Import and register routers
from routers import workflow, streams, images, training, stacks, local_ai, stack_config

app.include_router(workflow.router, prefix="/api/workflow", tags=["workflow"])
app.include_router(streams.router, prefix="/api/stream", tags=["stream"])
app.include_router(images.router, prefix="/api/images", tags=["images"])
app.include_router(training.router, prefix="/api/training", tags=["training"])
app.include_router(stacks.router, prefix="/api/stacks", tags=["stacks"])
app.include_router(local_ai.router, prefix="/api/local/ai", tags=["local_ai"])
app.include_router(stack_config.router, prefix="/api/stack-config", tags=["stack_config"])

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8000)
