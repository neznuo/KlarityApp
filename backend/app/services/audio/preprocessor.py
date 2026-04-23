"""Audio preprocessing service using FFmpeg."""

from __future__ import annotations
from typing import Optional

import json
import re
import shutil
import subprocess
from pathlib import Path

# Homebrew install locations that macOS GUI apps typically don't have in PATH.
_HOMEBREW_PATHS = ["/opt/homebrew/bin", "/usr/local/bin"]


def _find_tool(name: str) -> str:
    """
    Locate a CLI tool by checking PATH first, then common Homebrew directories.
    Returns the resolved path string, or raises RuntimeError if not found.
    """
    found = shutil.which(name)
    if found:
        return found
    for prefix in _HOMEBREW_PATHS:
        candidate = Path(prefix) / name
        if candidate.is_file():
            return str(candidate)
    raise RuntimeError(
        f"'{name}' not found on PATH or in {_HOMEBREW_PATHS}. "
        f"Install it with: brew install ffmpeg"
    )


def find_tool_or_none(name: str) -> Optional[str]:
    """Like _find_tool but returns None instead of raising — safe for health checks."""
    try:
        return _find_tool(name)
    except RuntimeError:
        return None


class AudioPreprocessor:
    """
    Wraps FFmpeg to normalize audio to 16 kHz mono WAV.
    Requires FFmpeg to be installed on the host system (brew install ffmpeg).
    """

    def preprocess(self, source_path: Path, output_path: Path) -> Path:
        """
        Convert source audio to 16 kHz mono WAV.
        Returns the output path.
        """
        ffmpeg = _find_tool("ffmpeg")
        ffprobe = _find_tool("ffprobe")

        if not source_path.exists():
            raise FileNotFoundError(f"Source audio not found: {source_path}")

        output_path.parent.mkdir(parents=True, exist_ok=True)

        probe_cmd = [
            ffprobe, "-v", "error", "-select_streams", "a",
            "-show_entries", "stream=index", "-of", "json", str(source_path)
        ]
        probe_result = subprocess.run(probe_cmd, capture_output=True, text=True)
        num_streams = 1
        if probe_result.returncode == 0:
            try:
                data = json.loads(probe_result.stdout)
                num_streams = len(data.get("streams", []))
            except json.JSONDecodeError:
                pass

        cmd = [
            ffmpeg,
            "-y",               # overwrite without prompt
            "-i", str(source_path),
        ]

        if num_streams > 1:
            # Mix all audio streams (e.g. Mic + System Audio) inside the M4A
            cmd.extend([
                "-filter_complex", f"amix=inputs={num_streams}:duration=longest,aresample=16000",
                "-ac", "1",
                "-sample_fmt", "s16"
            ])
        else:
            cmd.extend([
                "-ac", "1",
                "-ar", "16000",
                "-sample_fmt", "s16"
            ])

        cmd.append(str(output_path))
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            sanitized = re.sub(r"(?:/[^\s:]+)+", "<path>", result.stderr)
            raise RuntimeError(
                f"FFmpeg preprocessing failed:\n{sanitized}"
            )
        return output_path
