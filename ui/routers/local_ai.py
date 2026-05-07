"""
Local AI Router — Open WebUI & llama.cpp Integration für lokale AI-Modelle.
"""
from __future__ import annotations

import asyncio
import json
import os
import subprocess
from pathlib import Path
from typing import Any, Optional

import httpx
from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent

# Open WebUI / Ollama Konfiguration
OPEN_WEBUI_URL = os.getenv("OPEN_WEBUI_URL", "http://127.0.0.1:3002")
OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11435")
LLAMA_SERVER_URL = os.getenv("LLAMA_SERVER_URL", "http://127.0.0.1:8080")  # Dein nativer llama.cpp Server

# Pfade für lokale AI
LLAMA_CPP_DIR = PROJECT_ROOT / "llama.cpp"
MODELS_DIR = PROJECT_ROOT / "models"

router = APIRouter()

# Globaler State für lokalen llama.cpp Server
local_server_process: Optional[asyncio.subprocess.Process] = None
local_server_model: Optional[str] = None


class ChatRequest(BaseModel):
    """Open WebUI / Ollama Chat Request."""
    model: str
    messages: list[dict[str, str]]
    stream: bool = False


class LoadModelRequest(BaseModel):
    """Request zum Laden eines Modells."""
    model: str
    source: str = "ollama"  # "ollama" oder "open-webui"


# ───────────────────────────────────────────────────────────────────────────
# Helper: Open WebUI / Ollama API
# ───────────────────────────────────────────────────────────────────────────


async def get_ollama_models() -> list[str]:
    """Holt verfügbare Modelle von Ollama."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{OLLAMA_URL}/api/tags")
            if resp.status_code == 200:
                data = resp.json()
                return [m["name"] for m in data.get("models", [])]
    except Exception:
        pass
    return []


async def get_open_webui_models() -> list[str]:
    """Holt verfügbare Modelle von Open WebUI."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{OPEN_WEBUI_URL}/api/models")
            if resp.status_code == 200:
                data = resp.json()
                models = []
                for m in data.get("data", []):
                    if "name" in m:
                        models.append(m["name"])
                return models
    except Exception:
        pass
    return []


async def is_open_webui_running() -> bool:
    """Prüft ob Open WebUI läuft."""
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(OPEN_WEBUI_URL)
            return resp.status_code == 200
    except Exception:
        return False


async def is_ollama_running() -> bool:
    """Prüft ob Ollama läuft."""
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{OLLAMA_URL}/api/version")
            return resp.status_code == 200
    except Exception:
        return False


# ───────────────────────────────────────────────────────────────────────────
# Helper: llama.cpp Server Control
# ───────────────────────────────────────────────────────────────────────────


def find_gguf_models() -> list[str]:
    """Sucht nach GGUF-Modellen in verschiedenen Verzeichnissen."""
    models = []
    seen = set()
    
    # Typische Pfade für GGUF-Modelle
    search_paths = [
        # Project local
        MODELS_DIR,
        PROJECT_ROOT / "models" / "gguf",
        
        # Home directory variants
        Path.home() / "models",
        Path.home() / "models" / "gguf",
        Path.home() / ".ollama" / "models",
        Path.home() / ".local" / "share" / "ollama" / "models",
        Path.home() / ".local" / "share" / "goose" / "models",
        
        # Open WebUI paths
        Path("/app/models"),
        Path("/root/.ollama/models"),
        Path.home() / "open-webui" / "models",
        Path.home() / ".local" / "share" / "open-webui" / "models",
        
        # System-wide
        Path("/usr/share/models"),
        Path("/opt/models"),
        
        # Tools directories
        Path.home() / "tools" / "llama-cpp" / "models",
        
        # Offline LLM (dein Pfad!)
        Path.home() / "stuff" / "offline_llm" / "models",
        Path.home() / "stuff" / "offline_llm" / "modelle",
        Path.home() / "tools" / "llama-cpp-turboquant-cuda" / "models",
        Path.home() / "ai" / "models",
        Path.home() / "AI" / "models",
    ]
    
    for search_path in search_paths:
        try:
            if not search_path.exists():
                continue
        except (PermissionError, OSError):
            # Skip paths we can't access
            continue
        
        # Direkt im Pfad suchen
        try:
            for model_file in search_path.glob("*.gguf"):
                if model_file.name in seen:
                    continue
                
                # Filter: Nur "echte" Modelle (keine reinen Vokabular-Dateien)
                name_lower = model_file.name.lower()
                if any(x in name_lower for x in ['ggml-vocab', 'vocab']):
                    continue
                
                # Mindestgröße: 100MB (filtere sehr kleine Dateien)
                if model_file.stat().st_size < 50 * 1024 * 1024:
                    continue
                
                models.append(model_file.name)
                seen.add(model_file.name)
        except (PermissionError, OSError):
            continue
        
        # In Unterverzeichnissen suchen (z.B. ollama Struktur)
        try:
            for model_file in search_path.rglob("*.gguf"):
                if model_file.name in seen:
                    continue
                
                # Filter: Nur "echte" Modelle
                name_lower = model_file.name.lower()
                if any(x in name_lower for x in ['ggml-vocab', 'vocab']):
                    continue
                
                # Mindestgröße: 100MB
                if model_file.stat().st_size < 50 * 1024 * 1024:
                    continue
                
                models.append(model_file.name)
                seen.add(model_file.name)
        except (PermissionError, OSError):
            continue
    
    return sorted(models)


async def is_llama_server_running() -> bool:
    """Prüft ob der native llama.cpp Server läuft."""
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(f"{LLAMA_SERVER_URL}/health")
            return resp.status_code == 200
    except Exception:
        # Fallback: pgrep
        try:
            result = subprocess.run(
                ["pgrep", "-f", "llama-server"],
                capture_output=True,
                text=True,
            )
            return result.returncode == 0 and bool(result.stdout.strip())
        except Exception:
            return False


def get_running_model() -> Optional[str]:
    """Gibt das aktuell geladene Modell zurück (vom nativen llama.cpp Server)."""
    global local_server_model
    
    # Wenn bereits gespeichert, zurückgeben
    if local_server_model:
        return local_server_model
    
    # Versuchen vom Server zu holen
    try:
        result = subprocess.run(
            ["curl", "-s", f"{LLAMA_SERVER_URL}/health"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if result.returncode == 0 and result.stdout:
            import json
            data = json.loads(result.stdout)
            return data.get("model_path", "").split("/")[-1] or None
    except Exception:
        pass
    
    return None


async def start_llama_server(model_path: str, port: int = 8080) -> tuple[bool, str]:
    """
    Startet den llama.cpp Server.
    Sucht das Modell rekursiv in allen bekannten Verzeichnissen.
    
    Returns: (success, message)
    """
    global local_server_process, local_server_model
    
    # Modell-Pfad auflösen
    model_full_path = None
    
    # 1. Als absoluter Pfad prüfen
    if model_path and Path(model_path).exists():
        model_full_path = model_path
    # 2. Im MODELS_DIR suchen
    elif model_path and (MODELS_DIR / model_path).exists():
        model_full_path = str(MODELS_DIR / model_path)
    # 3. In verschiedenen Verzeichnissen suchen (auch rekursiv)
    elif model_path:
        search_base_dirs = [
            Path.home() / "models",
            Path.home() / ".local" / "share" / "goose" / "models",
            Path.home() / ".local" / "share" / "open-webui" / "models",
            Path.home() / "open-webui" / "models",
            Path.home() / ".ollama" / "models",
            Path.home() / "tools" / "llama-cpp" / "models",
            Path.home() / "tools" / "llama-cpp-turboquant-cuda" / "models",
            Path.home() / "stuff" / "offline_llm",
            Path.home() / "ai" / "models",
            Path.home() / "AI" / "models",
        ]
        
        # Suche in allen Verzeichnissen rekursiv
        for base_dir in search_base_dirs:
            if not base_dir.exists():
                continue
            try:
                for gguf_file in base_dir.rglob("*.gguf"):
                    if gguf_file.name == model_path:
                        model_full_path = str(gguf_file)
                        break
                if model_full_path:
                    break
            except (PermissionError, OSError):
                continue
    
    if not model_full_path:
        available = find_gguf_models()
        return False, f"Modell nicht gefunden: {model_path}. Verfügbare Modelle: {', '.join(available[:5]) if available else 'Keine'}"
    
    # llama-server finden
    llama_server = None
    for candidate in [
        LLAMA_CPP_DIR / "build" / "bin" / "llama-server",
        LLAMA_CPP_DIR / "llama-server",
        Path("/usr/local/bin/llama-server"),
        Path.home() / ".local" / "bin" / "llama-server",
        Path("/usr/bin/llama-server"),
    ]:
        if candidate.exists():
            llama_server = candidate
            break
    
    # Als Fallback im PATH suchen
    if not llama_server:
        try:
            result = subprocess.run(
                ["which", "llama-server"],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0 and result.stdout.strip():
                llama_server = Path(result.stdout.strip())
        except Exception:
            pass
    
    if not llama_server:
        return False, "llama-server nicht gefunden. Bitte llama.cpp installieren."
    
    # Server starten
    cmd = [
        str(llama_server),
        "-m", model_full_path,
        "--host", "127.0.0.1",
        "--port", str(port),
        "-c", "32768",  # Context size
        "--threads", str(os.cpu_count() or 4),
    ]
    
    try:
        local_server_process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        local_server_model = Path(model_full_path).name
        
        # Kurz warten damit der Server starten kann
        await asyncio.sleep(3)
        
        return True, f"Server gestartet mit {local_server_model}"
    except Exception as e:
        return False, f"Fehler beim Starten: {str(e)}"


async def stop_llama_server() -> tuple[bool, str]:
    """Stoppt den llama.cpp Server."""
    global local_server_process, local_server_model
    
    if local_server_process:
        try:
            local_server_process.terminate()
            await asyncio.wait_for(local_server_process.wait(), timeout=5)
            local_server_process = None
            local_server_model = None
            return True, "Server gestoppt"
        except asyncio.TimeoutError:
            local_server_process.kill()
            local_server_process = None
            local_server_model = None
            return True, "Server wurde beendet (kill)"
        except Exception as e:
            return False, f"Fehler: {str(e)}"
    
    # Fallback: pgrep/pkill
    try:
        subprocess.run(["pkill", "-f", "llama-server"], check=False)
        local_server_model = None
        return True, "Server gestoppt"
    except Exception as e:
        return False, f"Fehler: {str(e)}"


# ───────────────────────────────────────────────────────────────────────────
# API Endpoints
# ───────────────────────────────────────────────────────────────────────────


@router.get("/status")
async def get_local_ai_status():
    """
    Status der lokalen AI (Open WebUI + nativer llama.cpp Server).
    """
    open_webui_running = await is_open_webui_running()
    llama_server_running = await is_llama_server_running()
    
    # Modelle von Open WebUI (wenn auth möglich)
    open_webui_models = await get_open_webui_models() if open_webui_running else []
    
    # GGUF Modelle für direkten llama.cpp Betrieb
    gguf_models = find_gguf_models()
    
    # Kombinierte Modellliste
    all_models = list(set(open_webui_models + gguf_models))
    
    # Aktuelles Modell vom Server holen
    current_model = get_running_model()
    
    return {
        "running": llama_server_running,
        "open_webui": {
            "running": open_webui_running,
            "url": OPEN_WEBUI_URL,
            "models": open_webui_models,
            "note": "Open WebUI (Docker) mit Auth - Modelle über UI sichtbar",
        },
        "llama_cpp": {
            "running": llama_server_running,
            "url": LLAMA_SERVER_URL,
            "model": current_model,
            "models": gguf_models,
            "note": "Nativer llama.cpp Server (nicht Docker)",
        },
        "available_models": all_models,
        "port": 8080,
        "api_url": f"{LLAMA_SERVER_URL}/v1",
    }


@router.post("/start")
async def start_local_ai():
    """
    Startet lokale AI mit dem zuletzt verwendeten oder ersten verfügbaren Modell.
    """
    global local_server_model
    
    if is_llama_server_running():
        return {"ok": True, "message": "Server läuft bereits"}
    
    # Wenn kein Modell geladen ist, erstes verfügbares verwenden
    if not local_server_model:
        models = find_gguf_models()
        if not models:
            raise HTTPException(400, detail="Keine GGUF-Modelle gefunden. Bitte Modell in ~/models oder ~/.local/share/goose/models ablegen.")
        local_server_model = models[0]
    
    success, message = await start_llama_server(local_server_model)
    
    if not success:
        raise HTTPException(500, detail=message)
    
    return {"ok": True, "message": message, "model": local_server_model}


@router.post("/stop")
async def stop_local_ai():
    """
    Stoppt lokale AI.
    """
    success, message = await stop_llama_server()
    
    if not success:
        raise HTTPException(500, detail=message)
    
    return {"ok": True, "message": message}


@router.post("/model")
async def load_model(request: LoadModelRequest):
    """
    Lädt ein Modell in den llama.cpp Server.
    """
    global local_server_model
    
    if not request.model:
        raise HTTPException(400, detail="Modell-Pfad darf nicht leer sein")
    
    # Wenn Server bereits läuft mit anderem Modell, neu starten
    if is_llama_server_running() and local_server_model != request.model:
        await stop_llama_server()
        await asyncio.sleep(1)
    
    success, message = await start_llama_server(request.model)
    
    if not success:
        raise HTTPException(500, detail=message)
    
    return {"ok": True, "message": message, "model": request.model}


@router.get("/models")
async def list_models():
    """
    Liste alle verfügbaren GGUF-Modelle.
    """
    return {
        "models": find_gguf_models(),
        "models_dir": str(MODELS_DIR.absolute()),
    }
