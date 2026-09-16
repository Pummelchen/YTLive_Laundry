#!/usr/bin/env python3
"""Test stub: prints the address in log/fake_cam_ip, or nothing."""
import os, pathlib, sys
base = pathlib.Path(os.environ.get("BASE", "/nonexistent"))
f = base / "log/fake_cam_ip"
if f.exists():
    print(f.read_text().strip())
    sys.exit(0)
sys.exit(1)
