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
DIRS = {"orbit-ops": "/opt/orbit-ops/backups", "job-hunt": "/opt/apply/backups"}
NAMES = {"orbit-ops": b"no Orbit Ops dump", "job-hunt": b"no Job Hunt dump"}


def test_the_forced_command_is_bound_to_the_pull_key():
    defaults = (ROLE / "defaults/main.yml").read_text()
    assert 'command="/usr/local/bin/backup-export",restrict,' in defaults
    assert "jupiter-backup" in defaults


def test_the_key_is_never_managed_exclusively():
    # Every tenant's deploy key is another line in the same file.
    assert "exclusive: false" in (ROLE / "tasks/main.yml").read_text()


@pytest.fixture
def export(tmp_path):
    """The real script with each tenant's dump folder moved under tmp_path."""
    script = tmp_path / "backup-export"
    text = (ROLE / "files/backup-export").read_text()
    run_dirs = {}
    for tenant, path in DIRS.items():
        assert text.count(path) == 2, tenant  # the glob and the error message
        run_dirs[tenant] = tmp_path / tenant
        run_dirs[tenant].mkdir()
        text = text.replace(path, str(run_dirs[tenant]))
    script.write_text(text)

    def run(command):
        env = {"PATH": os.environ["PATH"], "SSH_ORIGINAL_COMMAND": command}
        return subprocess.run(["sh", str(script)], env=env, capture_output=True, stdin=subprocess.DEVNULL)

    run.dirs = run_dirs
    return run


def _dump(directory, name, body, age):
    path = directory / name
    path.write_bytes(gzip.compress(body))
    stamp = 2_000_000_000 - age
    os.utime(path, (stamp, stamp))


@pytest.mark.parametrize("tenant", DIRS)
def test_no_dump_is_a_named_error(export, tenant):
    result = export(tenant)
    assert result.returncode == 1
    assert result.stdout == b""
    assert NAMES[tenant] in result.stderr


@pytest.mark.parametrize("tenant", DIRS)
def test_it_serves_the_newest_finished_dump(export, tenant):
    _dump(export.dirs[tenant], "pre-deploy-1.sql.gz", b"older", age=200)
    _dump(export.dirs[tenant], "nightly-2.sql.gz", b"newest", age=100)
    _dump(export.dirs[tenant], "nightly-3.sql.gz.partial", b"unfinished", age=0)
    result = export(tenant)
    assert result.returncode == 0, result.stderr
    assert gzip.decompress(result.stdout) == b"newest"


def test_each_tenant_gets_only_its_own_dump(export):
    _dump(export.dirs["orbit-ops"], "nightly-1.sql.gz", b"orbit", age=0)
    _dump(export.dirs["job-hunt"], "nightly-1.sql.gz", b"apply", age=50)
    assert gzip.decompress(export("orbit-ops").stdout) == b"orbit"
    assert gzip.decompress(export("job-hunt").stdout) == b"apply"


@pytest.mark.parametrize("command", [
    "orbit-ops /etc/shadow",
    "orbit-ops ../../etc/shadow",
    "orbit-ops; id",
    "ORBIT-OPS",
    "job-hunt /etc/shadow",
    "job-hunt; id",
    "JOB-HUNT",
    "apply",
    "cat /etc/shadow",
    "",
])
def test_nothing_but_the_exact_command_is_served(export, command):
    for directory in export.dirs.values():
        _dump(directory, "nightly-1.sql.gz", b"a dump", age=0)
    result = export(command)
    assert result.returncode == 1
    assert result.stdout == b""
    assert b"backup-export: refused" in result.stderr
