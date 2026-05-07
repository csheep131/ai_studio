"""
SSE streaming endpoints — stream subprocess output in real-time.
"""
from __future__ import annotations

import asyncio
import json
import os
import shlex
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Query, Request
from fastapi.responses import StreamingResponse

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
WORKFLOW_SCRIPT = PROJECT_ROOT / "video_script_full_workflow.sh"

router = APIRouter()


async def _stream_subprocess(cmd: list[str], cwd: str):
    """Yield SSE events from a running subprocess."""
    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        cwd=cwd,
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

        # Flush remaining buffer
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


@router.get("/logs")
async def stream_logs(
    request: Request,
    command: str = Query(..., description="Workflow command: init, validate, pilot, gen, stitch"),
    args: str = Query("", description="Space-separated arguments"),
):
    """Stream subprocess output as SSE events."""
    valid_commands = {"init", "validate", "pilot", "gen", "stitch", "status"}
    if command not in valid_commands:
        return StreamingResponse(
            iter([f"data: {json.dumps({'type': 'error', 'data': f'Invalid command: {command}'})}\n\n"]),
            media_type="text/event-stream",
        )

    cmd = ["bash", str(WORKFLOW_SCRIPT), command]
    if args.strip():
        cmd.extend(shlex.split(args))

    return StreamingResponse(
        _stream_subprocess(cmd, cwd=str(PROJECT_ROOT)),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )
