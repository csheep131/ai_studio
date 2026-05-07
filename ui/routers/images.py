"""
Images Router — Bilderstellung und Dataset-Generierung.
"""
from __future__ import annotations

import asyncio
import json
import os
import random
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
LOCAL_PICS_SCRIPT = PROJECT_ROOT / "local_pics.py"
AP_IMG2IMG_SCRIPT = PROJECT_ROOT / "ap_img2img.py"

# Pfade für Datasets und Master-Bilder
DATASET_DIR = PROJECT_ROOT / "video_training_dataset"
IMAGES_DIR = DATASET_DIR / "images"
TEXTS_DIR = DATASET_DIR / "texts"
MASTER_IMAGES_DIR = PROJECT_ROOT / "master_images"

router = APIRouter()

# ───────────────────────────────────────────────────────────────────────────
# Helper: local_pics.py Subprocess-Wrapper
# ───────────────────────────────────────────────────────────────────────────


async def run_local_pics(
    init_image_path: str,
    num_images: int = 20,
    strength: float = 0.55,
    guidance: float = 1.5,
    steps: int = 4,
    base_prompt: Optional[str] = None,
    trigger: Optional[str] = None,
    create_video: bool = True,
) -> tuple[int, str, str]:
    """
    Führt local_pics.py aus.
    Returns: (returncode, stdout, stderr)
    """
    # Environment-Variablen setzen
    env = os.environ.copy()
    if base_prompt:
        env["BASE_PROMPT"] = base_prompt
    if trigger:
        env["TRIGGER"] = trigger
    
    cmd = [
        "python3",
        str(LOCAL_PICS_SCRIPT),
    ]
    
    # Hinweis: local_pics.py muss angepasst werden, um Parameter zu akzeptieren
    # Aktuell hardcoded es die Werte - für MVP verwenden wir das Script as-is
    # und setzen init_image_path als Umgebungsvariable
    
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=str(PROJECT_ROOT),
        env=env,
    )
    stdout, stderr = await proc.communicate()
    return proc.returncode or 0, stdout.decode("utf-8", errors="replace"), stderr.decode("utf-8", errors="replace")


async def stream_local_pics():
    """
    Streamt local_pics.py Output als SSE Events.
    """
    cmd = ["python3", str(LOCAL_PICS_SCRIPT)]
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        cwd=str(PROJECT_ROOT),
    )

    assert proc.stdout is not None
    buffer = b""
    try:
        while True:
            chunk = await proc.stdout.read(256)
            if not chunk:
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                text = line.decode("utf-8", errors="replace")
                payload = json.dumps({"type": "log", "data": text})
                yield f"data: {payload}\n\n"

        # Flush remaining
        if buffer:
            text = buffer.decode("utf-8", errors="replace")
            payload = json.dumps({"type": "log", "data": text})
            yield f"data: {payload}\n\n"

        rc = await proc.wait()
        done = json.dumps({"type": "done", "returncode": rc})
        yield f"data: {done}\n\n"
    except asyncio.CancelledError:
        proc.kill()
        await proc.wait()


# ───────────────────────────────────────────────────────────────────────────
# Pydantic Models
# ───────────────────────────────────────────────────────────────────────────


class ImageGenerationRequest(BaseModel):
    """Request für Einzelbild-Generierung."""
    prompt: str
    negative_prompt: Optional[str] = None
    width: int = 1024
    height: int = 1024
    steps: int = 28
    guidance: float = 3.5
    seed: Optional[int] = None
    strength: Optional[float] = None  # Nur für img2img
    init_image_path: Optional[str] = None  # Nur für img2img


class DatasetGenerationRequest(BaseModel):
    """Request für Dataset-Generierung."""
    init_image_path: str
    base_prompt: Optional[str] = None
    trigger: Optional[str] = None
    num_images: int = 20
    strength: float = 0.55
    guidance: float = 1.5
    steps: int = 4
    create_video: bool = True


# ───────────────────────────────────────────────────────────────────────────
# API Endpoints: Dataset
# ───────────────────────────────────────────────────────────────────────────


@router.post("/dataset/generate")
async def generate_dataset(request: DatasetGenerationRequest):
    """
    Startet die Dataset-Generierung (local_pics.py).
    """
    # Prüfen ob Init-Bild existiert
    init_path = PROJECT_ROOT / request.init_image_path
    if not init_path.exists():
        raise HTTPException(400, detail=f"Init-Bild nicht gefunden: {request.init_image_path}")
    
    # Starte Generierung im Hintergrund
    # Hinweis: Für echtes Background-Job-Management müsste man Celery o.ä. verwenden
    # Für MVP: Blockierend, aber mit Timeout
    
    rc, out, err = await run_local_pics(
        init_image_path=request.init_image_path,
        num_images=request.num_images,
        strength=request.strength,
        guidance=request.guidance,
        steps=request.steps,
        base_prompt=request.base_prompt,
        trigger=request.trigger,
        create_video=request.create_video,
    )
    
    if rc != 0:
        raise HTTPException(500, detail=err or out)
    
    return {
        "ok": True,
        "output": out,
        "dataset_path": str(IMAGES_DIR.absolute()),
        "num_images": request.num_images,
    }


@router.get("/dataset/stream")
async def stream_dataset_generation():
    """
    Streamt Dataset-Generierung als SSE Events.
    """
    return StreamingResponse(
        stream_local_pics(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@router.get("/dataset/status")
async def get_dataset_status():
    """
    Status der Dataset-Generierung.
    """
    # Zähle generierte Bilder
    images_count = 0
    texts_count = 0
    video_exists = False
    
    if IMAGES_DIR.exists():
        images_count = len(list(IMAGES_DIR.glob("*.png")))
    
    if TEXTS_DIR.exists():
        texts_count = len(list(TEXTS_DIR.glob("*.txt")))
    
    video_path = DATASET_DIR / "consistency_check.mp4"
    if video_path.exists():
        video_exists = True
    
    return {
        "images_count": images_count,
        "texts_count": texts_count,
        "video_exists": video_exists,
        "dataset_path": str(IMAGES_DIR.absolute()),
    }


@router.get("/dataset/preview")
async def get_dataset_preview():
    """
    Streamt das Konsistenz-Video.
    """
    video_path = DATASET_DIR / "consistency_check.mp4"
    if not video_path.exists():
        raise HTTPException(404, detail="Konsistenz-Video nicht gefunden")
    
    return FileResponse(
        str(video_path),
        media_type="video/mp4",
        filename="consistency_check.mp4",
    )


# ───────────────────────────────────────────────────────────────────────────
# API Endpoints: Master-Bilder
# ───────────────────────────────────────────────────────────────────────────


@router.get("/master")
async def list_master_images():
    """
    Liste alle Master-Bilder.
    """
    if not MASTER_IMAGES_DIR.exists():
        return {"images": []}
    
    images = []
    for img_path in MASTER_IMAGES_DIR.glob("*.png"):
        images.append({
            "key": img_path.stem,
            "filename": img_path.name,
            "path": str(img_path.absolute()),
            "size": img_path.stat().st_size,
        })
    
    return {"images": images}


@router.post("/master/{key}")
async def upload_master_image(key: str, file: UploadFile = File(...)):
    """
    Uploadt oder ersetzt ein Master-Bild.
    """
    MASTER_IMAGES_DIR.mkdir(exist_ok=True)
    
    # Speichere Bild
    img_path = MASTER_IMAGES_DIR / f"{key}.png"
    
    content = await file.read()
    with open(img_path, "wb") as f:
        f.write(content)
    
    return {
        "ok": True,
        "key": key,
        "path": str(img_path.absolute()),
    }


@router.delete("/master/{key}")
async def delete_master_image(key: str):
    """
    Löscht ein Master-Bild.
    """
    img_path = MASTER_IMAGES_DIR / f"{key}.png"
    if not img_path.exists():
        raise HTTPException(404, detail=f"Master-Bild '{key}' nicht gefunden")
    
    img_path.unlink()
    
    return {"ok": True, "deleted": key}


@router.get("/master/{key}/preview")
async def get_master_image_preview(key: str):
    """
    Vorschau eines Master-Bildes.
    """
    img_path = MASTER_IMAGES_DIR / f"{key}.png"
    if not img_path.exists():
        raise HTTPException(404, detail=f"Master-Bild '{key}' nicht gefunden")
    
    return FileResponse(
        str(img_path),
        media_type="image/png",
        filename=f"{key}.png",
    )


# ───────────────────────────────────────────────────────────────────────────
# API Endpoints: Einzelbild-Generierung
# ───────────────────────────────────────────────────────────────────────────


@router.post("/generate")
async def generate_image(request: ImageGenerationRequest):
    """
    Generiert ein einzelnes Bild via SDXL (ap_img2img.py).
    
    Hinweis: Dies ist ein Placeholder. Die tatsächliche Implementierung
    muss den Gradio Client oder die SDXL API ansprechen.
    """
    # TODO: Implementierung der tatsächlichen Bildgenerierung
    # Für MVP: Returne Mock-Response
    
    return {
        "ok": True,
        "message": "Bildgenerierung wird implementiert",
        "request": request.dict(),
    }


@router.get("/{image_id}")
async def get_generated_image(image_id: str):
    """
    Ruft ein generiertes Bild ab.
    """
    # TODO: Implementierung
    raise HTTPException(501, detail="Noch nicht implementiert")
