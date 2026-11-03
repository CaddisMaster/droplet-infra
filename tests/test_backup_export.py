"""backup-export, run for real with sh, and the key bound to it.

The script's paths are fixed on purpose, so a copy with the one directory replaced
runs here. infra/test.sh drives the real file over SSH on the VM. Moved from Budget
Buddy's tests/test_infra_app_roles.py (BB #532, #535).
"""
import gzip
import os
import subprocess
from pathlib import Path

import pytest

ROLE = Path(__file__).resolve().parent.parent / "infra/ansible/roles/droplet_export"
ORBIT_DIR = "/opt/orbit-ops/backups"


def test_the_forced_command_is_bound_to_the_pull_key():
    defaults = (ROLE / "defaults/main.yml").read_text()
    assert 'command="/usr/local/bin/backup-export",restrict,' in defaults
    assert "jupiter-backup" in defaults


def test_the_key_is_never_managed_exclusively():
    # Every tenant's deploy key is another line in the same file.
    assert "exclusive: false" in (ROLE / "tasks/main.yml").read_text()


@pytest.fixture
def export(tmp_path):
    backups = tmp_path / "backups"
    backups.mkdir()
    script = tmp_path / "backup-export"
    text = (ROLE / "files/backup-export").read_text()
    assert ORBIT_DIR in text
    script.write_text(text.replace(ORBIT_DIR, str(backups)))

    def run(command):
        env = {"PATH": os.environ["PATH"], "SSH_ORIGINAL_COMMAND": command}
        return subprocess.run(["sh", str(script)], env=env, capture_output=True, stdin=subprocess.DEVNULL)

    run.backups = backups
    return run


def _dump(directory, name, body, age):
    path = directory / name
    path.write_bytes(gzip.compress(body))
    stamp = 2_000_000_000 - age
    os.utime(path, (stamp, stamp))


def test_no_dump_is_a_named_error(export):
    result = export("orbit-ops")
    assert result.returncode == 1
    assert result.stdout == b""
    assert b"no Orbit Ops dump" in result.stderr


def test_it_serves_the_newest_finished_dump(export):
    _dump(export.backups, "pre-deploy-1.sql.gz", b"older", age=200)
    _dump(export.backups, "nightly-2.sql.gz", b"newest", age=100)
    _dump(export.backups, "nightly-3.sql.gz.partial", b"unfinished", age=0)
    result = export("orbit-ops")
    assert result.returncode == 0, result.stderr
    assert gzip.decompress(result.stdout) == b"newest"


@pytest.mark.parametrize("command", [
    "orbit-ops /etc/shadow",
    "orbit-ops ../../etc/shadow",
    "orbit-ops; id",
    "ORBIT-OPS",
    "cat /etc/shadow",
    "",
])
def test_nothing_but_the_exact_command_is_served(export, command):
    _dump(export.backups, "nightly-1.sql.gz", b"a dump", age=0)
    result = export(command)
    assert result.returncode == 1
    assert result.stdout == b""
    assert b"backup-export: refused" in result.stderr
