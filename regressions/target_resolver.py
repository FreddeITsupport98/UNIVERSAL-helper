#!/usr/bin/env python3
from pathlib import Path


def resolve_target_script_path(base_file: str | Path) -> Path:
    repo_root = Path(base_file).resolve().parent.parent
    uni_path = repo_root / "UNI-auto.sh"
    if uni_path.is_file():
        return uni_path
    return repo_root / "zypper-auto.sh"
