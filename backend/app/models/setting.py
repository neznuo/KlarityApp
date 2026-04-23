"""Setting ORM model — simple key/value store for app configuration."""

from __future__ import annotations

import base64
import hashlib
import platform
from datetime import datetime
from pathlib import Path

from cryptography.fernet import Fernet
from sqlalchemy import DateTime, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.database import Base


def _get_fernet() -> Fernet:
    """Return a Fernet instance keyed to the local machine."""
    if platform.system() == "Darwin":
        machine_id = Path("/etc/machine-id").read_text().strip() if Path("/etc/machine-id").exists() else "klarity-default-key"
    else:
        machine_id = Path("/etc/machine-id").read_text().strip() if Path("/etc/machine-id").exists() else "klarity-default-key"
    key = hashlib.sha256(machine_id.encode()).digest()[:32]
    key_b64 = base64.urlsafe_b64encode(key)
    return Fernet(key_b64)


def encrypt_value(value: str) -> str:
    """Encrypt a plaintext string for at-rest storage."""
    return _get_fernet().encrypt(value.encode()).decode()


def decrypt_value(value: str | None) -> str | None:
    """Decrypt a stored value; if decryption fails, assume plaintext and return as-is."""
    if not value:
        return value
    try:
        return _get_fernet().decrypt(value.encode()).decode()
    except Exception:
        return value


class Setting(Base):
    __tablename__ = "settings"

    key: Mapped[str] = mapped_column(String, primary_key=True)
    value: Mapped[str] = mapped_column(String, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=func.now(), onupdate=func.now(), nullable=False
    )
