"""
Test for audio preprocessing service.
Requires FFmpeg installed on the host.
"""

import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock

from app.services.audio.preprocessor import AudioPreprocessor


def test_preprocessor_raises_without_ffmpeg():
    preprocessor = AudioPreprocessor()
    with patch("shutil.which", return_value=None):
        with pytest.raises(RuntimeError, match="ffmpeg not found"):
            preprocessor.preprocess(Path("/fake/input.wav"), Path("/fake/output.wav"))


def test_preprocessor_raises_if_source_missing(tmp_path):
    preprocessor = AudioPreprocessor()
    with patch("shutil.which", return_value="/usr/bin/ffmpeg"):
        with pytest.raises(FileNotFoundError):
            preprocessor.preprocess(tmp_path / "missing.wav", tmp_path / "out.wav")
