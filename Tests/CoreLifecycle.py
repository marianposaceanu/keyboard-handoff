"""Exercise the isolated fixture with the same CLI and socket as the application."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

with tempfile.TemporaryDirectory(dir="/tmp") as directory:
    env = dict(os.environ, HANDOFF_TEST_SOCKET=str(Path(directory) / "core.sock"))
    def run(*args):
        return subprocess.run([sys.argv[1], *args], env=env, capture_output=True, text=True, timeout=8)

    assert run("status").stdout.strip() == "The core is stopped."
    core = subprocess.Popen([sys.argv[1], "--serve"], env=env)
    try:
        for _ in range(80):
            result = run("status")
            if result.stdout.startswith("{"):
                break
            time.sleep(0.05)
        assert result.returncode == 0 and json.loads(result.stdout)["busy"] is False
        assert run("--serve").returncode == 1, "second core must refuse the existing lock"
        assert run("send").returncode == 1, "an unconfigured keyboard cannot be sent"
        assert run("unknown").returncode == 2
        assert run("stop").returncode == 0
        assert core.wait(timeout=5) == 0
        assert run("status").stdout.strip() == "The core is stopped."
    finally:
        if core.poll() is None:
            core.terminate()
            core.wait(timeout=5)
