"""Sandbox-friendly scratch directory helpers for tests.

Some restricted sandboxes (e.g. the DSH file sandbox on Windows) hang or
deny file operations inside directories created by ``tempfile.mkdtemp``
(and therefore ``tempfile.TemporaryDirectory``). Tests that exercise code
which itself calls ``tempfile.mkstemp`` inside the scratch dir (such as
``webui.login_lock._write_state``) would hang forever there.

These helpers build scratch dirs with plain ``os.makedirs`` so the same
tests run unchanged on normal Windows/Linux machines and inside the
sandbox. No business code is involved.
"""

import os
import uuid
from pathlib import Path


def make_scratch_dir(base: Path | None = None) -> Path:
    path = (base or Path(os.environ.get("TMP", os.environ.get("TEMP", ".")))) / (
        "scratch-" + uuid.uuid4().hex
    )
    path.mkdir(parents=True)
    return path


def remove_scratch_dir(root: Path) -> None:
    """Remove a small scratch tree without shutil.rmtree."""
    for p in sorted(root.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if p.is_dir():
            p.rmdir()
        else:
            p.unlink()
    root.rmdir()
