"""
Stack Config Router — Konfiguration pro Stack (Remote vs Lokal).
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
STACK_CONFIG_FILE = PROJECT_ROOT / ".stack_config.json"

router = APIRouter()


class StackConfig(BaseModel):
    """Konfiguration für einen Stack."""
    mode: str = "remote"  # "remote" oder "local"
    local_model: Optional[str] = None  # Pfad zum lokalen Modell
    auto_start_local: bool = False  # Lokal automatisch starten wenn Stack ausgewählt


def load_all_stack_configs() -> dict[str, StackConfig]:
    """Lädt alle Stack-Konfigurationen."""
    if not STACK_CONFIG_FILE.exists():
        return {}
    
    try:
        with open(STACK_CONFIG_FILE, 'r') as f:
            data = json.load(f)
            return {k: StackConfig(**v) for k, v in data.items()}
    except Exception:
        return {}


def save_stack_config(stack_name: str, config: StackConfig) -> None:
    """Speichert die Konfiguration für einen Stack."""
    all_configs = load_all_stack_configs()
    all_configs[stack_name] = config
    
    with open(STACK_CONFIG_FILE, 'w') as f:
        json.dump({k: v.dict() for k, v in all_configs.items()}, f, indent=2)


@router.get("")
async def get_all_stack_configs():
    """Alle Stack-Konfigurationen."""
    configs = load_all_stack_configs()
    return {
        "configs": {
            k: {
                "mode": v.mode,
                "local_model": v.local_model,
                "auto_start_local": v.auto_start_local,
            }
            for k, v in configs.items()
        }
    }


@router.get("/{stack_name}")
async def get_stack_config(stack_name: str):
    """Konfiguration für einen spezifischen Stack."""
    configs = load_all_stack_configs()
    config = configs.get(stack_name, StackConfig())
    
    return {
        "stack": stack_name,
        "mode": config.mode,
        "local_model": config.local_model,
        "auto_start_local": config.auto_start_local,
    }


@router.put("/{stack_name}")
async def update_stack_config(stack_name: str, config: StackConfig):
    """Aktualisiert die Konfiguration für einen Stack."""
    save_stack_config(stack_name, config)
    
    return {
        "ok": True,
        "stack": stack_name,
        "mode": config.mode,
        "local_model": config.local_model,
    }


@router.post("/{stack_name}/mode")
async def set_stack_mode(stack_name: str, mode: str, model: Optional[str] = None):
    """Setzt den Modus (remote/local) für einen Stack."""
    if mode not in ["remote", "local"]:
        raise HTTPException(400, detail="Ungültiger Modus. Muss 'remote' oder 'local' sein.")
    
    configs = load_all_stack_configs()
    config = configs.get(stack_name, StackConfig())
    config.mode = mode
    
    if model:
        config.local_model = model
    
    save_stack_config(stack_name, config)
    
    return {
        "ok": True,
        "stack": stack_name,
        "mode": mode,
        "local_model": model,
    }
