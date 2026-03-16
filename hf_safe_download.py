#!/usr/bin/env python3
"""
hf_safe_download.py - Safe HuggingFace Download Utilities

Prevents accidental large downloads by:
1. Creating download plans before downloading
2. Estimating total size before download
3. Enforcing size limits
4. Cleaning up incomplete downloads
5. Supporting dry-run and safe modes

Usage:
    python hf_safe_download.py --model black-forest-labs/FLUX.2-dev --dry-run
    python hf_safe_download.py --model stabilityai/stable-diffusion-xl-base-1.0 --safe-mode
    python hf_safe_download.py --model Wan-AI/Wan2.1-T2V-14B-Diffusers --max-size-gb 45
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

from huggingface_hub import HfApi, hf_hub_download, snapshot_download, login


# ── Configuration ──────────────────────────────────────────────────────────

DEFAULT_MAX_SIZE_GB = 40.0
SAFE_MODE_MAX_SIZE_GB = 1.0  # Only metadata in safe mode
DRY_RUN = False
SAFE_MODE = False
VERBOSE = False

# Model-specific configurations
MODEL_CONFIGS = {
    "black-forest-labs/FLUX.2-dev": {
        "max_size_gb": 50.0,
        "required_components": ["model_index", "scheduler", "text_encoder", "tokenizer", "transformer"],
        "optional_components": [],
        "excluded_components": ["vae", "image_encoder", "feature_extractor"],
        "description": "FLUX.2 Text-to-Image (NO VAE, NO image_encoder)",
    },
    "black-forest-labs/FLUX.1-dev": {
        "max_size_gb": 50.0,
        "required_components": ["model_index", "scheduler", "text_encoder", "tokenizer", "transformer"],
        "optional_components": [],
        "excluded_components": ["vae", "image_encoder", "feature_extractor"],
        "description": "FLUX.1 Text-to-Image (NO VAE, NO image_encoder)",
    },
    "stabilityai/stable-diffusion-xl-base-1.0": {
        "max_size_gb": 20.0,
        "required_components": ["model_index", "scheduler", "text_encoder", "text_encoder_2", 
                                "tokenizer", "tokenizer_2", "unet", "vae"],
        "optional_components": ["feature_extractor"],
        "excluded_components": [],
        "description": "SDXL Base",
    },
    "Wan-AI/Wan2.1-T2V-14B-Diffusers": {
        "max_size_gb": 45.0,
        "required_components": ["model_index", "scheduler", "tokenizer", "text_encoder", 
                                "text_encoder_2", "transformer", "vae"],
        "optional_components": ["feature_extractor", "image_encoder"],
        "excluded_components": [],
        "description": "Wan2.1 Text-to-Video",
    },
    "Wan-AI/Wan2.1-I2V-14B-720P-Diffusers": {
        "max_size_gb": 45.0,
        "required_components": ["model_index", "scheduler", "tokenizer", "text_encoder",
                                "transformer", "vae", "image_encoder"],
        "optional_components": ["feature_extractor"],
        "excluded_components": [],
        "description": "Wan2.1 Image-to-Video",
    },
}

# File patterns for each component
COMPONENT_PATTERNS = {
    "model_index": ["model_index.json"],
    "scheduler": ["scheduler/*.json"],
    "text_encoder": ["text_encoder/*.safetensors", "text_encoder/*.json"],
    "text_encoder_2": ["text_encoder_2/*.safetensors", "text_encoder_2/*.json"],
    "tokenizer": ["tokenizer/*.json", "tokenizer/*.txt"],
    "tokenizer_2": ["tokenizer_2/*.json", "tokenizer_2/*.txt"],
    "transformer": ["transformer/*.safetensors", "transformer/*.json"],
    "unet": ["unet/*.safetensors", "unet/*.json"],
    "vae": ["vae/*.safetensors", "vae/*.json"],
    "image_encoder": ["image_encoder/*.safetensors", "image_encoder/*.json"],
    "feature_extractor": ["feature_extractor/*.json"],
}


# ── Data Classes ───────────────────────────────────────────────────────────

@dataclass
class FileInfo:
    """Information about a single file in the repo."""
    path: str
    size: int
    component: str
    
    @property
    def size_mb(self) -> float:
        return self.size / (1024 * 1024)
    
    @property
    def size_gb(self) -> float:
        return self.size / (1024 * 1024 * 1024)


@dataclass
class DownloadPlan:
    """Complete download plan for a model."""
    model_id: str
    target_dir: str
    files: List[FileInfo] = field(default_factory=list)
    total_size_bytes: int = 0
    max_size_gb: float = DEFAULT_MAX_SIZE_GB
    excluded_files: List[str] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)
    
    @property
    def total_size_gb(self) -> float:
        return self.total_size_bytes / (1024 * 1024 * 1024)
    
    @property
    def total_size_mb(self) -> float:
        return self.total_size_bytes / (1024 * 1024)
    
    @property
    def file_count(self) -> int:
        return len(self.files)
    
    def fits_within_limit(self) -> bool:
        return self.total_size_bytes <= (self.max_size_gb * 1024 * 1024 * 1024)
    
    def get_summary(self) -> Dict[str, Any]:
        """Get summary for logging/JSON output."""
        component_sizes: Dict[str, int] = {}
        for f in self.files:
            component_sizes[f.component] = component_sizes.get(f.component, 0) + f.size
        
        return {
            "model_id": self.model_id,
            "target_dir": self.target_dir,
            "file_count": self.file_count,
            "total_size_gb": round(self.total_size_gb, 2),
            "total_size_mb": round(self.total_size_mb, 2),
            "max_size_gb": self.max_size_gb,
            "fits_within_limit": self.fits_within_limit(),
            "components": {k: round(v / (1024*1024), 2) for k, v in component_sizes.items()},
            "excluded_count": len(self.excluded_files),
            "warning_count": len(self.warnings),
        }


# ── Helper Functions ───────────────────────────────────────────────────────

def log(msg: str, level: str = "INFO") -> None:
    """Log message with timestamp and level."""
    timestamp = time.strftime("%H:%M:%S")
    prefix = {
        "INFO": "▶",
        "WARN": "⚠",
        "ERROR": "✗",
        "SUCCESS": "✓",
    }.get(level, "•")
    
    print(f"{prefix} [{timestamp}] {msg}", file=sys.stderr if level == "ERROR" else sys.stdout)


def get_hf_api(token: Optional[str] = None) -> HfApi:
    """Get authenticated HuggingFace API client."""
    # Only use token if it's non-empty
    if token and token.strip():
        token = token.strip()
        try:
            login(token=token, add_to_git_credential=False, skip_if_logged_in=False)
        except Exception as e:
            # Log warning but continue - many repos work without auth
            log(f"Token invalid, continuing without auth: {e}", "WARN")
            return HfApi(token=None)
    return HfApi(token=None)


def list_repo_files(api: HfApi, model_id: str) -> List[str]:
    """List all files in a model repo."""
    try:
        files = api.list_repo_files(model_id)
        return sorted(files)
    except Exception as e:
        log(f"Failed to list repo files: {e}", "ERROR")
        raise


def get_file_size(api: HfApi, model_id: str, file_path: str, revision: str = "main") -> int:
    """Get size of a single file in bytes."""
    try:
        info = api.get_paths_info(model_id, [file_path], revision=revision)
        if info and len(info) > 0:
            return getattr(info[0], 'size', 0)
        return 0
    except Exception:
        return 0


def identify_component(file_path: str) -> str:
    """Identify which component a file belongs to."""
    path_parts = file_path.split('/')
    if len(path_parts) > 0:
        root_dir = path_parts[0]
        # Map common directory names to components
        component_map = {
            "scheduler": "scheduler",
            "text_encoder": "text_encoder",
            "text_encoder_2": "text_encoder_2",
            "tokenizer": "tokenizer",
            "tokenizer_2": "tokenizer_2",
            "transformer": "transformer",
            "unet": "unet",
            "vae": "vae",
            "image_encoder": "image_encoder",
            "feature_extractor": "feature_extractor",
        }
        return component_map.get(root_dir, "other")
    return "other"


def matches_pattern(file_path: str, pattern: str) -> bool:
    """Check if file path matches a glob pattern."""
    import fnmatch
    return fnmatch.fnmatch(file_path, pattern)


def build_download_plan(
    model_id: str,
    target_dir: str,
    token: Optional[str] = None,
    max_size_gb: Optional[float] = None,
    safe_mode: bool = False,
    components: Optional[List[str]] = None,
) -> DownloadPlan:
    """
    Build a download plan without downloading anything.
    
    Args:
        model_id: HuggingFace model repo ID
        target_dir: Local directory to download to
        token: HuggingFace API token
        max_size_gb: Maximum allowed download size in GB
        safe_mode: If True, only download metadata (no large weights)
        components: Specific components to download (None = use model config)
    
    Returns:
        DownloadPlan with file list and size estimates
    """
    global SAFE_MODE
    SAFE_MODE = safe_mode
    
    log(f"Building download plan for: {model_id}")
    
    # Get model config
    config = MODEL_CONFIGS.get(model_id, {})
    effective_max_size = max_size_gb or config.get("max_size_gb", DEFAULT_MAX_SIZE_GB)
    
    if safe_mode:
        effective_max_size = SAFE_MODE_MAX_SIZE_GB
        log(f"SAFE MODE: Limited to {effective_max_size}GB (metadata only)", "WARN")
    
    # Get API client
    api = get_hf_api(token)
    
    # List all repo files
    log("Fetching file list from HuggingFace...")
    all_files = list_repo_files(api, model_id)
    log(f"Found {len(all_files)} files in repo")
    
    # Determine which components to include
    if components:
        required_components = components
        excluded_components = []
    else:
        required_components = config.get("required_components", [])
        excluded_components = config.get("excluded_components", [])
    
    log(f"Required components: {required_components}")
    if excluded_components:
        log(f"Excluded components: {excluded_components}", "WARN")
    
    # Build file patterns
    allowed_patterns = []
    for comp in required_components:
        patterns = COMPONENT_PATTERNS.get(comp, [])
        allowed_patterns.extend(patterns)
    
    # Also always include model_index.json
    if "model_index.json" not in allowed_patterns:
        allowed_patterns.append("model_index.json")
    
    # Filter files matching allowed patterns
    plan = DownloadPlan(
        model_id=model_id,
        target_dir=target_dir,
        max_size_gb=effective_max_size,
    )
    
    for file_path in all_files:
        # Check if file matches any allowed pattern
        is_allowed = any(matches_pattern(file_path, pattern) for pattern in allowed_patterns)
        
        # Check if file is in excluded component
        component = identify_component(file_path)
        is_excluded = component in excluded_components
        
        # In safe mode, exclude large weight files
        if safe_mode and file_path.endswith(".safetensors"):
            is_allowed = False
            plan.warnings.append(f"Safe mode: excluding {file_path}")
        
        if is_excluded:
            plan.excluded_files.append(file_path)
            continue
        
        if not is_allowed:
            plan.excluded_files.append(file_path)
            continue
        
        # Get file size
        size = get_file_size(api, model_id, file_path)
        
        file_info = FileInfo(
            path=file_path,
            size=size,
            component=component,
        )
        plan.files.append(file_info)
        plan.total_size_bytes += size
    
    # Add warnings
    if plan.total_size_bytes > (effective_max_size * 1024 * 1024 * 1024):
        plan.warnings.append(
            f"Download size ({plan.total_size_gb:.2f}GB) exceeds limit ({effective_max_size}GB)"
        )
    
    log(f"Download plan: {plan.file_count} files, {plan.total_size_gb:.2f}GB")
    
    return plan


def validate_model_dir(target_dir: str, model_id: str) -> Tuple[bool, str]:
    """
    Validate if a model directory is complete and valid.
    
    Returns:
        (is_valid, reason)
    """
    target_path = Path(target_dir)
    
    if not target_path.exists():
        return False, "Directory does not exist"
    
    if not target_path.is_dir():
        return False, "Path exists but is not a directory"
    
    # Check for model_index.json (essential for diffusers models)
    model_index = target_path / "model_index.json"
    if not model_index.exists():
        return False, "Missing model_index.json (incomplete download)"
    
    # Check if model_index.json is valid JSON
    try:
        with open(model_index, 'r') as f:
            data = json.load(f)
        if not data:
            return False, "model_index.json is empty"
    except json.JSONDecodeError as e:
        return False, f"model_index.json is invalid: {e}"
    
    # Check for essential subdirectories based on model
    config = MODEL_CONFIGS.get(model_id, {})
    required_components = config.get("required_components", [])
    
    for comp in required_components:
        if comp == "model_index":
            continue
        
        # Check if component directory exists and has files
        comp_dir = target_path / comp
        if comp_dir.exists():
            # Check if directory has actual files (not just empty)
            comp_files = list(comp_dir.glob("*"))
            if not comp_files:
                return False, f"Component {comp} directory is empty (incomplete download)"
    
    return True, "Model directory is valid"


def cleanup_partial_model_dir(target_dir: str, keep_metadata: bool = False) -> bool:
    """
    Clean up a partial/incomplete model directory.
    
    Args:
        target_dir: Directory to clean up
        keep_metadata: If True, keep model_index.json and scheduler
    
    Returns:
        True if cleanup was successful
    """
    target_path = Path(target_dir)
    
    if not target_path.exists():
        return True
    
    log(f"Cleaning up partial download: {target_dir}")
    
    if keep_metadata:
        # Keep only metadata files
        files_to_keep = ["model_index.json"]
        dirs_to_keep = ["scheduler"]
        
        for item in target_path.iterdir():
            if item.name in files_to_keep:
                continue
            if item.is_dir() and item.name in dirs_to_keep:
                continue
            try:
                if item.is_dir():
                    shutil.rmtree(item)
                else:
                    item.unlink()
                log(f"  Removed: {item.name}")
            except Exception as e:
                log(f"  Failed to remove {item.name}: {e}", "WARN")
    else:
        # Remove everything
        try:
            shutil.rmtree(target_path)
            log("  Removed entire directory")
        except Exception as e:
            log(f"Failed to cleanup: {e}", "ERROR")
            return False
    
    return True


def safe_hf_download_file(
    model_id: str,
    filename: str,
    local_dir: str,
    token: Optional[str] = None,
) -> str:
    """
    Safely download a single file from HuggingFace.
    
    Args:
        model_id: HuggingFace model repo ID
        filename: Specific file to download
        local_dir: Local directory to save to
        token: HuggingFace API token
    
    Returns:
        Path to downloaded file
    """
    log(f"Downloading single file: {filename}")
    
    try:
        local_path = hf_hub_download(
            repo_id=model_id,
            filename=filename,
            local_dir=local_dir,
            token=token,
        )
        log(f"✓ Downloaded: {filename}", "SUCCESS")
        return local_path
    except Exception as e:
        log(f"Failed to download {filename}: {e}", "ERROR")
        raise


def safe_snapshot_download(
    plan: DownloadPlan,
    token: Optional[str] = None,
    resume: bool = True,
) -> bool:
    """
    Execute a download based on a validated plan.
    
    Args:
        plan: DownloadPlan from build_download_plan()
        token: HuggingFace API token
        resume: If True, attempt to resume incomplete downloads
    
    Returns:
        True if download was successful
    """
    global DRY_RUN
    
    if DRY_RUN:
        log("DRY RUN: No files will be downloaded", "WARN")
        return True
    
    target_dir = Path(plan.target_dir)
    
    # Check if directory already exists and is valid
    is_valid, reason = validate_model_dir(str(target_dir), plan.model_id)
    
    if is_valid:
        log("Model directory already valid, skipping download")
        return True
    
    # Handle incomplete download
    if target_dir.exists():
        log(f"Existing download is incomplete: {reason}", "WARN")
        
        if resume:
            log("Attempting to resume download (will clean up corrupted files)")
            # Clean up but keep metadata
            cleanup_partial_model_dir(str(target_dir), keep_metadata=True)
        else:
            log("Full cleanup and redownload")
            cleanup_partial_model_dir(str(target_dir), keep_metadata=False)
    
    # Create target directory
    target_dir.mkdir(parents=True, exist_ok=True)
    
    # Check disk space
    try:
        total, used, free = shutil.disk_usage(str(target_dir))
        free_gb = free / (1024**3)
        required_gb = plan.total_size_gb * 1.2  # 20% buffer
        
        if free_gb < required_gb:
            log(f"Insufficient disk space: {free_gb:.1f}GB free, need {required_gb:.1f}GB", "ERROR")
            return False
        
        log(f"Disk space OK: {free_gb:.1f}GB free")
    except Exception as e:
        log(f"Could not check disk space: {e}", "WARN")
    
    # Extract file paths for snapshot_download
    allow_patterns = [f.path for f in plan.files]
    
    log(f"Starting download: {plan.file_count} files, {plan.total_size_gb:.2f}GB")
    log(f"Target: {target_dir}")
    
    try:
        snapshot_download(
            repo_id=plan.model_id,
            token=token,
            max_workers=4,
            local_dir=str(target_dir),
            allow_patterns=allow_patterns,
        )
        
        # Validate after download
        is_valid, reason = validate_model_dir(str(target_dir), plan.model_id)
        if is_valid:
            log("Download completed successfully", "SUCCESS")
            return True
        else:
            log(f"Download completed but validation failed: {reason}", "ERROR")
            return False
            
    except Exception as e:
        log(f"Download failed: {e}", "ERROR")
        # Clean up on failure
        cleanup_partial_model_dir(str(target_dir), keep_metadata=False)
        return False


# ── Main CLI ───────────────────────────────────────────────────────────────

def print_plan(plan: DownloadPlan, format: str = "text") -> None:
    """Print download plan in specified format."""
    summary = plan.get_summary()
    
    if format == "json":
        print(json.dumps(summary, indent=2))
        return
    
    # Text format
    print("\n" + "="*70)
    print(f"DOWNLOAD PLAN: {plan.model_id}")
    print("="*70)
    print(f"Target Directory: {plan.target_dir}")
    print(f"Max Size Limit: {plan.max_size_gb}GB")
    print(f"Total Files: {plan.file_count}")
    print(f"Total Size: {plan.total_size_gb:.2f}GB ({plan.total_size_mb:.0f}MB)")
    print(f"Fits Within Limit: {'YES ✓' if plan.fits_within_limit() else 'NO ✗'}")
    
    if plan.warnings:
        print(f"\nWarnings ({len(plan.warnings)}):")
        for w in plan.warnings:
            print(f"  ⚠ {w}")
    
    # Component breakdown
    component_sizes: Dict[str, int] = {}
    for f in plan.files:
        component_sizes[f.component] = component_sizes.get(f.component, 0) + f.size
    
    if component_sizes:
        print("\nComponent Breakdown:")
        for comp, size in sorted(component_sizes.items(), key=lambda x: -x[1]):
            size_mb = size / (1024*1024)
            pct = (size / plan.total_size_bytes * 100) if plan.total_size_bytes > 0 else 0
            print(f"  {comp:20s} {size_mb:8.1f}MB ({pct:5.1f}%)")
    
    # File list (first 20)
    if plan.files:
        print(f"\nFiles ({plan.file_count} total, showing first 20):")
        for f in plan.files[:20]:
            size_str = f"{f.size_mb:.1f}MB" if f.size_mb >= 1 else f"{f.size_mb*1024:.0f}KB"
            print(f"  {f.path:50s} {size_str:>10s}")
        if plan.file_count > 20:
            print(f"  ... and {plan.file_count - 20} more files")
    
    print("="*70 + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="Safe HuggingFace Download Utility",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Dry run - see what would be downloaded
  python hf_safe_download.py --model black-forest-labs/FLUX.2-dev --dry-run

  # Safe mode - only metadata, no large weights
  python hf_safe_download.py --model FLUX.2-dev --safe-mode

  # Download with size limit
  python hf_safe_download.py --model Wan2.1-T2V-14B --max-size-gb 40

  # Download specific components only
  python hf_safe_download.py --model SDXL --components text_encoder,tokenizer

  # JSON output for scripting
  python hf_safe_download.py --model FLUX.2-dev --dry-run --json
        """
    )
    
    parser.add_argument("--model", "-m", required=True, help="Model ID (e.g., black-forest-labs/FLUX.2-dev)")
    parser.add_argument("--output", "-o", default=None, help="Output directory")
    parser.add_argument("--token", "-t", default=None, help="HuggingFace API token")
    parser.add_argument("--max-size-gb", type=float, default=None, help="Maximum download size in GB")
    parser.add_argument("--dry-run", "-n", action="store_true", help="Show what would be downloaded, don't download")
    parser.add_argument("--safe-mode", "-s", action="store_true", help="Only download metadata (no large weights)")
    parser.add_argument("--components", "-c", default=None, help="Comma-separated list of components to download")
    parser.add_argument("--json", "-j", action="store_true", help="Output in JSON format")
    parser.add_argument("--verbose", "-v", action="store_true", help="Verbose output")
    parser.add_argument("--no-resume", action="store_true", help="Don't resume, always redownload")
    
    args = parser.parse_args()
    
    global DRY_RUN, SAFE_MODE, VERBOSE
    DRY_RUN = args.dry_run
    SAFE_MODE = args.safe_mode
    VERBOSE = args.verbose
    
    # Get token from env if not provided
    token = args.token or os.environ.get("HF_TOKEN") or os.environ.get("HUGGINGFACE_HUB_TOKEN")
    
    # Determine output directory
    if args.output:
        target_dir = args.output
    else:
        # Default based on model
        model_name = args.model.split("/")[-1]
        target_dir = f"/opt/models/{model_name}"
    
    # Parse components
    components = None
    if args.components:
        components = [c.strip() for c in args.components.split(",")]
    
    try:
        # Build download plan
        plan = build_download_plan(
            model_id=args.model,
            target_dir=target_dir,
            token=token,
            max_size_gb=args.max_size_gb,
            safe_mode=args.safe_mode,
            components=components,
        )
        
        # Print plan
        print_plan(plan, format="json" if args.json else "text")
        
        # Check if within limit
        if not plan.fits_within_limit():
            log(f"Download exceeds size limit! ({plan.total_size_gb:.2f}GB > {plan.max_size_gb}GB)", "ERROR")
            sys.exit(1)
        
        # If dry run, stop here
        if args.dry_run:
            log("Dry run complete. Use without --dry-run to actually download.", "INFO")
            sys.exit(0)
        
        # Execute download
        success = safe_snapshot_download(plan, token=token, resume=not args.no_resume)
        
        if success:
            log("Download completed successfully!", "SUCCESS")
            sys.exit(0)
        else:
            log("Download failed!", "ERROR")
            sys.exit(1)
            
    except Exception as e:
        log(f"Error: {e}", "ERROR")
        if VERBOSE:
            import traceback
            traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
