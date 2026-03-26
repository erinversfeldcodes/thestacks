"""Verify that generated proto files are in sync with .proto sources.

Runs `scripts/gen_python_proto.py --check --language python` and asserts it
exits 0.  A non-zero exit means a .proto file has changed without the
generated Pydantic models being regenerated — fix by running:

    scripts/gen-python-proto.sh
"""

import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
GEN_SCRIPT = REPO_ROOT / "scripts" / "gen_python_proto.py"


def test_generated_python_proto_is_not_drifted() -> None:
    """Generated vision.py must match the current vision.proto."""
    result = subprocess.run(
        ["python3", str(GEN_SCRIPT), "--language", "python", "--check"],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    assert result.returncode == 0, (
        "Generated proto files are out of date.\n"
        f"Run: scripts/gen-python-proto.sh\n\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )
