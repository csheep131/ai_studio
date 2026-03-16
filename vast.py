#!/usr/bin/env python3
"""
vast.py - Zentrale Vast.ai Verwaltung

Backend für:
- Instanz-Mietlogik (rent)
- Health-Checks
- SSH-Operationen
- Stack-Konfiguration (aus stacks.yaml)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Optional, Dict, List, Tuple, Union

import yaml

SCRIPT_DIR = Path(__file__).resolve().parent
STACKS_YAML = SCRIPT_DIR / "stacks.yaml"
MANAGE_SCRIPT = SCRIPT_DIR / "manage_v7_fixed.sh"
ENV_FILE = SCRIPT_DIR / ".env"
HF_TOKEN_FILE = SCRIPT_DIR / ".hf_token"
STATE_PREFIX = ".vast_instance_"
MANIFEST_PATH = "/etc/stack_manifest.json"

# Wird aus stacks.yaml geladen
STACK_CONFIG: Dict[str, Any] = {}


def _load_project_env() -> None:
    """Load simple KEY=VALUE pairs from .env into os.environ if not already set."""
    if not ENV_FILE.exists():
        return

    for raw_line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        os.environ.setdefault(key, value)


_load_project_env()


def _resolve_project_hf_token() -> str:
    if HF_TOKEN_FILE.exists():
        return HF_TOKEN_FILE.read_text(encoding="utf-8").strip()
    return os.environ.get("HF_TOKEN", "") or os.environ.get("HUGGINGFACE_HUB_TOKEN", "")


def _export_project_hf_token() -> None:
    token = _resolve_project_hf_token()
    if token:
        os.environ["HF_TOKEN"] = token
        os.environ["HUGGINGFACE_HUB_TOKEN"] = token


_export_project_hf_token()


# ========== SSH Port Resolution ==========

def parse_ssh_command(text: str) -> Optional[Dict[str, Any]]:
    """
    Parse SSH command string like:
    - "ssh -p 18533 root@ssh8.vast.ai -L 8080:localhost:8080"
    - "ssh -p18533 root@ssh8.vast.ai"
    Returns dict with ssh_host, ssh_port or None.
    """
    if not text:
        return None
    try:
        tokens = shlex.split(text)
    except ValueError:
        tokens = text.split()

    if not tokens or tokens[0] != "ssh":
        return None

    port: Optional[int] = None
    host: Optional[str] = None
    options_with_arg = {
        "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L",
        "-l", "-m", "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w",
    }

    i = 1
    while i < len(tokens):
        token = tokens[i]
        if token == "-p":
            if i + 1 < len(tokens) and str(tokens[i + 1]).isdigit():
                port = int(tokens[i + 1])
            i += 2
            continue
        if token.startswith("-p") and token != "-p":
            raw_port = token[2:]
            if raw_port.isdigit():
                port = int(raw_port)
            i += 1
            continue
        if token in options_with_arg:
            i += 2
            continue
        if token.startswith("-"):
            i += 1
            continue

        host = token.split("@", 1)[-1]
        break

    if host and port:
        return {"ssh_port": port, "ssh_host": host}
    return None


def parse_hostport(text: str) -> Optional[Dict[str, Any]]:
    """
    Parse host:port string like:
    - "ssh8.vast.ai:18533"
    - "root@ssh8.vast.ai:18533"
    Returns dict with ssh_host, ssh_port or None.
    """
    if not text:
        return None
    text = text.strip()
    # Match HOST:PORT or USER@HOST:PORT
    m = re.match(r"^(?:[^@:\s]+@)?([^:\s]+):(\d+)$", text)
    if m:
        return {"ssh_host": m.group(1), "ssh_port": int(m.group(2))}
    return None


def parse_ssh_url(text: str) -> Optional[Dict[str, Any]]:
    """
    Parse SSH URL like:
    - "ssh://root@ssh8.vast.ai:18533"
    Returns dict with ssh_host, ssh_port or None.
    """
    if not text:
        return None
    text = text.strip()
    # Match: ssh://USER@HOST:PORT
    m = re.match(r"^ssh://(?:[^@/\s]+@)?([^:/\s]+):(\d+)(?:/.*)?$", text)
    if m:
        return {"ssh_host": m.group(1), "ssh_port": int(m.group(2))}
    return None


def resolve_instance_ssh_cli(instance_id: str) -> Optional[Dict[str, Any]]:
    """
    Ask Vast directly for the canonical SSH connect URL of one instance.
    This is more reliable than inferring from raw fields like ssh_port or
    machine_dir_ssh_port, which can differ for proxy-backed instances.
    """
    if not instance_id:
        return None

    try:
        cp = run(["vastai", "ssh-url", str(instance_id)], capture=True)
    except Exception:
        return None

    raw = (cp.stdout or "").strip()
    if not raw:
        return None

    for parser, source in (
        (parse_ssh_url, "ssh_url_helper"),
        (parse_ssh_command, "ssh_command_helper"),
        (parse_hostport, "ssh_hostport_helper"),
    ):
        parsed = parser(raw)
        if parsed:
            parsed["source"] = source
            return parsed
    return None


def resolve_instance_ssh(instance: dict) -> Dict[str, Any]:
    """
    Liefert den tatsächlich nutzbaren SSH-Host/Port für eine Vast-Instanz.

    Prioritäten:
    A. Fertiger Connect-String / SSH-URL (am zuverlässigsten)
    B. ports["22/tcp"] Feld (HostPort von Vast)
    C. ssh_port Feld von Vast (bei ssh*.vast.ai Proxy-Hosts der echte externe Port)
    D. machine_dir_ssh_port (interner Maschinen-Port, fuer Proxy-Hosts meist falsch)

    Rückgabe:
    {
        "ssh_host": "...",
        "ssh_port": 18533,
        "source": "ssh_url|ssh_command|hostport|ports_field|direct_port|ssh_port|machine_dir_ssh_port|error",
        "ssh_resolution_error": None  # oder Fehlerbeschreibung
    }
    """
    result = {
        "ssh_host": None,
        "ssh_port": None,
        "source": None,
        "ssh_resolution_error": None,
        "raw_ssh_url": None,
        "raw_ports": {},
    }

    # === Priorität A: Fertige Connect-Strings (beste Quelle) ===

    # 1. SSH URL (ssh://root@host:port)
    for key in ["ssh_url", "connect_url", "proxy_ssh_url"]:
        val = instance.get(key)
        if val:
            parsed = parse_ssh_url(val)
            if parsed:
                result["ssh_host"] = parsed["ssh_host"]
                result["ssh_port"] = parsed["ssh_port"]
                result["source"] = "ssh_url"
                result["raw_ssh_url"] = val
                return result

    # 2. SSH Command (ssh -p PORT root@HOST)
    for key in ["ssh_command", "connect_command", "proxy_ssh_command"]:
        val = instance.get(key)
        if val:
            parsed = parse_ssh_command(val)
            if parsed:
                result["ssh_host"] = parsed["ssh_host"]
                result["ssh_port"] = parsed["ssh_port"]
                result["source"] = "ssh_command"
                return result

    # 3. Host:Port String (root@host:port oder host:port)
    for key in ["ssh_hostport", "connect_string", "proxy_ssh"]:
        val = instance.get(key)
        if val:
            parsed = parse_hostport(val)
            if parsed:
                result["ssh_host"] = parsed["ssh_host"]
                result["ssh_port"] = parsed["ssh_port"]
                result["source"] = "hostport"
                return result

    # === Priorität B: ports["22/tcp"] HostPort (sehr zuverlässig) ===

    ssh_host = instance.get("ssh_host") or instance.get("public_ipaddr")
    ports = instance.get("ports") or {}
    result["raw_ports"] = ports

    if ports:
        # Suche nach SSH Port (22/tcp) - das ist der echte externe Port
        ssh_entry = ports.get("22/tcp", [])
        if ssh_entry and isinstance(ssh_entry, list) and len(ssh_entry) > 0:
            entry = ssh_entry[0]
            if isinstance(entry, dict):
                host_port = entry.get("HostPort")
                if host_port:
                    result["ssh_host"] = str(ssh_host or f"ssh{host_port}.vast.ai")
                    result["ssh_port"] = int(host_port)
                    result["source"] = "ports_field"
                    return result

        # Alternative: direct_port
        direct_port = instance.get("direct_port")
        if direct_port and isinstance(direct_port, int) and direct_port > 1024:
            result["ssh_port"] = direct_port
            result["ssh_host"] = ssh_host or f"ssh{direct_port}.vast.ai"
            result["source"] = "direct_port"
            return result

    # === Priorität C: ssh_port Feld (bei ssh*.vast.ai der echte externe Proxy-Port) ===

    ssh_host_str = str(ssh_host or "")
    ssh_port = instance.get("ssh_port")
    if ssh_host and ssh_port:
        result["ssh_host"] = ssh_host_str
        result["ssh_port"] = int(ssh_port)
        result["source"] = "ssh_port"
        return result

    # === Priorität D: machine_dir_ssh_port (interner Maschinen-Port, nur Notnagel) ===

    machine_dir_ssh_port = instance.get("machine_dir_ssh_port")
    if ssh_host and machine_dir_ssh_port and not re.match(r"^ssh\d+\.vast\.ai$", ssh_host_str):
        result["ssh_host"] = ssh_host_str
        result["ssh_port"] = int(machine_dir_ssh_port)
        result["source"] = "machine_dir_ssh_port"
        return result

    # === Fehler: Keine Quelle verfügbar ===

    result["ssh_resolution_error"] = f"Could not resolve SSH connection. Available keys: {list(instance.keys())}"
    result["source"] = "error"
    return result


# ========== END SSH Port Resolution ==========


class VastError(RuntimeError):
    pass


@dataclass
class Instance:
    id: str
    label: str
    gpu_name: str
    status: str
    ssh_host: str
    ssh_port: str
    public_ip: str
    dph_total: str
    cpu_cores: str
    gpu_ram: str
    ssh_source: str = ""
    ssh_resolution_error: str = ""

    @classmethod
    def from_raw(cls, raw: dict[str, Any]) -> "Instance":
        # Verwende zentrale SSH-Resolution-Logik
        ssh_info = resolve_instance_ssh(raw)
        
        ports = raw.get("ports") or {}
        direct_port = ""
        try:
            direct_port = str(ports.get("22/tcp", [{}])[0].get("HostPort") or "")
        except Exception:
            direct_port = ""
        
        return cls(
            id=str(raw.get("id") or ""),
            label=str(raw.get("label") or ""),
            gpu_name=str(raw.get("gpu_name") or ""),
            status=str(raw.get("actual_status") or raw.get("cur_state") or raw.get("intended_status") or "unknown").lower(),
            ssh_host=str(ssh_info.get("ssh_host") or raw.get("ssh_host") or raw.get("public_ipaddr") or ""),
            ssh_port=str(ssh_info.get("ssh_port") or raw.get("ssh_port") or direct_port or raw.get("machine_dir_ssh_port") or ""),
            public_ip=str(raw.get("public_ipaddr") or ""),
            dph_total=str(raw.get("dph_total") or raw.get("dph") or ""),
            cpu_cores=str(raw.get("cpu_cores_effective") or raw.get("cpu_cores") or ""),
            gpu_ram=str(raw.get("gpu_ram") or ""),
            ssh_source=str(ssh_info.get("source") or ""),
            ssh_resolution_error=str(ssh_info.get("ssh_resolution_error") or ""),
        )


def enrich_instance_with_canonical_ssh(inst: Optional[Instance]) -> Optional[Instance]:
    """Overlay the canonical Vast ssh-url result onto an Instance when available."""
    if not inst or not inst.id:
        return inst

    ssh_info = resolve_instance_ssh_cli(inst.id)
    if not ssh_info:
        return inst

    inst.ssh_host = str(ssh_info.get("ssh_host") or inst.ssh_host or "")
    inst.ssh_port = str(ssh_info.get("ssh_port") or inst.ssh_port or "")
    inst.ssh_source = str(ssh_info.get("source") or inst.ssh_source or "")
    return inst


# ---------- generic helpers ----------

def c(text: str, code: str) -> str:
    if not sys.stdout.isatty():
        return text
    return f"\033[{code}m{text}\033[0m"


def info(msg: str) -> None:
    print(c(msg, "36"))


def ok(msg: str) -> None:
    print(c(msg, "32"))


def warn(msg: str) -> None:
    print(c(msg, "33"))


def err(msg: str) -> None:
    print(c(msg, "31"), file=sys.stderr)


def need_cmd(name: str) -> None:
    if shutil.which(name) is None:
        raise VastError(f"Missing dependency: {name}")


def run(cmd: list[str], check: bool = True, capture: bool = False, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        capture_output=capture,
        env=merged_env,
    )


def sh(cmd: str, check: bool = True, capture: bool = False, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        cmd,
        shell=True,
        executable="/bin/bash",
        check=check,
        text=True,
        capture_output=capture,
        env=merged_env,
    )


def state_file(stack: str) -> Path:
    return SCRIPT_DIR / f"{STATE_PREFIX}{stack}"


def save_state(stack: str, instance: Instance) -> Path:
    """
    Save instance data as state file.
    Includes SSH resolution info for debugging and fallback.
    """
    sf = state_file(stack)
    
    # Keep only the resolved SSH port. Adjacent fallback ports caused false positives.
    port_candidates = str(instance.ssh_port) if instance.ssh_port else ""
    
    content = (
        f'INSTANCE_ID="{instance.id}"\n'
        f'INSTANCE_IP="{instance.ssh_host}"\n'
        f'INSTANCE_PORT="{instance.ssh_port}"\n'
        f'INSTANCE_PORT_CANDIDATES="{port_candidates}"\n'
        f'INSTANCE_STATUS="{instance.status}"\n'
        f'SSH_SOURCE="{instance.ssh_source}"\n'
        f'STACK="{stack}"\n'
    )
    
    if instance.ssh_resolution_error:
        content += f'SSH_RESOLUTION_ERROR="{instance.ssh_resolution_error}"\n'
    
    sf.write_text(content, encoding="utf-8")
    os.chmod(sf, 0o600)
    return sf


def load_state(stack: str) -> dict[str, str] | None:
    sf = state_file(stack)
    if not sf.exists():
        return None
    data: dict[str, str] = {}
    for line in sf.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip().strip('"')
    return data


def load_stack_config() -> Dict[str, Any]:
    """Lade stacks.yaml und extrahiere Stack-Konfiguration."""
    global STACK_CONFIG
    if STACK_CONFIG:
        return STACK_CONFIG
    
    if not STACKS_YAML.exists():
        raise VastError(f"Configuration file not found: {STACKS_YAML}")
    
    with open(STACKS_YAML, 'r', encoding='utf-8') as f:
        config = yaml.safe_load(f)
    
    stacks = config.get('stacks', {})
    defaults = config.get('defaults', {})
    
    # Konfiguration für jeden Stack aufbereiten
    STACK_CONFIG = {
        'stacks': stacks,
        'defaults': defaults,
    }
    return STACK_CONFIG


def get_stack_config(stack: str) -> Dict[str, Any]:
    """Hole Konfiguration für einen spezifischen Stack."""
    config = load_stack_config()
    stacks = config.get('stacks', {})
    if stack not in stacks:
        raise VastError(f"Unknown stack: {stack}")
    return stacks[stack]


def get_all_stacks() -> List[str]:
    """Liste alle verfügbaren Stacks auf."""
    config = load_stack_config()
    return list(config.get('stacks', {}).keys())


def ensure_layout() -> None:
    need_cmd("python3")
    need_cmd("vastai")
    if not MANAGE_SCRIPT.exists():
        raise VastError(f"Missing {MANAGE_SCRIPT.name} next to vast.py")
    # Lade Konfiguration
    load_stack_config()


# ---------- Vast CLI ----------

def _vast_api_key() -> str:
    """Read API key from ~/.config/vastai/vast_api_key or VASTAI_API_KEY env."""
    env_key = os.environ.get("VASTAI_API_KEY", "")
    if env_key:
        return env_key.strip()
    key_file = Path.home() / ".config" / "vastai" / "vast_api_key"
    if key_file.exists():
        return key_file.read_text().strip()
    # fallback: local .vastai_key
    local_key = SCRIPT_DIR / ".vastai_key"
    if local_key.exists():
        return local_key.read_text().strip()
    raise VastError("No vastai API key found. Set VASTAI_API_KEY or create ~/.config/vastai/vast_api_key")


def _ensure_vastai_config() -> None:
    """Ensure API key is in ~/.config/vastai/vast_api_key for CLI to work."""
    api_key = _vast_api_key()
    config_dir = Path.home() / ".config" / "vastai"
    config_dir.mkdir(parents=True, exist_ok=True)
    key_file = config_dir / "vast_api_key"
    key_file.write_text(api_key)
    os.chmod(key_file, 0o600)


def search_offers_cli(
    gpu_regex: str,
    min_vram_mb: int,
    max_dph: float,
    limit: int = 50,
) -> list[dict]:
    """
    Search offers via vastai CLI - returns valid ask IDs for create.
    Query syntax: 'field op value' mit quotes.
    gpu_ram ist in GB!
    """
    import re as _re
    
    # gpu_ram in GB umrechnen (API gibt GB zurück)
    min_vram_gb = min_vram_mb / 1024.0
    
    # Query für CLI: gpu_name regex, min_vram, max_dph, rentable
    query = f'rentable=True dph_total<{max_dph} gpu_ram>={min_vram_gb:.1f} num_gpus=1'
    
    # CLI command
    cmd = [
        "vastai", "search", "offers",
        query,
        "--limit", str(limit),
        "--raw",
        "-o", "dph_total",  # Sort by price ascending
    ]
    
    info(f"Search query: {query}")
    cp = run(cmd, check=False, capture=True)
    raw = cp.stdout.strip()
    
    if cp.returncode != 0:
        raise VastError(f"Search failed: {cp.stderr}")
    
    try:
        data = json.loads(raw)
        offers = data if isinstance(data, list) else data.get("offers", [])
        
        # Filter by GPU regex (client-side)
        pattern = _re.compile(gpu_regex, _re.IGNORECASE)
        filtered = [o for o in offers if pattern.search(o.get("gpu_name", ""))]
        
        # Sort by dph
        filtered.sort(key=lambda x: float(x.get("dph_total") or x.get("dph") or 999))
        
        # Debug: erste 3 Angebote loggen
        if filtered:
            info(f"Found {len(filtered)} offers. Top offer: id={filtered[0].get('ask_contract_id')}, gpu={filtered[0].get('gpu_name')}, dph={filtered[0].get('dph_total')}")
        
        return filtered
    except json.JSONDecodeError as e:
        raise VastError(f"Search output not JSON: {raw[:200]}") from e


def search_offers_api(
    gpu_regex: str,
    min_vram_gb: float,
    max_dph: float,
    num_gpus: int = 1,
    rentable_only: bool = True,
    limit: int = 100,
) -> list[dict]:
    """
    Search Vast.ai offers via REST API directly (avoids CLI parser bugs with >=, <, ~ operators).
    Filters by GPU name regex, minimum VRAM (GB), and maximum price (dph).
    Returns list of offer dicts sorted by dph ascending.
    """
    import urllib.request
    import re as _re

    api_key = _vast_api_key()
    url = f"https://console.vast.ai/api/v0/bundles/?order=dph_total&type=on-demand&limit={limit}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {api_key}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
    except Exception as exc:
        raise VastError(f"vastai API request failed: {exc}") from exc

    offers = data.get("offers", [])
    pattern = _re.compile(gpu_regex, _re.IGNORECASE)
    result = []
    for o in offers:
        gpu = o.get("gpu_name", "")
        vram_mb = float(o.get("gpu_ram") or 0)
        vram_gb = vram_mb / 1024.0
        dph = float(o.get("dph_total") or o.get("dph") or 999)
        ng = int(o.get("num_gpus") or 0)
        rented = bool(o.get("rented"))
        rentable = bool(o.get("rentable"))
        # Apply filters
        if not pattern.search(gpu):
            continue
        if vram_gb < min_vram_gb:
            continue
        if dph >= max_dph:
            continue
        if ng != num_gpus:
            continue
        if rentable_only and rented:
            continue
        result.append(o)
    result.sort(key=lambda x: float(x.get("dph_total") or x.get("dph") or 999))
    return result


def vast_json(args: list[str]) -> Any:
    """Execute vastai command via CLI (requires ~/.config/vastai/vast_api_key)."""
    _ensure_vastai_config()
    cp = run(["vastai", *args, "--raw"], capture=True)
    raw = cp.stdout.strip()
    if not raw:
        return []
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise VastError(f"Could not parse vastai output for {' '.join(args)}: {raw[:400]}") from exc


def list_instances() -> list[Instance]:
    data = vast_json(["show", "instances"])
    if not isinstance(data, list):
        raise VastError("Unexpected vastai show instances output")
    items = [Instance.from_raw(x) for x in data]
    items.sort(key=lambda x: int(x.id or 0), reverse=True)
    return items


def get_instance(selector: str) -> Instance:
    selector = selector.strip()
    items = list_instances()
    if selector.isdigit():
        for inst in items:
            if inst.id == selector:
                return enrich_instance_with_canonical_ssh(inst)
        raise VastError(f"No instance with id {selector}")
    sel = selector.lower()
    if sel == "last" and items:
        return enrich_instance_with_canonical_ssh(items[0])
    for inst in items:
        hay = " ".join([inst.id, inst.label, inst.gpu_name, inst.ssh_host]).lower()
        if sel in hay:
            return enrich_instance_with_canonical_ssh(inst)
    raise VastError(f"Could not resolve instance selector: {selector}")


def print_instances(items: list[Instance]) -> None:
    if not items:
        warn("No Vast instances found.")
        return
    print(f"{'ID':<8} {'STATUS':<10} {'GPU':<18} {'$/h':<8} {'SSH':<28} LABEL")
    print("-" * 100)
    for inst in items:
        ssh = f"{inst.ssh_host}:{inst.ssh_port}" if inst.ssh_host and inst.ssh_port else "-"
        gpu = inst.gpu_name[:18]
        ssh_info = f" {inst.ssh_source}" if inst.ssh_source else ""
        print(f"{inst.id:<8} {inst.status:<10} {gpu:<18} {inst.dph_total:<8} {ssh:<28} {inst.label}{ssh_info}")


def instance_to_dict_extended(inst: Instance) -> dict:
    """
    Convert Instance to dict with extended SSH debug info.
    For use with --json flag to show SSH resolution details.
    """
    return {
        "id": inst.id,
        "label": inst.label,
        "gpu_name": inst.gpu_name,
        "status": inst.status,
        "ssh_host": inst.ssh_host,
        "ssh_port": inst.ssh_port,
        "ssh_source": inst.ssh_source,
        "ssh_resolution_error": inst.ssh_resolution_error,
        "public_ip": inst.public_ip,
        "dph_total": inst.dph_total,
        "cpu_cores": inst.cpu_cores,
        "gpu_ram": inst.gpu_ram,
    }


def vast_action(action: str, instance_id: str) -> None:
    run(["vastai", action, "instance", instance_id])


# ---------- State + Instance Resolution ----------

def load_stack_state(stack: str) -> Optional[Dict[str, str]]:
    """Load local state file for stack, return dict or None."""
    return load_state(stack)


def save_stack_state(stack: str, instance: Instance) -> Path:
    """Save instance data as state file."""
    return save_state(stack, instance)


def clear_stack_state(stack: str) -> bool:
    """Remove local state file, return True if removed."""
    sf = state_file(stack)
    if sf.exists():
        sf.unlink()
        return True
    return False


def get_saved_instance_id(stack: str) -> Optional[str]:
    """Return saved instance ID from state file, or None."""
    st = load_state(stack)
    return st.get("INSTANCE_ID") if st else None


def find_instance_by_id(instance_id: str) -> Optional[Instance]:
    """Find instance by ID among all Vast instances."""
    instances = list_instances()
    for inst in instances:
        if inst.id == instance_id:
            return enrich_instance_with_canonical_ssh(inst)
    return None


def resolve_stack_instance(stack: str) -> Tuple[Optional[Dict[str, str]], Optional[Instance]]:
    """
    Combine local state and remote instance data.
    Returns (state_dict, instance_obj).
    If state missing or instance not found, returns (None, None) or partial.
    
    If saved instance doesn't exist, tries to find a replacement.
    """
    state = load_state(stack)
    if not state:
        return None, None
    iid = state.get("INSTANCE_ID")
    if not iid:
        return state, None
    
    # Try to find saved instance
    inst = find_instance_by_id(iid)
    if inst:
        return state, inst

    return state, None


# ---------- Instance Status / Lifecycle ----------

def instance_exists(stack_or_id: str) -> bool:
    """Check if instance exists (either by stack state or direct ID)."""
    if stack_or_id in get_all_stacks():
        state = load_state(stack_or_id)
        if not state:
            return False
        iid = state.get("INSTANCE_ID")
        if not iid:
            return False
        stack_or_id = iid
    # assume it's an instance ID
    return find_instance_by_id(stack_or_id) is not None


def instance_is_running(stack_or_id: str) -> bool:
    """Check if instance is in 'running' status."""
    if stack_or_id in get_all_stacks():
        state = load_state(stack_or_id)
        if not state:
            return False
        iid = state.get("INSTANCE_ID")
        if not iid:
            return False
        stack_or_id = iid
    inst = find_instance_by_id(stack_or_id)
    return inst is not None and inst.status == "running"


def ensure_instance_running(stack: str) -> bool:
    """Start instance if stopped; return True if running afterwards."""
    state, inst = resolve_stack_instance(stack)
    if not state or not inst:
        return False
    if inst.status == "running":
        return True
    try:
        vast_action("start", inst.id)
        # wait a bit for status update
        time.sleep(5)
        # refresh instance
        new_inst = find_instance_by_id(inst.id)
        return new_inst is not None and new_inst.status == "running"
    except Exception:
        return False


def wait_for_instance_ssh(stack: str, timeout: int = 180, interval: int = 5) -> bool:
    """Wait until SSH is reachable."""
    state, inst = resolve_stack_instance(stack)
    if not state or not inst:
        return False
    ip = state.get("INSTANCE_IP")
    port = state.get("INSTANCE_PORT")
    if not ip or not port:
        return False
    start = time.time()
    while time.time() - start < timeout:
        if ssh_check_with_ip_port(ip, port):
            return True
        time.sleep(interval)
    return False


def wait_for_ssh_ready(inst: Instance, timeout: int = 180, interval: int = 5) -> bool:
    """Wait until SSH is reachable for given Instance object."""
    if not inst or not inst.ssh_host or not inst.ssh_port:
        return False
    
    start = time.time()
    last_status = "unknown"
    
    while time.time() - start < timeout:
        if ssh_check_with_ip_port(inst.ssh_host, inst.ssh_port):
            elapsed = int(time.time() - start)
            info(f"SSH ready after {elapsed}s")
            return True
        
        # Refresh instance status for better logging
        try:
            fresh_inst = find_instance_by_id(inst.id)
            if fresh_inst:
                current_status = fresh_inst.status
                if current_status != last_status:
                    info(f"Instanz Status: {current_status} ({int(time.time() - start)}s)")
                    last_status = current_status
        except Exception:
            pass
        
        time.sleep(interval)
    
    return False


def ssh_check_with_ip_port(ip: str, port: str) -> bool:
    """Quick SSH reachability test."""
    try:
        cp = run(["ssh", "-T", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5",
                  "-o", "LogLevel=ERROR",
                  "-o", "UserKnownHostsFile=/dev/null",
                  "-p", port, f"root@{ip}", "bash --noprofile --norc -lc 'echo test'"], check=False, capture=True)
        return cp.returncode == 0
    except Exception:
        return False


# ---------- SSH / Remote Checks ----------

def ssh_check(stack: str) -> bool:
    """Check SSH reachability for stack."""
    state = load_state(stack)
    if not state:
        return False
    ip = state.get("INSTANCE_IP")
    port = state.get("INSTANCE_PORT")
    if not ip or not port:
        return False
    return ssh_check_with_ip_port(ip, port)


def run_remote(stack: str, command: str, check: bool = False, capture_output: bool = True,
               timeout: Optional[int] = None) -> subprocess.CompletedProcess[str]:
    """Run command on remote instance via SSH."""
    state = load_state(stack)
    if not state:
        raise VastError(f"No state for stack {stack}")
    ip = state.get("INSTANCE_IP")
    port = state.get("INSTANCE_PORT")
    if not ip or not port:
        raise VastError(f"Missing IP/PORT in state for {stack}")
    remote_cmd = f"bash --noprofile --norc -lc {shlex.quote(command)}"
    ssh_cmd = ["ssh", "-T", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
               "-o", "LogLevel=ERROR", "-o", "UserKnownHostsFile=/dev/null",
               "-p", port, f"root@{ip}", remote_cmd]
    return run(ssh_cmd, check=check, capture=capture_output)


def remote_file_exists(stack: str, path: str) -> bool:
    """Check if file exists on remote."""
    cp = run_remote(stack, f"test -f {shlex.quote(path)}", check=False, capture_output=True)
    return cp.returncode == 0


def remote_dir_exists(stack: str, path: str) -> bool:
    """Check if directory exists on remote."""
    cp = run_remote(stack, f"test -d {shlex.quote(path)}", check=False, capture_output=True)
    return cp.returncode == 0


def remote_command_exists(stack: str, command_name: str) -> bool:
    """Check if command is available on remote."""
    cp = run_remote(stack, f"command -v {shlex.quote(command_name)}", check=False, capture_output=True)
    return cp.returncode == 0


def remote_port_open(stack: str, port: int) -> bool:
    """Check if TCP port is listening on remote (uses curl, always available)."""
    cp = run_remote(stack, f"curl -sf --connect-timeout 3 --max-time 5 http://127.0.0.1:{port}/ >/dev/null 2>&1 || curl -sf --connect-timeout 3 --max-time 5 http://127.0.0.1:{port}/health >/dev/null 2>&1", check=False, capture_output=True)
    return cp.returncode == 0


def remote_http_healthcheck(stack: str, url_or_port: Union[str, int], path: str = "/", timeout: int = 10) -> bool:
    """Check HTTP health via curl."""
    if isinstance(url_or_port, int):
        url = f"http://127.0.0.1:{url_or_port}{path}"
    else:
        url = url_or_port
    cmd = f"curl -s -f --max-time {timeout} {shlex.quote(url)} >/dev/null 2>&1"
    cp = run_remote(stack, cmd, check=False, capture_output=True)
    return cp.returncode == 0


# ---------- Doctor / Health Check ----------

def cmd_doctor(args) -> int:
    """
    Doctor-Befehl: Prüft lokalen und optional Remote-Zustand.
    """
    stack = getattr(args, 'stack', None)
    verbose = getattr(args, 'verbose', False)
    
    result = {
        "local": {
            "checks": {},
            "ok": True,
            "errors": []
        },
        "remote": None
    }
    
    # Lokale Checks
    info("Prüfe lokale Umgebung...")
    
    # Python3
    if shutil.which("python3"):
        result["local"]["checks"]["python3"] = "ok"
    else:
        result["local"]["checks"]["python3"] = "missing"
        result["local"]["ok"] = False
        result["local"]["errors"].append("python3 nicht gefunden")
    
    # jq
    if shutil.which("jq"):
        result["local"]["checks"]["jq"] = "ok"
    else:
        result["local"]["checks"]["jq"] = "missing"
        result["local"]["ok"] = False
        result["local"]["errors"].append("jq nicht gefunden")
    
    # ssh
    if shutil.which("ssh"):
        result["local"]["checks"]["ssh"] = "ok"
    else:
        result["local"]["checks"]["ssh"] = "missing"
        result["local"]["ok"] = False
        result["local"]["errors"].append("ssh nicht gefunden")
    
    # vastai CLI
    if shutil.which("vastai"):
        result["local"]["checks"]["vastai"] = "ok"
    else:
        result["local"]["checks"]["vastai"] = "missing"
        result["local"]["ok"] = False
        result["local"]["errors"].append("vastai CLI nicht gefunden")
    
    # stacks.yaml
    if STACKS_YAML.exists():
        result["local"]["checks"]["stacks.yaml"] = "ok"
    else:
        result["local"]["checks"]["stacks.yaml"] = "missing"
        result["local"]["ok"] = False
        result["local"]["errors"].append("stacks.yaml nicht gefunden")
    
    # PyYAML
    try:
        import yaml
        result["local"]["checks"]["pyyaml"] = "ok"
    except ImportError:
        result["local"]["checks"]["pyyaml"] = "missing"
        result["local"]["ok"] = False
        result["local"]["errors"].append("PyYAML nicht installiert")
    
    # State-Dateien
    states = {}
    for s in get_all_stacks():
        sf = state_file(s)
        states[s] = sf.exists()
    result["local"]["checks"]["state_files"] = states
    
    # Port-Konflikte lokal
    port_conflicts = []
    for s in get_all_stacks():
        config = get_stack_config(s)
        local_port = config.get("local_port")
        if local_port and not is_local_port_free(local_port):
            port_conflicts.append(f"{s}: Port {local_port} belegt")
    if port_conflicts:
        result["local"]["checks"]["port_conflicts"] = port_conflicts
    else:
        result["local"]["checks"]["port_conflicts"] = "none"
    
    # Remote-Checks falls Stack angegeben
    if stack:
        info(f"Prüfe Remote-Zustand für {stack}...")
        state, inst = resolve_stack_instance(stack)
        remote_result = {
            "stack": stack,
            "state_exists": state is not None,
            "instance_exists": inst is not None,
            "checks": {}
        }
        
        if state and inst:
            # Manifest
            remote_result["checks"]["manifest"] = manifest_exists(stack)
            
            # Health
            health = stack_health(stack)
            remote_result["checks"]["ready"] = health.get("ready", False)
            remote_result["checks"]["ssh_reachable"] = health.get("ssh_reachable", False)
            remote_result["checks"]["service_port_open"] = health.get("checks", {}).get("service_port_open", False)
            remote_result["checks"]["http_health_ok"] = health.get("checks", {}).get("http_health_ok", False)
            remote_result["missing"] = health.get("missing", [])
        else:
            remote_result["error"] = "Kein State oder Instanz gefunden"
        
        result["remote"] = remote_result
    
    # Output
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(c("╔════════════════════════════════════════════════════════╗", "36"))
        print(c("║  DOCTOR - Lokale Umgebung                              ║", "36"))
        print(c("╚════════════════════════════════════════════════════════╝", "36"))
        
        for check, status in result["local"]["checks"].items():
            if isinstance(status, dict):
                print(f"  {check}:")
                for k, v in status.items():
                    icon = c("✓", "32") if v else c("✗", "31")
                    print(f"    {k}: {icon}")
            elif isinstance(status, list):
                if status:
                    print(f"  {check}: {c(', '.join(status), '33')}")
                else:
                    print(f"  {check}: {c('keine', '32')}")
            else:
                icon = c("✓", "32") if status == "ok" or status == "none" else c("✗", "31")
                print(f"  {check}: {icon} ({status})")
        
        if result["local"]["errors"]:
            print(c("\nFehler:", "31"))
            for err in result["local"]["errors"]:
                print(f"  - {err}")
        
        if result["remote"]:
            print(c("\n╔════════════════════════════════════════════════════════╗", "36"))
            print(c(f"║  DOCTOR - Remote ({stack})                               ║", "36"))
            print(c("╚════════════════════════════════════════════════════════╝", "36"))
            
            remote = result["remote"]
            for key, value in remote.items():
                if key == "checks":
                    for ck, cv in value.items():
                        icon = c("✓", "32") if cv else c("✗", "31")
                        print(f"  {ck}: {icon}")
                elif key == "missing" and value:
                    print(c(f"  Fehlend: {', '.join(value)}", "33"))
                elif key not in ("checks", "missing"):
                    print(f"  {key}: {value}")
    
    return 0 if result["local"]["ok"] else 1


def write_manifest(stack: str, template: str, service_port: int) -> Dict[str, Any]:
    """Schreibe Manifest auf Remote-Instanz."""
    config = get_stack_config(stack)
    manifest = {
        "manifest_version": 1,
        "stack": stack,
        "template": template,
        "service_port": service_port,
        "model": config.get("default_model", ""),
        "model_file_hint": config.get("model_file_hint", ""),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }
    
    # Upload manifest via Python script on remote
    manifest_json = json.dumps(manifest, indent=2)
    remote_cmd = f"echo {shlex.quote(manifest_json)} > {MANIFEST_PATH}"
    cp = run_remote(stack, remote_cmd, check=False)
    if cp.returncode != 0:
        raise VastError(f"Failed to write manifest: {cp.stderr}")
    return manifest


def read_manifest(stack: str) -> Optional[Dict[str, Any]]:
    """Lese Manifest von Remote-Instanz."""
    try:
        cp = run_remote(stack, f"cat {MANIFEST_PATH}", check=True, capture_output=True)
        return json.loads(cp.stdout)
    except Exception:
        return None


def manifest_exists(stack: str) -> bool:
    """Prüfe ob Manifest auf Remote existiert."""
    return remote_file_exists(stack, MANIFEST_PATH)


# ---------- Stack Health ----------

def stack_health(stack: str) -> Dict[str, Any]:
    """Comprehensive health check for a stack."""
    config = get_stack_config(stack)
    state, inst = resolve_stack_instance(stack)
    
    result: Dict[str, Any] = {
        "stack": stack,
        "state_file_exists": state is not None,
        "instance_id": state.get("INSTANCE_ID") if state else None,
        "instance_exists": inst is not None,
        "instance_status": inst.status if inst else None,
        "ssh_reachable": False,
        "manifest_exists": False,
        "checks": {},
        "ready": False,
        "missing": [],
        "suggested_actions": [],
    }
    
    # If no state file, stop early
    if not state:
        result["missing"].append("state file")
        result["suggested_actions"].append("rent a new instance")
        return result
    
    # If no instance
    if not inst:
        result["missing"].append("remote instance (maybe deleted)")
        result["suggested_actions"].append("clear state and rent new")
        return result
    
    # Instance running?
    if inst.status != "running":
        result["missing"].append(f"instance not running (status: {inst.status})")
        result["suggested_actions"].append("start instance")
        return result
    
    # SSH reachable
    ssh_ok = ssh_check(stack)
    result["ssh_reachable"] = ssh_ok
    if not ssh_ok:
        result["missing"].append("SSH not reachable")
        result["suggested_actions"].append("check network, maybe resume instance")
        return result
    
    # Manifest vorhanden?
    manifest_ok = manifest_exists(stack)
    result["manifest_exists"] = manifest_ok
    if not manifest_ok:
        result["missing"].append("manifest not found")
        result["suggested_actions"].append("rerun setup")
    else:
        manifest = read_manifest(stack) or {}
        desired_model = str(config.get("default_model", "") or "")
        desired_hint = str(config.get("model_file_hint", "") or "")
        actual_model = str(manifest.get("model", "") or "")
        actual_hint = str(manifest.get("model_file_hint", "") or "")
        model_match = (actual_model == desired_model) and (actual_hint == desired_hint)
        result["checks"]["manifest_model"] = {
            "expected_model": desired_model,
            "expected_model_file_hint": desired_hint,
            "actual_model": actual_model,
            "actual_model_file_hint": actual_hint,
            "match": model_match,
        }
        if not model_match:
            result["missing"].append("model mismatch")
            result["suggested_actions"].append("rerun setup to apply current model")

    if stack in {"text", "text_pro"}:
        desired_hint = str(config.get("model_file_hint", "") or "")
        current_files: List[str] = []
        onstart_model_path = ""
        try:
            cp = run_remote(
                stack,
                f"find /opt/models/{shlex.quote(stack)} -maxdepth 5 -type f \\( -name '*.gguf' -o -name '*.gguf.part*' \\) -printf '%f\\n' 2>/dev/null | sort",
                check=False,
                capture_output=True,
            )
            if cp.stdout:
                current_files = [line.strip() for line in cp.stdout.splitlines() if line.strip()]
        except Exception:
            current_files = []

        try:
            cp = run_remote(
                stack,
                "grep -oP '^MODEL_PATH=\"\\K[^\"]+' /onstart.sh 2>/dev/null || true",
                check=False,
                capture_output=True,
            )
            onstart_model_path = (cp.stdout or "").strip()
        except Exception:
            onstart_model_path = ""

        desired_present = any(desired_hint in name for name in current_files) if desired_hint else bool(current_files)
        onstart_match = desired_hint in os.path.basename(onstart_model_path) if desired_hint and onstart_model_path else False
        result["checks"]["remote_model_files"] = current_files
        result["checks"]["onstart_model_path"] = onstart_model_path
        result["checks"]["remote_model_match"] = {
            "desired_hint": desired_hint,
            "desired_present": desired_present,
            "onstart_match": onstart_match,
        }
        if desired_hint and (not desired_present or not onstart_match):
            if "model mismatch" not in result["missing"]:
                result["missing"].append("model mismatch")
            if "rerun setup to apply current model" not in result["suggested_actions"]:
                result["suggested_actions"].append("rerun setup to apply current model")
    
    # Required files
    required_files = config.get("required_files", [])
    file_checks = {}
    for f in required_files:
        exists = remote_file_exists(stack, f)
        file_checks[f] = exists
        if not exists:
            result["missing"].append(f"missing file: {f}")
    result["checks"]["required_files"] = file_checks
    
    # Required commands
    required_commands = config.get("required_commands", [])
    cmd_checks = {}
    for cmd in required_commands:
        exists = remote_command_exists(stack, cmd)
        cmd_checks[cmd] = exists
        if not exists:
            result["missing"].append(f"missing command: {cmd}")
    result["checks"]["required_commands"] = cmd_checks
    
    # Service port open
    port = config.get("service_port")
    port_open = False
    if port:
        port_open = remote_port_open(stack, port)
        result["checks"]["service_port_open"] = port_open
        if not port_open:
            result["missing"].append(f"service port {port} not open")
    
    # HTTP health
    health_ok = False
    if port and port_open:
        health_path = config.get("health_path", "/")
        health_ok = remote_http_healthcheck(stack, port, health_path, 10)
        result["checks"]["http_health_ok"] = health_ok
        if not health_ok:
            result["missing"].append("http health check failed")
    
    # Determine overall readiness
    missing = result["missing"]
    if not missing:
        result["ready"] = True
        result["suggested_actions"].append("ready to use")
    else:
        if "state file" not in missing and "remote instance" not in missing and "instance not running" not in missing and "SSH not reachable" not in missing:
            result["suggested_actions"].append("rerun setup")
            result["suggested_actions"].append("rerun start")
    
    return result


def get_stack_health_json(stack: str) -> str:
    """Return stack health as JSON string, suitable for shell consumption."""
    return json.dumps(stack_health(stack), separators=(',', ':'))


# ---------- Port Utilities ----------

def is_local_port_free(port: int) -> bool:
    """Check if local TCP port is free."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(1)
            s.bind(('', port))
            return True
    except OSError:
        return False


def find_next_free_local_port(start_port: int, max_tries: int = 100) -> Optional[int]:
    """Find next free local port, starting from start_port."""
    for offset in range(max_tries):
        port = start_port + offset
        if is_local_port_free(port):
            return port
    return None


# ---------- SSH / sync ----------

def ssh_target(inst: Instance) -> str:
    if not inst.ssh_host or not inst.ssh_port:
        raise VastError(f"Instance {inst.id} has no SSH host/port yet")
    return f"root@{inst.ssh_host}"


def ssh_base(inst: Instance) -> list[str]:
    return [
        "ssh",
        "-o", "StrictHostKeyChecking=no",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=6",
        "-p", inst.ssh_port,
        ssh_target(inst),
    ]


def scp_base(inst: Instance) -> list[str]:
    return [
        "scp",
        "-o", "StrictHostKeyChecking=no",
        "-P", inst.ssh_port,
    ]


def rsync_base(inst: Instance) -> list[str]:
    cmd = [
        "rsync",
        "-az",
        "-vv",  # Verbose output
        "--info=progress2",
        "-e",
        f"ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p {inst.ssh_port}",
    ]
    info(f"rsync target: {ssh_target(inst)}")
    return cmd


def run_ssh(inst: Instance, remote_cmd: str) -> None:
    info(f"SSH command: {' '.join(ssh_base(inst))} {remote_cmd[:50]}")
    run([*ssh_base(inst), remote_cmd])


def open_shell(inst: Instance) -> None:
    os.execvp("ssh", ssh_base(inst))


def sync_to(inst: Instance, src: Path, dest: str, delete: bool = False) -> None:
    if not src.exists():
        raise VastError(f"Source does not exist: {src}")
    
    info(f"Sync: {src} -> {ssh_target(inst)}:{dest}")
    info(f"SSH Host: {inst.ssh_host}, Port: {inst.ssh_port}")
    
    # Test SSH connection first
    info("Testing SSH connection...")
    try:
        test_cmd = ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "ConnectTimeout=5", "-p", inst.ssh_port, ssh_target(inst), "echo SSH_OK"]
        info(f"SSH test: {' '.join(test_cmd)}")
        cp = run(test_cmd, check=False, capture=True)
        if cp.returncode == 0 and "SSH_OK" in cp.stdout:
            info("SSH connection test: OK")
        else:
            warn(f"SSH connection test failed: returncode={cp.returncode}")
            warn(f"STDOUT: {cp.stdout[:200]}")
            warn(f"STDERR: {cp.stderr[:200]}")
    except Exception as e:
        warn(f"SSH test exception: {e}")

    if shutil.which("rsync"):
        cmd = rsync_base(inst)
        if delete:
            cmd.append("--delete")
        if src.is_dir():
            cmd.extend([str(src) + "/", f"{ssh_target(inst)}:{dest.rstrip('/')}/"])
        else:
            cmd.extend([str(src), f"{ssh_target(inst)}:{dest}"])
        info(f"rsync command: {' '.join(cmd)}")
        try:
            run(cmd)
            info("rsync completed successfully")
        except Exception as e:
            err(f"rsync failed: {e}")
            raise
        return
    warn("rsync not found, falling back to scp")
    if src.is_dir():
        run_ssh(inst, f"mkdir -p {shlex.quote(dest)}")
        run([*scp_base(inst), "-r", str(src), f"{ssh_target(inst)}:{dest}"])
    else:
        run([*scp_base(inst), str(src), f"{ssh_target(inst)}:{dest}"])


def upload_ssh_key(inst: Instance) -> None:
    """
    Upload local SSH public key to remote instance's authorized_keys.
    Enables passwordless SSH for rsync/scp operations.
    """
    # Find local public key
    local_pub_key = Path.home() / ".ssh" / "id_rsa.pub"
    if not local_pub_key.exists():
        local_pub_key = Path.home() / ".ssh" / "id_ed25519.pub"
    
    if not local_pub_key.exists():
        warn("No local SSH public key found. Skipping upload.")
        return
    
    pub_key_content = local_pub_key.read_text().strip()
    if not pub_key_content:
        warn("SSH public key is empty. Skipping upload.")
        return
    
    info("Uploading SSH public key to remote instance...")
    
    # Create .ssh directory and authorized_keys on remote
    remote_cmd = (
        f"mkdir -p ~/.ssh && "
        f"chmod 700 ~/.ssh && "
        f"grep -qF {shlex.quote(pub_key_content)} ~/.ssh/authorized_keys 2>/dev/null || "
        f"echo {shlex.quote(pub_key_content)} >> ~/.ssh/authorized_keys && "
        f"chmod 600 ~/.ssh/authorized_keys"
    )
    
    try:
        # Use run_remote which works for jupyter instances via SSH port
        cp = run_remote_by_ip(
            inst.ssh_host,
            inst.ssh_port,
            remote_cmd,
            check=False,
            capture_output=True
        )
        if cp.returncode == 0:
            info("SSH public key uploaded successfully.")
        else:
            warn(f"SSH key upload returned {cp.returncode}, but continuing...")
    except Exception as e:
        warn(f"SSH key upload failed: {e}. Remote operations may fail.")


def run_remote_by_ip(ip: str, port: str, command: str, check: bool = False, 
                     capture_output: bool = False) -> subprocess.CompletedProcess[str]:
    """Run command on remote instance by IP:port (for jupyter instances)."""
    remote_cmd = f"bash --noprofile --norc -lc {shlex.quote(command)}"
    ssh_cmd = [
        "ssh", "-T", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
        "-o", "LogLevel=ERROR", "-o", "UserKnownHostsFile=/dev/null",
        "-p", port, f"root@{ip}", remote_cmd
    ]
    return run(ssh_cmd, check=check, capture=capture_output)


def sync_from(inst: Instance, src: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if shutil.which("rsync"):
        cmd = rsync_base(inst)
        cmd.extend([f"{ssh_target(inst)}:{src}", str(dest)])
        run(cmd)
        return
    warn("rsync not found, falling back to scp")
    run([*scp_base(inst), f"{ssh_target(inst)}:{src}", str(dest)])


# ---------- stack orchestration ----------

def manage(*args: str) -> None:
    run([str(MANAGE_SCRIPT), *args])


def stack_up(stack: str) -> None:
    st = load_state(stack)
    if st:
        ok(f"Stack {stack} already has local state: {st.get('INSTANCE_ID')}")
        return
    manage("rent", stack)
    manage("setup", stack)
    manage("start", stack)


def stack_open(stack: str) -> None:
    os.execv(str(MANAGE_SCRIPT), [str(MANAGE_SCRIPT), "login", stack])


def stack_attach(stack: str, selector: str) -> None:
    inst = get_instance(selector)
    sf = save_state(stack, inst)
    ok(f"Saved {sf.name}: {inst.id} -> {inst.ssh_host}:{inst.ssh_port}")


# ---------- menu ----------

def prompt(text: str, default: str | None = None) -> str:
    suffix = f" [{default}]" if default else ""
    raw = input(f"{text}{suffix}: ").strip()
    return raw or (default or "")


def choose_instance() -> Instance:
    items = list_instances()
    if not items:
        raise VastError("No instances found")
    print(f"{'#':<3} {'ID':<8} {'STATUS':<10} {'GPU':<18} {'$/h':<8} {'SSH':<28} LABEL")
    print("-" * 100)
    for idx, inst in enumerate(items, 1):
        ssh = f"{inst.ssh_host}:{inst.ssh_port}" if inst.ssh_host and inst.ssh_port else "-"
        gpu = inst.gpu_name[:18]
        print(f"{idx:<3} {inst.id:<8} {inst.status:<10} {gpu:<18} {inst.dph_total:<8} {ssh:<28} {inst.label}")
    print()
    sel = prompt("Instance #, id, or selector (1, 2, 3, last, ...)", "last").strip()
    if sel.isdigit():
        idx = int(sel)
        if 1 <= idx <= len(items):
            return items[idx - 1]
    return get_instance(sel)


def pause() -> None:
    input("\nEnter drücken zum Weiter... ")


def menu_instances() -> None:
    while True:
        os.system("clear >/dev/null 2>&1 || true")
        print(c("Vast Instanzen", "1"))
        print()
        print_instances(list_instances())
        print()
        print("1) Aktualisiere...")
        print("2) Starten")
        print("3) Stoppen")
        print("4) Zerstören")
        print("5) SSH öffnen")
        print("6) Befehl auf Instanz ausführen")
        print("7) Beliebige Dateien hochladen")
        print("8) Beliebige Dateien herunterladen")
        print("b) Zurück")
        choice = input("> ").strip().lower()
        try:
            if choice == "1":
                continue
            if choice == "2":
                inst = choose_instance()
                vast_action("start", inst.id)
                ok(f"Instance {inst.id} started")
                pause()
            elif choice == "3":
                inst = choose_instance()
                vast_action("stop", inst.id)
                ok(f"Instance {inst.id} stopped")
                pause()
            elif choice == "4":
                inst = choose_instance()
                confirm = prompt(f"Destroy instance {inst.id}? type YES")
                if confirm == "YES":
                    vast_action("destroy", inst.id)
                    ok(f"Instance {inst.id} destroyed")
                else:
                    warn("Aborted")
                pause()
            elif choice == "5":
                open_shell(choose_instance())
            elif choice == "6":
                inst = choose_instance()
                cmd = prompt("Remote command", "nvidia-smi")
                run_ssh(inst, cmd)
                pause()
            elif choice == "7":
                inst = choose_instance()
                src = Path(prompt("Lokaler Pfad", str(Path.cwd())))
                dest = prompt("Remote Ziel", "/root/")
                delete = prompt("delete beim rsync? (y/N)", "N").lower() == "y"
                sync_to(inst, src, dest, delete=delete)
                pause()
            elif choice == "8":
                inst = choose_instance()
                src = prompt("Remote Quelle", "/root/")
                dest = Path(prompt("Lokales Ziel", str(Path.cwd())))
                sync_from(inst, src, dest)
                pause()
            elif choice in {"b", "back"}:
                return
        except Exception as exc:
            err(str(exc))
            pause()


def menu_stacks() -> None:
    while True:
        os.system("clear >/dev/null 2>&1 || true")
        print(c("Stack Verwaltung", "1"))
        print()
        for stack in get_all_stacks():
            st = load_state(stack)
            target = f"{st.get('INSTANCE_ID')} @ {st.get('INSTANCE_IP')}:{st.get('INSTANCE_PORT')}" if st else "keine lokale Instanz"
            print(f"- {stack:<5} -> {target}")
        print()
        print("1) Stack automatisch hochfahren")
        print("2) Stack UI/Tunnel öffnen")
        print("3) setup auf Stack erneut ausführen")
        print("4) start auf Stack erneut ausführen")
        print("5) State aufräumen")
        print("6) Remote zerstören + State aufräumen")
        print("b) Zurück")
        choice = input("> ").strip().lower()
        try:
            if choice == "1":
                stack = prompt("Stack", "text")
                stack_up(stack)
                pause()
            elif choice == "2":
                stack = prompt("Stack", "text")
                stack_open(stack)
            elif choice == "3":
                stack = prompt("Stack", "text")
                manage("setup", stack)
                pause()
            elif choice == "4":
                stack = prompt("Stack", "text")
                manage("start", stack)
                pause()
            elif choice == "5":
                stack = prompt("Stack", "text")
                manage("delete", stack)
                pause()
            elif choice == "6":
                stack = prompt("Stack", "text")
                manage("delete", stack, "--remote")
                pause()
            elif choice in {"b", "back"}:
                return
        except Exception as exc:
            err(str(exc))
            pause()


def interactive_menu() -> None:
    ensure_layout()
    while True:
        os.system("clear >/dev/null 2>&1 || true")
        print(c("Vast Commander", "1"))
        print()
        print("1) Instanzen verwalten")
        print("2) Stacks verwalten")
        print("3) Instanzen anzeigen")
        print("q) Beenden")
        choice = input("> ").strip().lower()
        if choice == "1":
            menu_instances()
        elif choice == "2":
            menu_stacks()
        elif choice == "3":
            print_instances(list_instances())
            pause()
        elif choice == "q":
            return


# ---------- CLI Commands ----------

def cmd_resolve(args) -> int:
    """
    Resolve stack instance - returns SSH connection info.
    Uses resolve_instance_ssh() for accurate port determination.
    """
    stack = args.stack
    state, inst = resolve_stack_instance(stack)
    
    if not state:
        if args.json:
            print(json.dumps({"stack": stack, "error": "No state file", "ssh_host": None, "ssh_port": None}))
        else:
            print(f"No state for {stack}")
        return 1
    
    if not inst:
        if args.json:
            print(json.dumps({"stack": stack, "error": "Instance not found", "ssh_host": None, "ssh_port": None}))
        else:
            print(f"Instance not found for {stack}")
        return 1
    
    # Get fresh instance data from API and resolve SSH
    try:
        instances = list_instances()
        for fresh_inst in instances:
            if fresh_inst.id == inst.id:
                # Use the fresh instance with resolved SSH info
                inst = enrich_instance_with_canonical_ssh(fresh_inst)
                break
    except Exception:
        pass
    
    if args.json:
        out = {
            "stack": stack,
            "state": state,
            "ssh_host": inst.ssh_host,
            "ssh_port": inst.ssh_port,
            "ssh_source": inst.ssh_source,
            "ssh_resolution_error": inst.ssh_resolution_error,
            "instance_id": inst.id,
            "instance_status": inst.status,
        }
        print(json.dumps(out, indent=2))
    else:
        print(f"Stack: {stack}")
        print(f"Instance: {inst.id} ({inst.status})")
        print(f"SSH: {inst.ssh_host}:{inst.ssh_port} (source: {inst.ssh_source})")
        if inst.ssh_resolution_error:
            print(f"Error: {inst.ssh_resolution_error}")
    return 0


def cmd_health(args) -> int:
    """Stack health check."""
    health = stack_health(args.stack)
    if args.json:
        print(json.dumps(health, indent=2))
    else:
        print(f"Stack: {health['stack']}")
        print(f"State file exists: {health['state_file_exists']}")
        print(f"Instance exists: {health['instance_exists']}")
        print(f"Instance status: {health['instance_status']}")
        print(f"SSH reachable: {health['ssh_reachable']}")
        print(f"Manifest exists: {health['manifest_exists']}")
        print(f"Ready: {health['ready']}")
        if health['missing']:
            print("Missing:")
            for m in health['missing']:
                print(f"  - {m}")
        if health['suggested_actions']:
            print("Suggested actions:")
            for a in health['suggested_actions']:
                print(f"  - {a}")
    return 0 if health['ready'] else 1


def cmd_ssh_check(args) -> int:
    """SSH reachability test."""
    ok = ssh_check(args.stack)
    if args.json:
        print(json.dumps({"ssh_reachable": ok}, indent=2))
    else:
        print("SSH reachable" if ok else "SSH not reachable")
    return 0 if ok else 1


def cmd_remote_file_exists(args) -> int:
    """Check remote file."""
    exists = remote_file_exists(args.stack, args.path)
    if args.json:
        print(json.dumps({"exists": exists}, indent=2))
    else:
        print("exists" if exists else "not exists")
    return 0 if exists else 1


def cmd_remote_port_open(args) -> int:
    """Check remote port."""
    try:
        port = int(args.port)
    except ValueError:
        err(f"Invalid port: {args.port}")
        return 1
    ok = remote_port_open(args.stack, port)
    if args.json:
        print(json.dumps({"port_open": ok}, indent=2))
    else:
        print("open" if ok else "closed")
    return 0 if ok else 1


def cmd_next_free_port(args) -> int:
    """Find next free local port."""
    try:
        start = int(args.start_port)
    except ValueError:
        err(f"Invalid start port: {args.start_port}")
        return 1
    port = find_next_free_local_port(start, args.max_tries)
    if port is None:
        if args.json:
            print(json.dumps({"free_port": None}, indent=2))
        else:
            print("no free port found")
        return 1
    if args.json:
        print(json.dumps({"free_port": port}, indent=2))
    else:
        print(port)
    return 0


def cmd_instance_status(args) -> int:
    """Check instance existence and running status."""
    exists = instance_exists(args.stack_or_id)
    running = instance_is_running(args.stack_or_id) if exists else False
    if args.json:
        print(json.dumps({"exists": exists, "running": running}, indent=2))
    else:
        print(f"exists: {exists}")
        print(f"running: {running}")
    return 0 if (exists and running) else 1


# ---------- Machine-ID Blacklist für Retry-Logik ----------
# Wird pro Laufzeit geführt, um fehlerhafte Maschinen zu überspringen
_BLACKLISTED_MACHINE_IDS: set[str] = set()


def get_local_ssh_public_key() -> str | None:
    """Get local SSH public key content."""
    local_pub_key = Path.home() / ".ssh" / "id_rsa.pub"
    if not local_pub_key.exists():
        local_pub_key = Path.home() / ".ssh" / "id_ed25519.pub"
    
    if not local_pub_key.exists():
        return None
    
    return local_pub_key.read_text().strip()


def create_instance_cli(
    offer_id: str,
    image: str,
    disk: int,
    runtype: str = "jupyter",
    label: str | None = None,
) -> dict:
    """
    Create instance via vastai CLI - entspricht WebUI RENT button.
    Fügt automatisch SSH-Key via --onstart-cmd hinzu.
    runtype: 'jupyter' oder 'ssh'
    """
    _ensure_vastai_config()
    
    # SSH-Key laden und als onstart-cmd hinzufügen
    ssh_pub_key = get_local_ssh_public_key()
    onstart_cmd = ""
    if ssh_pub_key:
        # SSH-Key in authorized_keys einfügen beim Start
        onstart_cmd = (
            f"mkdir -p /root/.ssh && "
            f"chmod 700 /root/.ssh && "
            f"echo '{ssh_pub_key}' >> /root/.ssh/authorized_keys && "
            f"chmod 600 /root/.ssh/authorized_keys"
        )
    
    # CLI Flags - ssh und jupyter sind mutually exclusive!
    cmd = [
        "vastai", "create", "instance", offer_id,
        "--image", image,
        "--disk", str(disk),
        "--cancel-unavail",
        "--raw",
    ]
    
    # Entweder --ssh ODER --jupyter (nicht beide!)
    if runtype == "jupyter":
        cmd.append("--jupyter")
    else:
        cmd.append("--ssh")
    
    # SSH-Key via onstart-cmd hinzufügen
    if onstart_cmd:
        cmd.extend(["--onstart-cmd", onstart_cmd])
    
    if label:
        cmd.extend(["--label", label])
    
    info(f"CLI Befehl: {' '.join(cmd)}")
    cp = run(cmd, check=False, capture=True)
    raw_output = cp.stdout.strip()
    raw_stderr = cp.stderr.strip() if cp.stderr else ""
    
    info(f"CLI STDOUT (full): {raw_output}")
    if raw_stderr:
        info(f"CLI STDERR (full): {raw_stderr}")
    
    # JSON ist im stdout nach dem explain output
    json_start = raw_output.rfind('{')
    if json_start >= 0:
        json_str = raw_output[json_start:]
    else:
        json_str = raw_output
    
    if cp.returncode != 0:
        raise VastError(f"CLI create failed (code={cp.returncode}): {raw_stderr}")
    
    try:
        result = json.loads(json_str)
        info(f"CLI Response: success={result.get('success')}, new_contract={result.get('new_contract')}")
        return result
    except json.JSONDecodeError as e:
        raise VastError(f"CLI output not JSON: {json_str[:200]}") from e


def get_daemon_logs(instance_id: str) -> str:
    """Hole Daemon-Logs einer Instanz zur Fehleranalyse."""
    try:
        cp = run(["vastai", "logs", "--daemon-logs", instance_id], check=False, capture=True)
        return cp.stdout.strip() + cp.stderr.strip()
    except Exception:
        return ""


def check_container_error(logs: str) -> bool:
    """Prüfe ob Logs auf Container-Fehler hinweisen (z. B. 'No such container')."""
    error_patterns = [
        "No such container",
        "container not found",
        "failed to create container",
        "image pull failed",
        "ErrImagePull",
        "ImagePullBackOff",
    ]
    return any(pattern.lower() in logs.lower() for pattern in error_patterns)


def destroy_instance_silent(instance_id: str) -> bool:
    """Destroy Instanz ohne Fehlerausgabe. Return True wenn erfolgreich."""
    try:
        run(["vastai", "destroy", "instance", instance_id], check=False, capture=True)
        return True
    except Exception:
        return False


def cmd_rent(args) -> int:
    """
    Miete neue Instanz für Stack via Vast.ai API.
    Entspricht exakt dem WebUI-Verhalten (Image, runtype, target_state).
    Mit Retry-Logik bei fehlerhaften Maschinen.
    """
    stack = args.stack
    config = get_stack_config(stack)

    # Konfiguration extrahieren
    template = config.get("vast_template")
    runtype = config.get("vast_runtype", "jupyter")
    target_state = config.get("vast_target_state", "running")
    cancel_unavail = config.get("vast_cancel_unavail", True)
    max_dph = config.get("max_dph", 99)
    min_vram_mb = config.get("min_vram_mb", 0)
    gpu_regex = config.get("gpu_regex", ".")
    min_vram_gb = min_vram_mb / 1024.0
    disk = args.disk or config.get("disk_gb", 100)

    info(f"Suche Angebot für {stack} (max ${max_dph}/h, min {min_vram_mb}MB VRAM, GPU: {gpu_regex})...")

    # CLI search verwenden - liefert valide ask IDs für create
    offers = search_offers_cli(
        gpu_regex=gpu_regex,
        min_vram_mb=min_vram_mb,
        max_dph=max_dph,
        limit=50,
    )

    if not offers:
        err("Keine passenden Angebote gefunden.")
        return 1

    # Filtere geblacklistete Angebote
    filtered_offers = [o for o in offers if str(o.get("machine_id")) not in _BLACKLISTED_MACHINE_IDS]
    if not filtered_offers:
        err("Alle Angebote sind geblacklistet. Reset mit neuem Suchlauf.")
        _BLACKLISTED_MACHINE_IDS.clear()
        filtered_offers = offers

    max_attempts = min(len(filtered_offers), 5)  # Max 5 Versuche
    attempt = 0

    while attempt < max_attempts:
        attempt += 1
        best = filtered_offers[attempt - 1]
        # ask_contract_id ist die ID für create instance (nicht bundle_id!)
        offer_id = str(best.get("ask_contract_id") or best.get("id", ""))
        machine_id = str(best.get("machine_id", ""))
        best_gpu = str(best.get("gpu_name", ""))
        best_dph = str(best.get("dph_total") or best.get("dph", "-"))

        print(f"\n{'='*50}")
        print(f"VERSUCH {attempt}/{max_attempts}")
        print(f"=== BESTES ANGEBOT ===")
        print(f"ID:    {offer_id}")
        print(f"Machine: {machine_id}")
        print(f"GPU:   {best_gpu}")
        print(f"Preis: ${best_dph}/h")
        print(f"Template: {template}")
        print(f"Runtype: {runtype}")
        print(f"Target: {target_state}")
        print(f"======================")
        print(f"{'='*50}\n")

        if not args.yes and attempt == 1:
            answer = input("Jetzt mieten? (y/N): ").strip()
            if answer.lower() != 'y':
                info("Abgebrochen.")
                return 0

        # Instanz via CLI erstellen (entspricht WebUI flow)
        info(f"Erstelle Instanz: image={template}, disk={disk}GB, runtype={runtype}")
        create_result = None
        
        try:
            create_result = create_instance_cli(
                offer_id=offer_id,
                image=template,
                disk=int(disk),
                runtype=runtype,
                label=f"{stack}-{offer_id}",
            )
            info("Erstellung via CLI erfolgreich.")
        except Exception as cli_exc:
            err(f"CLI fehlgeschlagen: {cli_exc}")
            create_result = None
        
        if not create_result:
            if attempt < max_attempts:
                info("Versuche nächstes Angebot...")
                time.sleep(2)
                continue
            return 1

        # Parse neue Instanz-ID
        new_id = str(create_result.get("new_contract") or create_result.get("id") or "")
        if not new_id:
            err(f"Keine Instanz-ID in Antwort: {create_result}")
            return 1

        create_success = create_result.get("success", True)

        # success=False bedeutet: Vast konnte das Image nicht laden/erstellen
        # Lösung: Instanz destroyen und nächstes Angebot versuchen
        if create_success is False:
            warn(f"Vast meldet success=false für Instanz {new_id} - Image wurde nicht korrekt geladen.")
            warn(f"Antwort: {create_result}")
            # Instanz bereinigen
            destroy_instance_silent(new_id)
            warn(f"Instanz {new_id} zerstört, versuche nächstes Angebot...")
            
            if attempt < max_attempts:
                time.sleep(1)
                continue
            else:
                err("Keine weiteren Angebote verfügbar.")
                return 1

        ok(f"Instanz {new_id} erstellt.")

        # Warte auf Instanz-Details mit präzisem Abbruch
        info("Warte auf Instanz-Details (kann 5-10 Min dauern bei großen Images)...")
        start_time = time.time()
        max_wait = 600  # 10 Minuten
        status = "unknown"
        ip = None
        port = None
        last_log_time = start_time

        while time.time() - start_time < max_wait:
            try:
                inst_info = find_instance_by_id(new_id)
                if inst_info:
                    status = inst_info.status
                    ip = inst_info.ssh_host
                    port = inst_info.ssh_port

                    if status == "running" and ip and port:
                        break

                    # Abbruch bei gestoppt/offline nach 30s
                    if status in {"stopped", "offline"} and time.time() - start_time > 30:
                        err(f"Instanz {new_id} ist nicht sauber hochgekommen (status={status}).")
                        destroy_instance_silent(new_id)
                        if attempt < max_attempts:
                            info("Versuche nächstes Angebot...")
                            time.sleep(2)
                            break
                        else:
                            return 1

                    # Status-Log alle 30s
                    elapsed = int(time.time() - start_time)
                    if elapsed - (last_log_time - start_time) >= 30:
                        info(f"Warte... Status: {status} ({elapsed}s)")
                        last_log_time = time.time()

                    # Bei loading/created ohne SSH nach 90s: Daemon-Logs prüfen
                    if elapsed > 90 and status in {"loading", "created"} and not ip:
                        info("Prüfe Daemon-Logs auf Fehler...")
                        logs = get_daemon_logs(new_id)
                        if check_container_error(logs):
                            err(f"Container-Fehler erkannt:")
                            for line in logs.splitlines()[-8:]:
                                err(f"  {line}")
                            destroy_instance_silent(new_id)
                            if machine_id:
                                _BLACKLISTED_MACHINE_IDS.add(machine_id)
                                info(f"Machine-ID {machine_id} geblacklistet.")
                            if attempt < max_attempts:
                                info("Versuche nächstes Angebot...")
                                time.sleep(2)
                                break
                            else:
                                err("Keine weiteren Angebote verfügbar.")
                                return 1
            except Exception as e:
                warn(f"Fehler bei Status-Abfrage: {e}")
            time.sleep(10)
        else:
            # Timeout durchlaufen
            if ip and port and status == "running":
                break
            # Timeout ohne Erfolg
            err(f"Timeout: Instanz {new_id} wurde nach {max_wait}s nicht running.")
            destroy_instance_silent(new_id)
            if attempt < max_attempts:
                info("Versuche nächstes Angebot...")
                time.sleep(2)
                continue
            return 1

        # Nach Warte-Schleife: Erfolg prüfen
        if ip and port and status == "running":
            break

        # Fehlerfall
        if attempt < max_attempts:
            warn(f"Instanz {new_id} nicht erfolgreich. Bereinige...")
            destroy_instance_silent(new_id)
            info("Versuche nächstes Angebot...")
            time.sleep(2)
            continue
        else:
            err("Instanz konnte nach mehreren Versuchen nicht gestartet werden.")
            return 1

    # Erfolg
    inst = Instance(
        id=new_id,
        label=f"{stack}-{new_id}",
        gpu_name=best_gpu,
        status=status,
        ssh_host=ip,
        ssh_port=port,
        public_ip=ip,
        dph_total=best_dph,
        cpu_cores="",
        gpu_ram="",
    )

    save_stack_state(stack, inst)
    ok(f"Instanz {new_id} gemietet und läuft.")
    print(f"\nNächste Schritte:")
    print(f"  python3 vast.py setup {stack}   # Setup durchführen")
    print(f"  python3 vast.py start {stack}   # Dienst starten")
    print(f"  python3 vast.py login {stack}   # Tunnel öffnen")

    return 0


def cmd_setup(args) -> int:
    """Führe Remote-Setup durch und schreibe Manifest. Wartet bis SSH bereit ist."""
    stack = args.stack
    config = get_stack_config(stack)

    state, inst = resolve_stack_instance(stack)
    if not state or not inst:
        err(f"Kein State oder Instanz für {stack} gefunden.")
        return 1

    # Warten bis SSH erreichbar ist
    info(f"Prüfe ob Instanz {inst.id} bereit für Setup...")
    info("Warte auf SSH-Verfügbarkeit (kann 1-2 Min dauern nach 'running')...")
    
    ssh_ready = wait_for_ssh_ready(inst, timeout=180)
    if not ssh_ready:
        err(f"Instanz {inst.id} ist nach 180s nicht via SSH erreichbar.")
        err("Tipp: Prüfe den Status in der Vast.ai WebUI oder versuche es später erneut.")
        return 1
    
    ok("SSH ist erreichbar, Instanz ist bereit für Setup.")

    # Ein konsistenter Setup-Pfad fuer alle Stacks.
    setup_script = SCRIPT_DIR / "setup_remote_v3.sh"

    if not setup_script.exists():
        err(f"Setup-Skript nicht gefunden: {setup_script}")
        return 1

    # Upload
    info(f"Lade {setup_script.name} hoch...")
    sync_to(inst, setup_script, "~/setup_remote.sh")
    image_app = SCRIPT_DIR / "ap_img2img.py"
    remote_image_app = ""
    if stack == "image" and image_app.exists():
        info(f"Lade {image_app.name} hoch...")
        sync_to(inst, image_app, "~/image_app.py")
        remote_image_app = "/root/image_app.py"

    # HF Token laden
    hf_token = _resolve_project_hf_token()

    # Stack Model
    stack_model = config.get("default_model", "")
    stack_model_file_hint = config.get("model_file_hint", "")
    stack_loras_json = json.dumps(config.get("loras", []))
    template = str(config.get("vast_template", ""))
    service_port = str(config.get("service_port", ""))

    # Remote ausführen
    info(f"Führe remote setup aus (Model: {stack_model or 'default'})...")
    remote_cmd = (
        f"chmod +x ~/setup_remote.sh && "
        f"STACK_TYPE={shlex.quote(stack)} "
        f"STACK_MODEL={shlex.quote(stack_model)} "
        f"STACK_MODEL_FILE_HINT={shlex.quote(str(stack_model_file_hint))} "
        f"STACK_TEMPLATE={shlex.quote(template)} "
        f"SERVICE_PORT={shlex.quote(service_port)} "
        f"FORCE_MODEL_REINSTALL={shlex.quote(str(os.environ.get('FORCE_MODEL_REINSTALL', '0')))} "
        f"HF_TOKEN={shlex.quote(hf_token)} "
        f"IMAGE_APP_SOURCE={shlex.quote(remote_image_app)} "
        f"IMAGE_LORAS_JSON={shlex.quote(stack_loras_json)} "
        f"bash ~/setup_remote.sh"
    )

    info("Live-Log vom Remote-Setup:")
    cp = run_remote(stack, remote_cmd, check=False, capture_output=False)
    if cp.returncode != 0:
        err("Remote setup fehlgeschlagen.")
        return 1

    # Manifest schreiben
    info("Schreibe Manifest...")
    write_manifest(stack, template, int(service_port))

    ok(f"Setup für {stack} abgeschlossen.")
    return 0


def cmd_start(args) -> int:
    """Starte Dienst auf Remote-Instanz."""
    stack = args.stack
    config = get_stack_config(stack)
    
    state, inst = resolve_stack_instance(stack)
    if not state or not inst:
        err(f"Kein State oder Instanz für {stack} gefunden.")
        return 1
    
    info(f"Starte Dienst für {stack}...")
    
    # Prüfe ob Port schon offen
    port = config.get("service_port")
    if remote_port_open(stack, port):
        ok(f"Dienst bereits auf Port {port} erreichbar.")
        return 0
    
    # /onstart.sh ausführen
    info("Führe /onstart.sh aus...")
    cp = run_remote(stack, "bash /onstart.sh", check=False)
    if cp.returncode != 0:
        warn("/onstart.sh konnte nicht ausgeführt werden.")
    
    # Warte auf Port
    info(f"Warte auf Dienst (Port {port})...")
    for i in range(60):
        if remote_port_open(stack, port):
            ok(f"Dienst auf Port {port} erreichbar.")
            return 0
        time.sleep(3)
    
    err(f"Dienst nach {60*3}s nicht erreichbar.")
    return 1


def cmd_go(args) -> int:
    """
    Smart Open / Go-Befehl: Macht alles automatisch fertig.

    Ablauf:
    1. Instanzstatus prüfen
    2. Falls nötig: mieten
    3. Falls nötig: starten
    4. SSH prüfen
    5. Health prüfen
    6. Falls Dienst fehlt: setup + start
    7. Tunnel öffnen
    8. Browser öffnen (optional)
    """
    stack = args.stack
    open_browser = getattr(args, 'open_browser', False)

    info(f"=== GO: {stack} ===")

    # 1. State laden
    state, inst = resolve_stack_instance(stack)

    if state and not inst:
        warn("State verweist auf keine existierende Instanz mehr. Bereinige State und miete neu...")
        clear_stack_state(stack)
        state = None

    if not state or not inst:
        info("Keine passende Stack-Instanz vorhanden, miete neue...")
        rent_result = cmd_rent(type('Args', (), {'stack': stack, 'yes': True, 'disk': None})())
        if rent_result != 0:
            err("Miete fehlgeschlagen.")
            return 1

        state, inst = resolve_stack_instance(stack)
        if not state or not inst:
            err("Instanz konnte nicht gemietet werden.")
            return 1

    # 2. Instanz starten falls nicht running
    if inst.status != "running":
        info(f"Instanz ist '{inst.status}', starte...")
        vast_action("start", inst.id)
        time.sleep(5)
        _, inst = resolve_stack_instance(stack)
        if not inst or inst.status != "running":
            err("Instanz konnte nicht gestartet werden.")
            return 1
        ok("Instanz läuft.")

    # 3. SSH prüfen
    info("Prüfe SSH...")
    if not ssh_check(stack):
        info("Warte auf SSH (bis zu 180s)...")
        if not wait_for_instance_ssh(stack, timeout=180):
            err("SSH nicht erreichbar.")
            return 1
    ok("SSH erreichbar.")

    # 4. Health prüfen
    info("Prüfe Health...")
    health = stack_health(stack)

    if health.get("ready"):
        ok("Stack ist bereit.")
    else:
        missing = health.get("missing", [])
        info(f"Stack nicht bereit: {', '.join(missing)}")
        
        # Setup + Start falls nötig
        if "manifest not found" in missing or "missing file" in str(missing):
            info("Führe Setup durch...")
            setup_result = cmd_setup(type('Args', (), {'stack': stack})())
            if setup_result != 0:
                err("Setup fehlgeschlagen.")
                return 1
        
        if "service port" in str(missing) or "http health" in str(missing):
            info("Starte Dienst...")
            start_result = cmd_start(type('Args', (), {'stack': stack})())
            if start_result != 0:
                err("Start fehlgeschlagen.")
                return 1
    
    # 5. Tunnel-Informationen anzeigen
    config = get_stack_config(stack)
    local_port = config.get("local_port", config.get("service_port"))
    service_port = config.get("service_port")
    api_tunnel_port = config.get("api_tunnel_port", config.get("ollama_tunnel_port"))
    
    ok(f"Tunnel bereit:")
    print(f"  Service: http://127.0.0.1:{local_port}")
    if api_tunnel_port:
        print(f"  API:     http://127.0.0.1:{api_tunnel_port}")
    
    # 6. Browser öffnen (optional)
    if open_browser:
        info("Öffne Browser...")
        import webbrowser
        url = f"http://127.0.0.1:{local_port}"
        webbrowser.open(url)
        ok(f"Browser geöffnet: {url}")
    else:
        info("Tunnel öffnen mit:")
        print(f"  python3 vast.py login {stack}")
        print(f"  Oder: ./manage_v7_fixed.sh login {stack}")
    
    return 0


def cmd_login(args) -> int:
    """Öffne SSH-Tunnel für Stack."""
    stack = args.stack
    config = get_stack_config(stack)

    state, inst = resolve_stack_instance(stack)
    if not state or not inst:
        err(f"Kein State oder Instanz für {stack} gefunden.")
        return 1

    local_port = config.get("local_port", config.get("service_port"))
    service_port = config.get("service_port")
    api_remote_port = config.get("api_remote_port", config.get("ollama_remote_port"))
    api_tunnel_port = config.get("api_tunnel_port", config.get("ollama_tunnel_port"))

    info(f"Öffne Tunnel für {stack} auf lokalem Port {local_port}...")

    # SSH Tunnel Command
    ssh_cmd = ["ssh", "-N",
               "-o", "StrictHostKeyChecking=no",
               "-o", "ServerAliveInterval=30",
               "-p", inst.ssh_port,
               f"root@{inst.ssh_host}"]

    # Local Port Forwarding
    ssh_cmd.extend(["-L", f"{local_port}:127.0.0.1:{service_port}"])

    # Zusatz-Tunnel für direkte API-Nutzung
    if api_remote_port and api_tunnel_port:
        ssh_cmd.extend(["-L", f"{api_tunnel_port}:127.0.0.1:{api_remote_port}"])

    os.execvp("ssh", ssh_cmd)


# ---------- CLI Parser ----------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Vast.ai Verwaltung mit zentraler Stack-Konfiguration")
    sub = p.add_subparsers(dest="cmd")

    sub.add_parser("menu", help="Interaktives Menü")
    
    list_parser = sub.add_parser("list", help="Instanzen anzeigen")
    list_parser.add_argument("--json", action="store_true")

    s = sub.add_parser("show", help="Einzelne Instanz anzeigen")
    s.add_argument("selector")

    for name in ("start", "stop", "destroy", "ssh"):
        sp = sub.add_parser(name, help=f"Instance {name}")
        sp.add_argument("selector")
        if name == "destroy":
            sp.add_argument("--yes", action="store_true")

    ex = sub.add_parser("exec", help="Befehl auf Instanz ausführen")
    ex.add_argument("selector")
    ex.add_argument("command", nargs=argparse.REMAINDER)

    up = sub.add_parser("upload", help="Dateien/Ordner zur Instanz hochladen")
    up.add_argument("selector")
    up.add_argument("src")
    up.add_argument("dest")
    up.add_argument("--delete", action="store_true")

    down = sub.add_parser("download", help="Dateien/Ordner von Instanz holen")
    down.add_argument("selector")
    down.add_argument("src")
    down.add_argument("dest")

    attach = sub.add_parser("attach", help="Stack an Instanz binden")
    attach.add_argument("stack")
    attach.add_argument("selector")

    stack = sub.add_parser("stack", help="Stack-Operationen")
    stack.add_argument("action", choices=["up", "open", "setup", "start", "status", "delete", "destroy"])
    stack.add_argument("stack")

    # New commands
    resolve = sub.add_parser("resolve", help="Resolve stack instance")
    resolve.add_argument("stack")
    resolve.add_argument("--json", action="store_true")

    health = sub.add_parser("health", help="Stack health check")
    health.add_argument("stack")
    health.add_argument("--json", action="store_true")

    ssh_check = sub.add_parser("ssh-check", help="SSH reachability test")
    ssh_check.add_argument("stack")
    ssh_check.add_argument("--json", action="store_true")

    remote_file = sub.add_parser("remote-file-exists", help="Check remote file")
    remote_file.add_argument("stack")
    remote_file.add_argument("path")
    remote_file.add_argument("--json", action="store_true")

    remote_port = sub.add_parser("remote-port-open", help="Check remote port")
    remote_port.add_argument("stack")
    remote_port.add_argument("port")
    remote_port.add_argument("--json", action="store_true")

    next_port = sub.add_parser("next-free-port", help="Find next free local port")
    next_port.add_argument("start_port")
    next_port.add_argument("--max-tries", type=int, default=100)
    next_port.add_argument("--json", action="store_true")

    inst_status = sub.add_parser("instance-status", help="Check instance existence and running")
    inst_status.add_argument("stack_or_id")
    inst_status.add_argument("--json", action="store_true")

    so = sub.add_parser("search-offers", help="Search Vast.ai offers")
    so.add_argument("--gpu-regex", default=".", help="GPU regex")
    so.add_argument("--min-vram", type=float, default=0, help="Min VRAM in GB")
    so.add_argument("--max-dph", type=float, default=99, help="Max price $/hr")
    so.add_argument("--num-gpus", type=int, default=1)
    so.add_argument("--limit", type=int, default=100)
    so.add_argument("--json", action="store_true")

    # Go command (Smart Open)
    go = sub.add_parser("go", help="Smart Open - macht alles automatisch fertig")
    go.add_argument("stack", help="Stack name")
    go.add_argument("--open", "-o", dest="open_browser", action="store_true", help="Browser automatisch öffnen")

    # Doctor command
    doctor = sub.add_parser("doctor", help="Diagnose: lokal und remote prüfen")
    doctor.add_argument("stack", nargs="?", help="Optional: Stack für Remote-Check")
    doctor.add_argument("--json", action="store_true")
    doctor.add_argument("--verbose", "-v", action="store_true")

    # Rent command
    rent = sub.add_parser("rent", help="Neue Instanz mieten")
    rent.add_argument("stack", help="Stack name")
    rent.add_argument("--yes", "-y", action="store_true", help="Ohne Nachfrage mieten")
    rent.add_argument("--disk", type=int, help="Disk size in GB")

    # Setup command
    setup = sub.add_parser("setup", help="Remote Setup durchführen")
    setup.add_argument("stack", help="Stack name")

    # Stack start command (different from instance start)
    stack_start = sub.add_parser("stack-start", help="Dienst für Stack starten")
    stack_start.add_argument("stack", help="Stack name")

    # Login command
    login = sub.add_parser("login", help="SSH Tunnel öffnen")
    login.add_argument("stack", help="Stack name")

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    cmd = args.cmd or "menu"

    try:
        ensure_layout()
        
        if cmd == "menu":
            interactive_menu()
        elif cmd == "list":
            if args.json:
                instances = list_instances()
                # Use extended dict with SSH resolution info
                print(json.dumps([instance_to_dict_extended(inst) for inst in instances], indent=2))
            else:
                print_instances(list_instances())
        elif cmd == "show":
            inst = get_instance(args.selector)
            print(json.dumps(inst.__dict__, indent=2))
        elif cmd in {"start", "stop"}:
            inst = get_instance(args.selector)
            vast_action(cmd, inst.id)
            ok(f"Instance {inst.id} {cmd}ed")
        elif cmd == "destroy":
            inst = get_instance(args.selector)
            if not args.yes:
                raise VastError("Add --yes to destroy an instance")
            vast_action("destroy", inst.id)
            ok(f"Instance {inst.id} destroyed")
        elif cmd == "ssh":
            open_shell(get_instance(args.selector))
        elif cmd == "exec":
            if not args.command:
                raise VastError("Please provide a remote command after --")
            run_ssh(get_instance(args.selector), " ".join(shlex.quote(x) for x in args.command))
        elif cmd == "upload":
            sync_to(get_instance(args.selector), Path(args.src).expanduser(), args.dest, delete=args.delete)
        elif cmd == "download":
            sync_from(get_instance(args.selector), args.src, Path(args.dest).expanduser())
        elif cmd == "attach":
            stack_attach(args.stack, args.selector)
        elif cmd == "stack":
            if args.action == "up":
                stack_up(args.stack)
            elif args.action == "open":
                stack_open(args.stack)
            elif args.action == "setup":
                manage("setup", args.stack)
            elif args.action == "start":
                manage("start", args.stack)
            elif args.action == "status":
                manage("status", args.stack)
            elif args.action == "delete":
                manage("delete", args.stack)
            elif args.action == "destroy":
                manage("delete", args.stack, "--remote")
        # New command handlers
        elif cmd == "resolve":
            return cmd_resolve(args)
        elif cmd == "health":
            return cmd_health(args)
        elif cmd == "ssh-check":
            return cmd_ssh_check(args)
        elif cmd == "remote-file-exists":
            return cmd_remote_file_exists(args)
        elif cmd == "remote-port-open":
            return cmd_remote_port_open(args)
        elif cmd == "next-free-port":
            return cmd_next_free_port(args)
        elif cmd == "instance-status":
            return cmd_instance_status(args)
        elif cmd == "search-offers":
            offers = search_offers_api(
                gpu_regex=args.gpu_regex,
                min_vram_gb=args.min_vram,
                max_dph=args.max_dph,
                num_gpus=args.num_gpus,
                limit=args.limit,
            )
            if args.json:
                print(json.dumps(offers, indent=2))
            else:
                print(json.dumps(offers, separators=(',', ':')))
            return 0
        elif cmd == "rent":
            return cmd_rent(args)
        elif cmd == "setup":
            return cmd_setup(args)
        elif cmd == "stack-start":
            return cmd_start(args)
        elif cmd == "login":
            return cmd_login(args)
        elif cmd == "go":
            return cmd_go(args)
        elif cmd == "doctor":
            return cmd_doctor(args)
        else:
            parser.print_help()
            return 1
        return 0
    except KeyboardInterrupt:
        err("Aborted")
        return 130
    except Exception as exc:
        err(str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
