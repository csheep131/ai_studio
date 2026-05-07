"""
Training Router — LoRA Training für Video-Modelle.
"""
from __future__ import annotations

import asyncio
import json
import os
import shutil
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, File, HTTPException, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent

# Pfade
DATASET_DIR = PROJECT_ROOT / "video_training_dataset"
LORAS_DIR = PROJECT_ROOT / "loras"
TRAINING_OUTPUT_DIR = PROJECT_ROOT / "training_output"

router = APIRouter()

# ───────────────────────────────────────────────────────────────────────────
# Pydantic Models
# ───────────────────────────────────────────────────────────────────────────


class TrainingRequest(BaseModel):
    """Request für LoRA Training."""
    dataset_path: str
    base_model: str = "Wan-AI/Wan2.1-T2V-14B-Diffusers"
    lora_name: str
    trigger_word: str = "sundancer_style"
    
    # Trainings-Parameter
    epochs: int = 10
    batch_size: int = 1
    learning_rate: str = "1e-4"
    rank: int = 16
    alpha: int = 32
    resolution: str = "512x512"
    max_steps: int = 1000
    warmup_steps: int = 100


# ───────────────────────────────────────────────────────────────────────────
# Helper: Training Subprocess-Wrapper
# ───────────────────────────────────────────────────────────────────────────


async def run_training(request: TrainingRequest) -> tuple[int, str, str]:
    """
    Startet LoRA Training.
    
    Hinweis: Dies ist ein Placeholder. Die tatsächliche Implementierung
    muss das remote Training-Script auf dem video_lora Stack ausführen.
    """
    # TODO: Implementierung des tatsächlichen Trainings
    # Für MVP: Mock-Implementation
    
    output = f"""
Training gestartet: {request.lora_name}
Dataset: {request.dataset_path}
Base Model: {request.base_model}
Trigger: {request.trigger_word}

Parameter:
  Epochs: {request.epochs}
  Batch Size: {request.batch_size}
  Learning Rate: {request.learning_rate}
  Rank: {request.rank}
  Alpha: {request.alpha}
  Resolution: {request.resolution}
  Max Steps: {request.max_steps}
  Warmup Steps: {request.warmup_steps}

Training wird simuliert (MVP Placeholder)...
"""
    
    # Simuliere Training
    for step in range(0, request.max_steps, 100):
        output += f"Step {step}/{request.max_steps}  loss: 0.0{random.randint(30, 50)}  lr: {request.learning_rate}\n"
        await asyncio.sleep(0.1)  # Simulierte Verzögerung
    
    output += f"\nTraining abgeschlossen: {request.lora_name}\n"
    output += f"LoRA gespeichert unter: {LORAS_DIR / request.lora_name}.safetensors\n"
    
    return 0, output, ""


async def stream_training(request: TrainingRequest):
    """
    Streamt Training-Output als SSE Events.
    """
    output = f"""Training gestartet: {request.lora_name}
Dataset: {request.dataset_path}
Base Model: {request.base_model}
Trigger: {request.trigger_word}

Parameter:
  Epochs: {request.epochs}
  Batch Size: {request.batch_size}
  Learning Rate: {request.learning_rate}
  Rank: {request.rank}
  Alpha: {request.alpha}
  Resolution: {request.resolution}
  Max Steps: {request.max_steps}
  Warmup Steps: {request.warmup_steps}

"""
    
    import random
    
    for step in range(0, request.max_steps, 50):
        loss = 0.1 - (step / request.max_steps) * 0.07 + random.uniform(-0.005, 0.005)
        lr = float(request.learning_rate) * (1 - step / request.max_steps * 0.5)
        
        payload = json.dumps({
            "type": "log",
            "data": f"Step {step}/{request.max_steps}  loss: {loss:.4f}  lr: {lr:.2e}\n"
        })
        yield f"data: {payload}\n\n"
        
        await asyncio.sleep(0.2)  # Simulierte Verzögerung
    
    # Abschluss
    done = json.dumps({
        "type": "done",
        "returncode": 0,
        "lora_path": str(LORAS_DIR / request.lora_name),
    })
    yield f"data: {done}\n\n"


# ───────────────────────────────────────────────────────────────────────────
# API Endpoints: Datasets
# ───────────────────────────────────────────────────────────────────────────


@router.get("/datasets")
async def list_datasets():
    """
    Liste alle verfügbaren Datasets.
    """
    datasets = []
    
    # Suche nach Dataset-Verzeichnissen
    if DATASET_DIR.exists():
        datasets.append({
            "name": "video_training_dataset",
            "path": str(DATASET_DIR.absolute()),
            "images_count": len(list(DATASET_DIR.glob("images/*.png"))) if (DATASET_DIR / "images").exists() else 0,
            "texts_count": len(list(DATASET_DIR.glob("texts/*.txt"))) if (DATASET_DIR / "texts").exists() else 0,
            "has_video": (DATASET_DIR / "consistency_check.mp4").exists(),
        })
    
    # Suche nach weiteren Datasets
    for dataset_dir in PROJECT_ROOT.glob("*_dataset"):
        if dataset_dir == DATASET_DIR:
            continue
        if not dataset_dir.is_dir():
            continue
        
        datasets.append({
            "name": dataset_dir.name,
            "path": str(dataset_dir.absolute()),
            "images_count": len(list(dataset_dir.glob("images/*.png"))) if (dataset_dir / "images").exists() else 0,
            "texts_count": len(list(dataset_dir.glob("texts/*.txt"))) if (dataset_dir / "texts").exists() else 0,
            "has_video": (dataset_dir / "consistency_check.mp4").exists(),
        })
    
    return {"datasets": datasets}


@router.get("/dataset/{name}")
async def get_dataset_details(name: str):
    """
    Details eines spezifischen Datasets.
    """
    if name == "video_training_dataset":
        dataset_dir = DATASET_DIR
    else:
        dataset_dir = PROJECT_ROOT / f"{name}_dataset"
    
    if not dataset_dir.exists():
        raise HTTPException(404, detail=f"Dataset '{name}' nicht gefunden")
    
    images_dir = dataset_dir / "images"
    texts_dir = dataset_dir / "texts"
    
    # Liste Bilder mit Captions
    images = []
    if images_dir.exists():
        for img_path in sorted(images_dir.glob("*.png"))[:10]:  # Max 10 für Preview
            caption_path = texts_dir / f"{img_path.stem}.txt" if texts_dir.exists() else None
            caption = None
            if caption_path and caption_path.exists():
                caption = caption_path.read_text(encoding="utf-8")
            
            images.append({
                "filename": img_path.name,
                "path": str(img_path.absolute()),
                "caption": caption,
            })
    
    return {
        "name": name,
        "path": str(dataset_dir.absolute()),
        "images_count": len(list(images_dir.glob("*.png"))) if images_dir.exists() else 0,
        "texts_count": len(list(texts_dir.glob("*.txt"))) if texts_dir.exists() else 0,
        "has_video": (dataset_dir / "consistency_check.mp4").exists(),
        "preview_images": images,
    }


@router.post("/dataset")
async def upload_dataset(
    name: str,
    images: list[UploadFile] = File(...),
):
    """
    Uploadt ein neues Dataset.
    """
    dataset_dir = PROJECT_ROOT / f"{name}_dataset" / "images"
    dataset_dir.mkdir(parents=True, exist_ok=True)
    
    uploaded_count = 0
    for file in images:
        if not file.filename:
            continue
        
        img_path = dataset_dir / file.filename
        content = await file.read()
        with open(img_path, "wb") as f:
            f.write(content)
        uploaded_count += 1
    
    return {
        "ok": True,
        "dataset": name,
        "uploaded": uploaded_count,
        "path": str(dataset_dir.absolute()),
    }


# ───────────────────────────────────────────────────────────────────────────
# API Endpoints: Training
# ───────────────────────────────────────────────────────────────────────────


@router.post("/lora")
async def start_training(request: TrainingRequest):
    """
    Startet LoRA Training.
    """
    # Prüfen ob Dataset existiert
    dataset_path = Path(request.dataset_path)
    if not dataset_path.exists():
        raise HTTPException(400, detail=f"Dataset nicht gefunden: {request.dataset_path}")
    
    # Starte Training (simuliert für MVP)
    rc, out, err = await run_training(request)
    
    if rc != 0:
        raise HTTPException(500, detail=err or out)
    
    return {
        "ok": True,
        "output": out,
        "lora_name": request.lora_name,
    }


@router.get("/lora/stream")
async def stream_training_endpoint(
    dataset_path: str,
    lora_name: str,
    base_model: str = "Wan-AI/Wan2.1-T2V-14B-Diffusers",
    trigger_word: str = "sundancer_style",
    epochs: int = 10,
    batch_size: int = 1,
    learning_rate: str = "1e-4",
    rank: int = 16,
    alpha: int = 32,
    resolution: str = "512x512",
    max_steps: int = 1000,
    warmup_steps: int = 100,
):
    """
    Streamt Training-Output als SSE Events.
    """
    request = TrainingRequest(
        dataset_path=dataset_path,
        base_model=base_model,
        lora_name=lora_name,
        trigger_word=trigger_word,
        epochs=epochs,
        batch_size=batch_size,
        learning_rate=learning_rate,
        rank=rank,
        alpha=alpha,
        resolution=resolution,
        max_steps=max_steps,
        warmup_steps=warmup_steps,
    )
    
    return StreamingResponse(
        stream_training(request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@router.get("/lora/status")
async def get_training_status():
    """
    Status des aktuellen Trainings.
    
    Hinweis: Für echtes Job-Management müsste man den Status persisted.
    Für MVP: Returne Mock-Status.
    """
    return {
        "status": "idle",  # idle, training, done, failed
        "current_job": None,
    }


@router.delete("/lora/{job_id}")
async def cancel_training(job_id: str):
    """
    Bricht ein Training ab.
    """
    # TODO: Implementierung
    return {"ok": True, "cancelled": job_id}


# ───────────────────────────────────────────────────────────────────────────
# API Endpoints: Fertige LoRAs
# ───────────────────────────────────────────────────────────────────────────


@router.get("/lora/models")
async def list_lora_models():
    """
    Liste alle trainierten LoRAs.
    """
    if not LORAS_DIR.exists():
        return {"models": []}
    
    models = []
    for lora_path in LORAS_DIR.glob("*.safetensors"):
        models.append({
            "name": lora_path.stem,
            "filename": lora_path.name,
            "path": str(lora_path.absolute()),
            "size": lora_path.stat().st_size,
            "created": datetime.fromtimestamp(lora_path.stat().st_mtime).isoformat(),
        })
    
    return {"models": models}


@router.get("/lora/{name}/preview")
async def get_lora_preview(name: str):
    """
    Vorschau-Bilder eines LoRA.
    """
    # TODO: Implementierung
    return {
        "name": name,
        "preview_images": [],
    }


@router.put("/lora/{name}/activate")
async def activate_lora(name: str):
    """
    Aktiviert ein LoRA für den Video-Workflow.
    """
    lora_path = LORAS_DIR / f"{name}.safetensors"
    if not lora_path.exists():
        raise HTTPException(404, detail=f"LoRA '{name}' nicht gefunden")
    
    # Speichere aktives LoRA in Config
    config_path = PROJECT_ROOT / ".active_lora.json"
    config = {
        "active_lora": name,
        "path": str(lora_path.absolute()),
        "activated_at": datetime.now().isoformat(),
    }
    
    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
    
    return {
        "ok": True,
        "active_lora": name,
    }


@router.post("/lora/upload")
async def upload_lora(file: UploadFile = File(...)):
    """
    Uploadt ein manuelles LoRA.
    """
    LORAS_DIR.mkdir(exist_ok=True)
    
    if not file.filename:
        raise HTTPException(400, detail="Kein Dateiname angegeben")
    
    if not file.filename.endswith(".safetensors"):
        raise HTTPException(400, detail="Nur .safetensors Dateien werden unterstützt")
    
    lora_path = LORAS_DIR / file.filename
    content = await file.read()
    with open(lora_path, "wb") as f:
        f.write(content)
    
    return {
        "ok": True,
        "filename": file.filename,
        "path": str(lora_path.absolute()),
    }


# Import random für Mock-Implementation
import random
