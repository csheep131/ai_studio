"""
Stacks Router — studio.sh Integration für Maschinenverwaltung.
"""
from __future__ import annotations

import asyncio
import json
import re
import yaml
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import StreamingResponse

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
STUDIO_SCRIPT = PROJECT_ROOT / "studio.sh"
STACKS_YAML = PROJECT_ROOT / "stacks.yaml"

router = APIRouter()

# ───────────────────────────────────────────────────────────────────────────
# Stack-Konfiguration aus stacks.yaml laden
# ───────────────────────────────────────────────────────────────────────────

def load_stacks_config() -> dict[str, Any]:
    """Lädt die Stack-Konfiguration aus stacks.yaml."""
    if not STACKS_YAML.exists():
        return {}
    
    try:
        with open(STACKS_YAML, 'r') as f:
            data = yaml.safe_load(f)
            return data.get('stacks', {})
    except Exception:
        return {}


def get_stack_config(stack_name: str) -> dict[str, Any]:
    """Holt Konfiguration für einen spezifischen Stack."""
    config = load_stacks_config()
    return config.get(stack_name, {})


# Alle bekannten Stacks aus der YAML-Datei
def get_known_stacks() -> list[str]:
    """Liste aller bekannten Stacks."""
    return list(load_stacks_config().keys())


# ───────────────────────────────────────────────────────────────────────────
# Helper: studio.sh Subprocess-Wrapper
# ───────────────────────────────────────────────────────────────────────────


async def run_studio_command(*args: str, timeout: int = 300) -> tuple[int, str, str]:
    """
    Führt studio.sh Befehl aus.
    Returns: (returncode, stdout, stderr)
    """
    cmd = ["bash", str(STUDIO_SCRIPT)] + list(args)
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=str(PROJECT_ROOT),
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return proc.returncode or 0, stdout.decode("utf-8", errors="replace"), stderr.decode("utf-8", errors="replace")
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return -1, "", "Command timeout"


async def run_vast_command(*args: str, timeout: int = 600) -> tuple[int, str, str]:
    """
    Führt vast.py Befehl aus (für Stack-Operationen).
    Returns: (returncode, stdout, stderr)
    """
    VAST_PY = PROJECT_ROOT / "vast.py"
    cmd = ["python3", str(VAST_PY)] + list(args)
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=str(PROJECT_ROOT),
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return proc.returncode or 0, stdout.decode("utf-8", errors="replace"), stderr.decode("utf-8", errors="replace")
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return -1, "", "Command timeout"


async def stream_studio_command(*args: str):
    """
    Streamt studio.sh Output als SSE Events.
    """
    cmd = ["bash", str(STUDIO_SCRIPT)] + list(args)
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
# Parser: studio.sh status Output
# ───────────────────────────────────────────────────────────────────────────

def parse_studio_status(output: str) -> list[dict[str, Any]]:
    """
    Parst das Output von 'studio.sh status' in eine JSON-Struktur.
    
    Expected format (example):
    ID  Machine  Status  Num  Model  Util. %  vCPUs  RAM  Storage  SSH Addr  SSH Port  $/hr  Image  Net up  Net down  R  Label  age(hours)  uptime(mins)
    14823  vastai-test  running  0  ...
    """
    stacks = []
    lines = output.strip().split("\n")
    
    # Skip header line (first line contains "ID  Machine  Status...")
    for line in lines[1:]:
        if not line.strip():
            continue
        
        # Skip lines that look like headers
        if "ID" in line and "Machine" in line:
            continue
        
        # Parse columns (tab or space separated)
        parts = line.split()
        if len(parts) < 3:
            continue
        
        # First part is ID, second is machine name, third is status
        stack_id = parts[0]
        machine_name = parts[1] if len(parts) > 1 else "unknown"
        status_raw = parts[2] if len(parts) > 2 else "unknown"
        
        # Determine status
        status = "unknown"
        if "running" in status_raw.lower() or "● läuft" in status_raw:
            status = "running"
        elif "stopped" in status_raw.lower() or "○ aus" in status_raw:
            status = "stopped"
        elif "rented" in status_raw.lower():
            status = "running"
        elif "available" in status_raw.lower():
            status = "stopped"
        
        # Try to extract GPU info from later columns
        gpu = "—"
        price = "—"
        if len(parts) > 4:
            # Model might be in position 4 or 5
            potential_gpu = parts[4] if len(parts) > 4 else ""
            if any(x in potential_gpu.upper() for x in ["H100", "H200", "A100", "RTX", "4090", "GPU"]):
                gpu = potential_gpu
        
        # Price is usually towards the end
        for part in parts:
            if re.match(r'^\d+\.?\d*$', part) and len(part) <= 5:
                price = part
                break
        
        stacks.append({
            "id": stack_id,
            "name": machine_name,
            "status": status,
            "status_raw": status_raw,
            "gpu": gpu,
            "price": price,
            "details": line,
        })
    
    return stacks


# ───────────────────────────────────────────────────────────────────────────
# API Endpoints
# ───────────────────────────────────────────────────────────────────────────

@router.get("")
async def list_stacks():
    """
    Liste alle Stacks mit ihrem Status.
    Kombiniert stacks.yaml Konfiguration mit studio.sh status.
    """
    # Lade Konfiguration aus YAML
    yaml_config = load_stacks_config()
    
    # Hole aktuellen Status von studio.sh
    rc, out, err = await run_studio_command("status", timeout=30)
    status_list = parse_studio_status(out) if rc == 0 else []
    
    # Baue vollständige Stack-Liste mit Konfiguration
    stacks = []
    for stack_name, config in yaml_config.items():
        # Suche passenden Status-Eintrag
        status_entry = next((s for s in status_list if s.get('name') == stack_name), None)
        
        stack_info = {
            "name": stack_name,
            "label": config.get('label', stack_name),
            "status": status_entry['status'] if status_entry else 'stopped',
            "status_raw": status_entry['status_raw'] if status_entry else '○ gestoppt',
            "gpu": status_entry.get('gpu') if status_entry else 'XXX',
            "price_per_hour": status_entry.get('price') if status_entry else 'XXX',
            "vast_id": status_entry.get('id') if status_entry else None,
            "service_port": config.get('service_port'),
            "local_port": config.get('local_port'),
            "api_tunnel_port": config.get('api_tunnel_port'),
            "default_model": config.get('default_model'),
            "max_dph": config.get('max_dph'),
            "min_vram_mb": config.get('min_vram_mb'),
            "details": status_entry.get('details') if status_entry else None,
        }
        
        stacks.append(stack_info)
    
    return {"stacks": stacks}


@router.get("/{stack_name}")
async def get_stack(stack_name: str):
    """
    Details eines spezifischen Stacks.
    """
    config = get_stack_config(stack_name)
    if not config:
        raise HTTPException(404, detail=f"Stack '{stack_name}' nicht gefunden")
    
    # Hole Status
    rc, out, err = await run_studio_command("status", timeout=30)
    status_list = parse_studio_status(out) if rc == 0 else []
    status_entry = next((s for s in status_list if s.get('name') == stack_name), None)
    
    return {
        "name": stack_name,
        "label": config.get('label', stack_name),
        "status": status_entry['status'] if status_entry else 'stopped',
        "status_raw": status_entry['status_raw'] if status_entry else '○ gestoppt',
        "gpu": status_entry.get('gpu') if status_entry else 'XXX',
        "price_per_hour": status_entry.get('price') if status_entry else 'XXX',
        "vast_id": status_entry.get('id') if status_entry else None,
        "service_port": config.get('service_port'),
        "local_port": config.get('local_port'),
        "api_tunnel_port": config.get('api_tunnel_port'),
        "default_model": config.get('default_model'),
        "max_dph": config.get('max_dph'),
        "min_vram_mb": config.get('min_vram_mb'),
        "details": status_entry.get('details') if status_entry else None,
    }


@router.post("/{stack_name}/start")
async def start_stack(stack_name: str):
    """
    Startet einen Stack (vast.py go).
    Mietet und richtet eine GPU-Instanz ein.
    """
    if stack_name not in get_known_stacks():
        raise HTTPException(400, detail=f"Unknown stack: {stack_name}")
    
    # Verwende vast.py go Befehl (wie studio.sh go)
    # --open wird NICHT verwendet, da wir keinen Browser öffnen wollen
    rc, out, err = await run_vast_command("go", stack_name, timeout=600)
    
    if rc != 0:
        raise HTTPException(500, detail=err or out)
    
    return {"ok": True, "output": out}


@router.post("/{stack_name}/ensure")
async def ensure_stack(stack_name: str):
    """
    Stellt sicher dass ein Stack läuft (Mieten + Einrichten).
    Alias für start.
    """
    return await start_stack(stack_name)


@router.post("/{stack_name}/stop")
async def stop_stack(stack_name: str):
    """
    Stoppt einen Stack (vast.py stop).
    Gibt die Remote-Instanz frei.
    """
    if stack_name not in get_known_stacks():
        raise HTTPException(400, detail=f"Unknown stack: {stack_name}")
    
    # Verwende vast.py stop Befehl
    rc, out, err = await run_vast_command("stop", stack_name, timeout=300)
    
    if rc != 0:
        raise HTTPException(500, detail=err or out)
    
    return {"ok": True, "output": out}


@router.post("/{stack_name}/tunnel")
async def start_tunnel(stack_name: str):
    """
    Startet SSH-Tunnel für einen Stack (vast.py stack open).
    """
    if stack_name not in get_known_stacks():
        raise HTTPException(400, detail=f"Unknown stack: {stack_name}")
    
    # Verwende vast.py stack open Befehl
    rc, out, err = await run_vast_command("stack", "open", stack_name, timeout=120)
    
    if rc != 0:
        raise HTTPException(500, detail=err or out)
    
    # Extrahiere Port aus Output wenn möglich
    import re
    port_match = re.search(r'localhost:(\d+)', out)
    port = port_match.group(1) if port_match else None
    
    return {"ok": True, "output": out, "port": port}


@router.get("/{stack_name}/health")
async def get_health(stack_name: str):
    """
    Health-Check für einen Stack (vast.py doctor).
    """
    if stack_name not in get_known_stacks():
        raise HTTPException(400, detail=f"Unknown stack: {stack_name}")
    
    rc, out, err = await run_vast_command("doctor", stack_name, timeout=120)
    
    return {
        "ok": rc == 0,
        "output": out,
        "error": err,
    }


@router.get("/{stack_name}/logs")
async def stream_stack_logs(stack_name: str):
    """
    Streamt Live-Logs eines Stacks (SSE).
    """
    if stack_name not in KNOWN_STACKS:
        raise HTTPException(400, detail=f"Unknown stack: {stack_name}")
    
    return StreamingResponse(
        stream_studio_command("logs", stack_name),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )
