"""
Workflow command wrapper — parses workflow.conf, reads/writes scenes.json,
and runs video_script_full_workflow.sh commands via subprocess.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
WORKFLOW_SCRIPT = PROJECT_ROOT / "video_script_full_workflow.sh"
WORKFLOW_CONF = PROJECT_ROOT / "workflow.conf"
SCENES_FILE = PROJECT_ROOT / "scenes.json"
WORKFLOW_STATE = PROJECT_ROOT / ".video_workflow_state.json"
VIDEO_OUTPUT = PROJECT_ROOT / "video_output"
BLUEPRINT_FILE = PROJECT_ROOT / "prnszene.txt"

router = APIRouter()

# ---------------------------------------------------------------------------
# workflow.conf  bash → JSON  /  JSON → bash
# ---------------------------------------------------------------------------

# Known config keys and their default types
CONF_KEYS = [
    "MASTER_IMAGES_DIR", "OUTPUT_DIR", "SCENES_FILE",
    "REMOTE_WORKDIR", "REMOTE_RUNS_BASE", "REMOTE_I2V_SCRIPT", "REMOTE_PYTHON",
    "I2V_MODEL",
    "FPS", "CLIP_SECONDS", "STEPS", "GUIDANCE", "SEED_BASE", "WIDTH", "HEIGHT",
    "MASTER_COLOR_LOOK", "NEGATIVE_PROMPT", "CAMERA_STYLE",
    "REF_ELENA_FRONT", "REF_ELENA_SIDE", "REF_MARKUS_FRONT", "REF_MARKUS_ENV",
]

NUMERIC_KEYS = {"FPS", "CLIP_SECONDS", "STEPS", "GUIDANCE", "SEED_BASE", "WIDTH", "HEIGHT"}


def parse_workflow_conf() -> dict[str, Any]:
    """Parse bash workflow.conf into a dict. Skips comments and blank lines."""
    if not WORKFLOW_CONF.exists():
        return {}
    result: dict[str, Any] = {}
    for line in WORKFLOW_CONF.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)="?(.*?)"?$', line)
        if not m:
            m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line)
        if m:
            key, val = m.group(1), m.group(2).strip().strip('"')
            if key in NUMERIC_KEYS:
                try:
                    val = float(val)
                    if val == int(val):
                        val = int(val)
                except ValueError:
                    pass
            result[key] = val
    return result


def update_workflow_conf(data: dict[str, Any]) -> None:
    """Write back a dict to workflow.conf preserving comments and order."""
    if not WORKFLOW_CONF.exists():
        lines: list[str] = []
    else:
        lines = WORKFLOW_CONF.read_text(encoding="utf-8").splitlines()

    # Build lookup of current values
    written_keys: set[str] = set()
    new_lines: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            new_lines.append(line)
            continue
        m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=', stripped)
        if m:
            key = m.group(1)
            if key in data:
                val = data[key]
                new_lines.append(f'{key}="{val}"')
                written_keys.add(key)
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)

    # Append any new keys not yet in file
    for key in CONF_KEYS:
        if key in data and key not in written_keys:
            new_lines.append(f'{key}="{data[key]}"')

    WORKFLOW_CONF.write_text("\n".join(new_lines) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# scenes.json
# ---------------------------------------------------------------------------

def read_scenes_json() -> dict[str, Any]:
    if not SCENES_FILE.exists():
        return {"scenes": []}
    return json.loads(SCENES_FILE.read_text(encoding="utf-8"))


def write_scenes_json(data: dict[str, Any]) -> None:
    SCENES_FILE.write_text(
        json.dumps(data, ensure_ascii=True, indent=2) + "\n",
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# Video file discovery
# ---------------------------------------------------------------------------

def get_video_files() -> list[dict[str, Any]]:
    """List all MP4 files under video_output/, grouped by run."""
    files: list[dict[str, Any]] = []
    if not VIDEO_OUTPUT.exists():
        return files
    for run_dir in sorted(VIDEO_OUTPUT.iterdir(), reverse=True):
        if not run_dir.is_dir():
            continue
        for mp4 in sorted(run_dir.glob("*.mp4")):
            files.append({
                "run": run_dir.name,
                "file": mp4.name,
                "path": str(mp4.relative_to(PROJECT_ROOT)),
                "size": mp4.stat().st_size,
            })
    return files


def get_available_clips() -> list[dict[str, Any]]:
    """Get all available clips for assignment to script scenes."""
    clips = []
    if not VIDEO_OUTPUT.exists():
        return clips

    for run_dir in sorted(VIDEO_OUTPUT.iterdir(), reverse=True):
        if not run_dir.is_dir():
            continue
        for mp4 in sorted(run_dir.glob("*.mp4")):
            clip_id = f"{run_dir.name}/{mp4.name}"
            clips.append({
                "id": clip_id,
                "name": mp4.name.replace(".mp4", ""),
                "run": run_dir.name,
                "file": mp4.name,
                "path": str(mp4.relative_to(PROJECT_ROOT)),
                "size": mp4.stat().st_size,
                "thumbnail": f"/api/workflow/video/{run_dir.name}/{mp4.name}",
            })
    return clips


# ---------------------------------------------------------------------------
# Workflow state
# ---------------------------------------------------------------------------

def get_workflow_state() -> dict[str, Any]:
    if not WORKFLOW_STATE.exists():
        return {"status": "no_runs"}
    return json.loads(WORKFLOW_STATE.read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# Subprocess runner
# ---------------------------------------------------------------------------

async def run_workflow_command(*args: str) -> tuple[int, str, str]:
    """Run video_script_full_workflow.sh with given args. Returns (rc, stdout, stderr)."""
    cmd = ["bash", str(WORKFLOW_SCRIPT)] + list(args)
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=str(PROJECT_ROOT),
    )
    stdout, stderr = await proc.communicate()
    return proc.returncode or 0, stdout.decode("utf-8", errors="replace"), stderr.decode("utf-8", errors="replace")


# ===================================================================
# API Endpoints
# ===================================================================

# --- Config ---
class ConfigPayload(BaseModel):
    config: dict[str, Any]

@router.get("/config")
async def get_config():
    return parse_workflow_conf()

@router.put("/config")
async def put_config(payload: ConfigPayload):
    update_workflow_conf(payload.config)
    return {"ok": True, "config": parse_workflow_conf()}


# --- Scenes ---
class ScenesPayload(BaseModel):
    scenes: list[dict[str, Any]]

@router.get("/scenes")
async def get_scenes():
    return read_scenes_json()

@router.put("/scenes")
async def put_scenes(payload: ScenesPayload):
    write_scenes_json({"scenes": payload.scenes})
    return {"ok": True, "count": len(payload.scenes)}


# --- Workflow commands ---
@router.post("/init")
async def cmd_init():
    rc, out, err = await run_workflow_command("init")
    if rc != 0:
        raise HTTPException(500, detail=err or out)
    return {"ok": True, "output": out}


@router.post("/validate")
async def cmd_validate():
    rc, out, err = await run_workflow_command("validate")
    if rc != 0:
        raise HTTPException(400, detail=err or out)
    return {"ok": True, "output": out}


class PilotPayload(BaseModel):
    start_id: int = 1
    end_id: int = 10

@router.post("/pilot")
async def cmd_pilot(payload: PilotPayload):
    rc, out, err = await run_workflow_command("pilot", str(payload.start_id), str(payload.end_id))
    if rc != 0:
        raise HTTPException(500, detail=err or out)
    return {"ok": True, "output": out}


class GenPayload(BaseModel):
    selector: str = "all"  # scene id or "all"

@router.post("/gen")
async def cmd_gen(payload: GenPayload):
    rc, out, err = await run_workflow_command("gen", payload.selector)
    if rc != 0:
        raise HTTPException(500, detail=err or out)
    return {"ok": True, "output": out}


class StitchPayload(BaseModel):
    output: Optional[str] = "final.mp4"

@router.post("/stitch")
async def cmd_stitch(payload: StitchPayload):
    rc, out, err = await run_workflow_command("stitch", "--output", payload.output or "final.mp4")
    if rc != 0:
        raise HTTPException(500, detail=err or out)
    return {"ok": True, "output": out}


# --- Status ---
@router.get("/status")
async def get_status():
    state = get_workflow_state()
    scenes = read_scenes_json()
    videos = get_video_files()
    runs: dict[str, list] = {}
    for v in videos:
        runs.setdefault(v["run"], []).append(v)
    return {
        "state": state,
        "total_scenes": len(scenes.get("scenes", [])),
        "runs": {k: {"clips": len(v), "files": v} for k, v in runs.items()},
    }


# --- Video streaming (serve MP4 files) ---
from fastapi.responses import FileResponse

@router.get("/video/{run}/{scene}")
async def serve_video(run: str, scene: str):
    """Serve a single MP4 file from video_output/."""
    # Sanitize path components
    safe_run = Path(run).name
    safe_scene = Path(scene).name
    fpath = VIDEO_OUTPUT / safe_run / safe_scene
    if not fpath.exists():
        raise HTTPException(404, f"Video not found: {run}/{scene}")
    return FileResponse(str(fpath), media_type="video/mp4")
