"""Audio preprocessing service using FFmpeg."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


class AudioPreprocessor:
    """
    Wraps FFmpeg to normalize audio to 16 kHz mono WAV.
    Requires FFmpeg to be installed on the host system.
    """

    def preprocess(self, source_path: Path, output_path: Path) -> Path:
        """
        Convert source audio to 16 kHz mono WAV.
        Returns the output path.
        """
        if not shutil.which("ffmpeg"):
            raise RuntimeError("ffmpeg not found on PATH. Install FFmpeg to continue.")

        if not source_path.exists():
            raise FileNotFoundError(f"Source audio not found: {source_path}")

        output_path.parent.mkdir(parents=True, exist_ok=True)

        import json
        probe_cmd = [
            "ffprobe", "-v", "error", "-select_streams", "a",
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
            "ffmpeg",
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
            raise RuntimeError(
                f"FFmpeg preprocessing failed:\n{result.stderr}"
            )
        return output_path
