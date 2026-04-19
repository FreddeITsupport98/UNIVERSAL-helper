#!/usr/bin/env python3
import sys
from pathlib import Path

_REGRESSION_DIR = Path(__file__).resolve().parent
if str(_REGRESSION_DIR) not in sys.path:
    sys.path.insert(0, str(_REGRESSION_DIR))

from target_resolver import resolve_target_script_path as _resolve_target_script_path


def resolve_target_script_path(base_file: str | Path) -> Path:
    return _resolve_target_script_path(base_file)
