"""Load authoritative source as an isolated installed-layout package, without deployment."""
import importlib.util
from pathlib import Path
import sys
import types

ROOT = Path(__file__).resolve().parents[1]
for name, path in [('usr.plugins.a0_notch', ROOT / 'plugin'),
                   ('usr.plugins.a0_notch.helpers', ROOT / 'plugin/helpers')]:
    module = types.ModuleType(name)
    module.__path__ = [str(path)]
    sys.modules[name] = module
