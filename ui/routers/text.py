"""
Text/Drehbuch Router — Script Generation & Management API
"""
from __future__ import annotations

import json
import os
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

import aiohttp
from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

# ─────────────────────────────────────────────────────────────────────────────
# Paths & Config
# ─────────────────────────────────────────────────────────────────────────────

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
WORKSPACE_DIR = PROJECT_ROOT / "workspace"
SCRIPTS_DIR = WORKSPACE_DIR / "scripts"
SCENES_FILE = PROJECT_ROOT / "scenes.json"  # Film-Workflow Szenen-Datei
VIDEO_OUTPUT = PROJECT_ROOT / "video_output"

# Import workflow functions for clip discovery
import sys
sys.path.insert(0, str(PROJECT_ROOT / "ui"))
from routers.workflow import get_available_clips

# Ensure directories exist
SCRIPTS_DIR.mkdir(parents=True, exist_ok=True)

LLM_API_URL = "http://127.0.0.1:8080/v1/chat/completions"
LLM_TIMEOUT = 120  # seconds

router = APIRouter()

# ─────────────────────────────────────────────────────────────────────────────
# Pydantic Models
# ─────────────────────────────────────────────────────────────────────────────

class ScriptScene(BaseModel):
    """Einzelne Szene im Drehbuch."""
    id: str
    scene_number: int
    act: int = 1
    title: str = ""
    description: str = ""
    visual_prompt: str = ""
    keywords: str = ""
    duration_seconds: int = 5
    ref: str = ""  # Referenz zu Clip/Datei
    notes: str = ""


class Script(BaseModel):
    """Drehbuch Metadaten."""
    id: str
    title: str = "Neues Drehbuch"
    created_at: str
    updated_at: str
    prompt: str = ""  # Ursprünglicher User-Prompt
    system_prompt: str = ""  # Verwendetes System-Prompt
    exported_to_film: bool = False
    film_run_id: Optional[str] = None


class ScriptWithScenes(BaseModel):
    """Drehbuch mit allen Szenen."""
    script: Script
    scenes: list[ScriptScene]


class ScriptSummary(BaseModel):
    """Kurzinfo für Listenansicht."""
    id: str
    title: str
    updated_at: str
    scenes_count: int


class GenerateRequest(BaseModel):
    """Request für LLM-Generierung."""
    user_prompt: str
    system_prompt: str = ""
    target_scenes: int = Field(default=5, ge=1, le=50)
    temperature: float = Field(default=0.7, ge=0, le=2)


class GenerateResponse(BaseModel):
    """Response von LLM-Generierung."""
    title: str
    scenes: list[dict[str, Any]]
    raw_response: Optional[str] = None


class GenerateStatus(BaseModel):
    """Status-Update für Streaming-Generierung."""
    status: str  # "starting", "generating", "parsing", "complete", "error"
    progress: int  # 0-100
    message: str
    partial_content: Optional[str] = None
    error: Optional[str] = None


# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

def get_script_path(script_id: str) -> Path:
    """Get file path for a script."""
    return SCRIPTS_DIR / f"{script_id}.json"


def sanitize_filename(name: str) -> str:
    """Sanitize string for use in filename."""
    return "".join(c for c in name if c.isalnum() or c in "_-").strip() or "script"


def guess_act_for_scene(scene_num: int, total_scenes: int) -> int:
    """Guess act based on scene position."""
    if total_scenes == 0:
        return 1
    ratio = scene_num / total_scenes
    if ratio <= 0.25:
        return 1
    if ratio <= 0.75:
        return 2
    return 3


def parse_llm_response(content: str, target_scenes: int) -> dict[str, Any]:
    """
    Parse LLM response and extract JSON structure.
    Handles various formats and cleans up common issues.
    """
    content = content.strip()

    # Try to find JSON block in markdown code fences
    if "```json" in content:
        start = content.find("```json") + 7
        end = content.find("```", start)
        if end > start:
            content = content[start:end].strip()
    elif "```" in content:
        start = content.find("```") + 3
        end = content.find("```", start)
        if end > start:
            content = content[start:end].strip()

    # Try parsing as JSON
    try:
        data = json.loads(content)
        return normalize_script_data(data, target_scenes)
    except json.JSONDecodeError:
        pass

    # Fallback: Try to extract structured data with regex-like parsing
    # This is a last resort for malformed LLM outputs
    return fallback_parse(content, target_scenes)


def normalize_script_data(data: dict, target_scenes: int) -> dict[str, Any]:
    """Normalize and validate script data from LLM."""
    result = {
        "title": data.get("title", "Generiertes Drehbuch"),
        "scenes": []
    }

    scenes = data.get("scenes", [])
    if not scenes and "scene" in data:
        scenes = data["scene"]

    for idx, scene_data in enumerate(scenes[:target_scenes]):
        scene = {
            "scene_number": scene_data.get("scene_number", idx + 1),
            "act": scene_data.get("act", guess_act_for_scene(idx + 1, len(scenes))),
            "title": scene_data.get("title", f"Szene {idx + 1}"),
            "description": scene_data.get("description", scene_data.get("desc", "")),
            "visual_prompt": scene_data.get("visual_prompt",
                scene_data.get("visual", scene_data.get("prompt", ""))),
            "keywords": scene_data.get("keywords", ""),
            "duration_seconds": scene_data.get("duration_seconds",
                scene_data.get("duration", 5)),
            "notes": scene_data.get("notes", "")
        }
        result["scenes"].append(scene)

    return result


def fallback_parse(content: str, target_scenes: int) -> dict[str, Any]:
    """Fallback parser for non-JSON LLM outputs."""
    lines = content.strip().split("\n")

    result = {
        "title": "Generiertes Drehbuch",
        "scenes": []
    }

    current_scene: Optional[dict] = None
    scene_idx = 0

    for line in lines:
        line = line.strip()
        if not line:
            continue

        # Look for scene headers
        if line.lower().startswith("szene") or line.lower().startswith("scene"):
            if current_scene and scene_idx < target_scenes:
                result["scenes"].append(current_scene)
                scene_idx += 1

            # Extract scene number if present
            parts = line.split()
            try:
                scene_num = int(parts[1]) if len(parts) > 1 else scene_idx + 1
            except ValueError:
                scene_num = scene_idx + 1

            current_scene = {
                "scene_number": scene_num,
                "act": guess_act_for_scene(scene_num, target_scenes),
                "title": line,
                "description": "",
                "visual_prompt": "",
                "keywords": "",
                "duration_seconds": 5,
                "notes": ""
            }

        elif current_scene:
            # Accumulate description
            if line.lower().startswith("visual") or line.lower().startswith("prompt"):
                current_scene["visual_prompt"] = line.split(":", 1)[1].strip() if ":" in line else line
            elif line.lower().startswith("keywords"):
                current_scene["keywords"] = line.split(":", 1)[1].strip() if ":" in line else line
            else:
                current_scene["description"] += " " + line if current_scene["description"] else line

    # Don't forget the last scene
    if current_scene and scene_idx < target_scenes:
        result["scenes"].append(current_scene)

    return result


# ─────────────────────────────────────────────────────────────────────────────
# API Endpoints
# ─────────────────────────────────────────────────────────────────────────────

@router.get("/scripts", response_model=list[ScriptSummary])
async def list_scripts() -> list[ScriptSummary]:
    """List all saved scripts with summary info."""
    scripts = []

    for script_file in SCRIPTS_DIR.glob("*.json"):
        try:
            with open(script_file, "r", encoding="utf-8") as f:
                data = json.load(f)

            script_data = data.get("script", {})
            scenes = data.get("scenes", [])

            scripts.append(ScriptSummary(
                id=script_data.get("id", script_file.stem),
                title=script_data.get("title", "Unbenannt"),
                updated_at=script_data.get("updated_at", script_data.get("created_at", "")),
                scenes_count=len(scenes)
            ))
        except Exception:
            continue

    # Sort by updated_at desc
    scripts.sort(key=lambda x: x.updated_at, reverse=True)
    return scripts


@router.post("/scripts")
async def save_script(data: ScriptWithScenes) -> dict[str, Any]:
    """Save or update a script."""
    script = data.script

    # Ensure ID exists
    if not script.id:
        script.id = f"script_{uuid.uuid4().hex[:12]}"

    # Update timestamp
    script.updated_at = datetime.now().isoformat()

    # Prepare full data
    payload = {
        "script": script.model_dump(),
        "scenes": [s.model_dump() for s in data.scenes]
    }

    # Save to file
    script_path = get_script_path(script.id)
    with open(script_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, ensure_ascii=False)

    return {"ok": True, "id": script.id, "saved_at": script.updated_at}


@router.get("/scripts/{script_id}", response_model=ScriptWithScenes)
async def get_script(script_id: str) -> ScriptWithScenes:
    """Get a specific script with all scenes."""
    script_path = get_script_path(script_id)

    if not script_path.exists():
        raise HTTPException(status_code=404, detail="Script not found")

    try:
        with open(script_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        script = Script(**data.get("script", {}))
        scenes = [ScriptScene(**s) for s in data.get("scenes", [])]

        return ScriptWithScenes(script=script, scenes=scenes)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to load script: {str(e)}")


@router.delete("/scripts/{script_id}")
async def delete_script(script_id: str) -> dict[str, Any]:
    """Delete a script."""
    script_path = get_script_path(script_id)

    if not script_path.exists():
        raise HTTPException(status_code=404, detail="Script not found")

    try:
        script_path.unlink()
        return {"ok": True, "message": "Script deleted"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to delete: {str(e)}")


@router.post("/generate", response_model=GenerateResponse)
async def generate_script(request: GenerateRequest) -> GenerateResponse:
    """
    Generate a script using the local LLM.
    Requires llama.cpp server running on port 8080.
    """
    # Build the full prompt
    system_msg = request.system_prompt or "Du bist ein Drehbuchautor für KI-generierte Videos."

    user_msg = f"""{request.user_prompt}

Erstelle ein Drehbuch mit etwa {request.target_scenes} Szenen.
Antworte im JSON-Format mit diesem Schema:
{{
  "title": "Drehbuch-Titel",
  "scenes": [
    {{
      "scene_number": 1,
      "act": 1,
      "title": "Szene-Titel",
      "description": "Detaillierte Beschreibung...",
      "visual_prompt": "Prompt für Video-Generierung...",
      "keywords": "schlüsselwörter",
      "duration_seconds": 5
    }}
  ]
}}"""

    # Call local LLM
    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=LLM_TIMEOUT)) as session:
            payload = {
                "model": "local-model",
                "messages": [
                    {"role": "system", "content": system_msg},
                    {"role": "user", "content": user_msg}
                ],
                "temperature": request.temperature,
                "max_tokens": 4000,
                "stream": False
            }

            async with session.post(LLM_API_URL, json=payload) as resp:
                if resp.status != 200:
                    text = await resp.text()
                    raise HTTPException(status_code=502, detail=f"LLM error: {text}")

                result = await resp.json()

                # Extract content from response
                if "choices" in result and len(result["choices"]) > 0:
                    content = result["choices"][0]["message"]["content"]
                elif "content" in result:
                    content = result["content"]
                else:
                    raise HTTPException(status_code=502, detail="Unexpected LLM response format")

                # Parse the response
                parsed = parse_llm_response(content, request.target_scenes)

                return GenerateResponse(
                    title=parsed.get("title", "Generiertes Drehbuch"),
                    scenes=parsed.get("scenes", []),
                    raw_response=content if not parsed.get("scenes") else None
                )

    except aiohttp.ClientError as e:
        raise HTTPException(status_code=503, detail=f"Cannot connect to LLM server: {str(e)}")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Generation failed: {str(e)}")


@router.post("/export-to-film/{script_id}")
async def export_to_film(script_id: str) -> dict[str, Any]:
    """
    Export script to film workflow.
    Creates/updates scenes.json for the film workflow.
    """
    # Load script
    script_path = get_script_path(script_id)
    if not script_path.exists():
        raise HTTPException(status_code=404, detail="Script not found")

    try:
        with open(script_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        script_data = data.get("script", {})
        scenes = data.get("scenes", [])

        if not scenes:
            raise HTTPException(status_code=400, detail="No scenes to export")

        # Convert script scenes to film workflow format
        film_scenes = []
        for scene in scenes:
            film_scene = {
                "id": scene.get("scene_number", 0),
                "act": scene.get("act", 1),
                "subject": scene.get("title", ""),
                "keywords": scene.get("keywords", ""),
                "visual_focus": scene.get("visual_prompt", ""),
                "environment": scene.get("description", ""),
                "ref": scene.get("ref", ""),
                "seed": scene.get("seed", 0),
                "fps": 24,
                "seconds": scene.get("duration_seconds", 5)
            }
            film_scenes.append(film_scene)

        # Write scenes.json for film workflow
        scenes_data = {"scenes": film_scenes}
        with open(SCENES_FILE, "w", encoding="utf-8") as f:
            json.dump(scenes_data, f, indent=2, ensure_ascii=False)

        # Update script metadata
        script_data["exported_to_film"] = True
        script_data["film_run_id"] = f"run_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        script_data["updated_at"] = datetime.now().isoformat()

        data["script"] = script_data
        with open(script_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

        return {
            "ok": True,
            "message": "Exported to film workflow",
            "film_run_id": script_data["film_run_id"],
            "scenes_file": str(SCENES_FILE),
            "scenes_exported": len(film_scenes)
        }

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Export failed: {str(e)}")


@router.get("/templates")
async def get_templates() -> dict[str, str]:
    """Get available system prompt templates."""
    return {
        "standard": "Standard 3-Akt-Struktur für narrative Videos",
        "short": "Kurzfilm (1-3 Minuten), kompakt und fokussiert",
        "commercial": "Werbespot (15-30 Sekunden) mit Call-to-Action",
        "musicvideo": "Musikvideo mit visuellen, atmosphärischen Szenen",
        "tutorial": "Tutorial/Erklärvideo mit Schritt-für-Schritt-Struktur",
        "custom": "Benutzerdefiniertes Template"
    }


# ─────────────────────────────────────────────────────────────────────────────
# Clip Management
# ─────────────────────────────────────────────────────────────────────────────

@router.get("/clips")
async def list_available_clips() -> list[dict[str, Any]]:
    """List all available video clips for assignment to script scenes."""
    return get_available_clips()


@router.post("/scripts/{script_id}/assign-clip")
async def assign_clip_to_scene(script_id: str, scene_id: str, clip_id: str) -> dict[str, Any]:
    """Assign a video clip to a specific scene in the script."""
    script_path = get_script_path(script_id)
    if not script_path.exists():
        raise HTTPException(status_code=404, detail="Script not found")

    try:
        with open(script_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        scenes = data.get("scenes", [])
        scene_found = False

        for scene in scenes:
            if scene.get("id") == scene_id:
                scene["ref"] = clip_id
                scene_found = True
                break

        if not scene_found:
            raise HTTPException(status_code=404, detail="Scene not found")

        # Update timestamp
        data["script"]["updated_at"] = datetime.now().isoformat()

        with open(script_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

        return {"ok": True, "message": "Clip assigned", "scene_id": scene_id, "clip_id": clip_id}

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to assign clip: {str(e)}")


# ─────────────────────────────────────────────────────────────────────────────
# Film Workflow Integration
# ─────────────────────────────────────────────────────────────────────────────

@router.get("/scripts/{script_id}/film-status")
async def get_script_film_status(script_id: str) -> dict[str, Any]:
    """Get the film workflow status for a script (clips generated, etc.)."""
    script_path = get_script_path(script_id)
    if not script_path.exists():
        raise HTTPException(status_code=404, detail="Script not found")

    try:
        with open(script_path, "r", encoding="utf-8") as f:
            data = json.load(f)

        script_data = data.get("script", {})
        scenes = data.get("scenes", [])

        # Count clips assigned
        scenes_with_clips = sum(1 for s in scenes if s.get("ref"))

        # Get available clips for reference
        available_clips = get_available_clips()

        # Check if exported film exists
        film_exists = SCENES_FILE.exists()
        film_scenes = []
        if film_exists:
            try:
                with open(SCENES_FILE, "r", encoding="utf-8") as f:
                    film_data = json.load(f)
                    film_scenes = film_data.get("scenes", [])
            except:
                pass

        return {
            "script_id": script_id,
            "title": script_data.get("title", "Unbenannt"),
            "exported_to_film": script_data.get("exported_to_film", False),
            "film_run_id": script_data.get("film_run_id"),
            "total_scenes": len(scenes),
            "scenes_with_clips": scenes_with_clips,
            "scenes_without_clips": len(scenes) - scenes_with_clips,
            "film_exists": film_exists,
            "film_scenes_count": len(film_scenes),
            "available_clips": len(available_clips),
            "can_generate_missing": len(scenes) - scenes_with_clips > 0
        }

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to get status: {str(e)}")


@router.post("/scripts/{script_id}/sync-from-film")
async def sync_from_film(script_id: str) -> dict[str, Any]:
    """Sync clip references from film workflow back to script."""
    script_path = get_script_path(script_id)
    if not script_path.exists():
        raise HTTPException(status_code=404, detail="Script not found")

    if not SCENES_FILE.exists():
        raise HTTPException(status_code=400, detail="No film workflow data found")

    try:
        # Load script
        with open(script_path, "r", encoding="utf-8") as f:
            script_data = json.load(f)

        # Load film scenes
        with open(SCENES_FILE, "r", encoding="utf-8") as f:
            film_data = json.load(f)

        film_scenes = {s.get("id"): s for s in film_data.get("scenes", [])}
        script_scenes = script_data.get("scenes", [])

        updated_count = 0
        for scene in script_scenes:
            scene_num = scene.get("scene_number")
            if scene_num in film_scenes:
                film_scene = film_scenes[scene_num]
                if film_scene.get("ref") and not scene.get("ref"):
                    scene["ref"] = film_scene["ref"]
                    updated_count += 1

        if updated_count > 0:
            script_data["script"]["updated_at"] = datetime.now().isoformat()
            with open(script_path, "w", encoding="utf-8") as f:
                json.dump(script_data, f, indent=2, ensure_ascii=False)

        return {
            "ok": True,
            "message": f"Synced {updated_count} clip references",
            "updated_count": updated_count
        }

    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Sync failed: {str(e)}")


# ─────────────────────────────────────────────────────────────────────────────
# Streaming Generation
# ─────────────────────────────────────────────────────────────────────────────

async def stream_generation(request: GenerateRequest):
    """
    Generator für Streaming-LLM-Generierung.
    Yields SSE-formatierte Status-Updates.
    """
    def send_event(data: dict) -> str:
        return f"data: {json.dumps(data)}\n\n"

    # Build prompt
    system_msg = request.system_prompt or "Du bist ein Drehbuchautor für KI-generierte Videos."

    user_msg = f"""{request.user_prompt}

Erstelle ein Drehbuch mit etwa {request.target_scenes} Szenen.
Antworte im JSON-Format mit diesem Schema:
{{
  "title": "Drehbuch-Titel",
  "scenes": [
    {{
      "scene_number": 1,
      "act": 1,
      "title": "Szene-Titel",
      "description": "Detaillierte Beschreibung...",
      "visual_prompt": "Prompt für Video-Generierung...",
      "keywords": "schlüsselwörter",
      "duration_seconds": 5
    }}
  ]
}}"""

    yield send_event({
        "status": "starting",
        "progress": 5,
        "message": "Verbinde mit LLM...",
        "partial_content": None
    })

    full_content = ""

    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=LLM_TIMEOUT)) as session:
            payload = {
                "model": "local-model",
                "messages": [
                    {"role": "system", "content": system_msg},
                    {"role": "user", "content": user_msg}
                ],
                "temperature": request.temperature,
                "max_tokens": 4000,
                "stream": True
            }

            async with session.post(LLM_API_URL, json=payload) as resp:
                if resp.status != 200:
                    text = await resp.text()
                    yield send_event({
                        "status": "error",
                        "progress": 0,
                        "message": f"LLM Fehler: {text}",
                        "error": text
                    })
                    return

                yield send_event({
                    "status": "generating",
                    "progress": 20,
                    "message": "Generiere Drehbuch...",
                    "partial_content": None
                })

                # Stream-Verarbeitung
                async for line in resp.content:
                    line = line.decode('utf-8').strip()
                    if not line or line.startswith(':'):
                        continue

                    if line.startswith('data: '):
                        data_str = line[6:]
                        if data_str == '[DONE]':
                            break

                        try:
                            chunk = json.loads(data_str)
                            if 'choices' in chunk and len(chunk['choices']) > 0:
                                delta = chunk['choices'][0].get('delta', {})
                                if 'content' in delta:
                                    content = delta['content']
                                    full_content += content

                                    # Progress basierend auf Content-Länge schätzen
                                    estimated_progress = min(20 + len(full_content) // 50, 70)
                                    yield send_event({
                                        "status": "generating",
                                        "progress": estimated_progress,
                                        "message": "Generiere Drehbuch...",
                                        "partial_content": full_content[-200:] if len(full_content) > 200 else full_content
                                    })
                        except json.JSONDecodeError:
                            continue

                # Parsing
                yield send_event({
                    "status": "parsing",
                    "progress": 80,
                    "message": "Verarbeite Antwort...",
                    "partial_content": None
                })

                # Parse final result
                parsed = parse_llm_response(full_content, request.target_scenes)

                yield send_event({
                    "status": "complete",
                    "progress": 100,
                    "message": "Fertig!",
                    "result": {
                        "title": parsed.get("title", "Generiertes Drehbuch"),
                        "scenes": parsed.get("scenes", [])
                    },
                    "raw_response": full_content if not parsed.get("scenes") else None
                })

    except aiohttp.ClientError as e:
        yield send_event({
            "status": "error",
            "progress": 0,
            "message": f"Verbindungsfehler: {str(e)}",
            "error": str(e)
        })
    except Exception as e:
        yield send_event({
            "status": "error",
            "progress": 0,
            "message": f"Fehler: {str(e)}",
            "error": str(e)
        })


@router.post("/generate/stream")
async def generate_script_stream(request: GenerateRequest):
    """
    Stream-generate a script using the local LLM.
    Returns SSE stream with progress updates.
    """
    return StreamingResponse(
        stream_generation(request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        }
    )
