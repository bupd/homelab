#!/usr/bin/env python3
import json
import os
import pathlib


path = pathlib.Path("/config/settings.json")
if not path.exists():
    raise SystemExit(0)

settings = json.loads(path.read_text())
settings.update(
    {
        "cache-size-mb": 16,
        "download-dir": "/data/downloads/complete",
        "download-queue-enabled": True,
        "download-queue-size": 20,
        "incomplete-dir": "/data/downloads/incomplete",
        "incomplete-dir-enabled": True,
        "peer-limit-global": 120,
        "peer-limit-per-torrent": 40,
        "preallocation": 0,
        "queue-stalled-enabled": True,
        "queue-stalled-minutes": 5,
        "speed-limit-down": 8192,
        "speed-limit-down-enabled": True,
    }
)

temporary = path.with_suffix(".json.tmp")
temporary.write_text(json.dumps(settings, indent=4, sort_keys=True) + "\n")
os.chmod(temporary, path.stat().st_mode)
temporary.replace(path)
