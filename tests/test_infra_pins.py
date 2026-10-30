"""#530 — the Ansible control node is pinned exactly, and in one place.

`infra/requirements-infra.txt` pins ansible-core and `infra/ansible/requirements.yml`
pins the collections. Orbit Ops pins this repo's host role by commit SHA
(orbit-ops #322), so a floating version here would make that SHA mean different
things on different days.

The same "one pin only" rule ruff follows (tests/test_lint_local.py): a second
ansible-core pin anywhere in the repo is a second answer to "which version?".

`infra/` is excluded from the image, so these skip there.
"""
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
INFRA = REPO_ROOT / "infra"
REQS = INFRA / "requirements-infra.txt"
COLLECTIONS = INFRA / "ansible/requirements.yml"
_NOT_IN_IMAGE = "not present in the shipped image — .dockerignore excludes infra/"

pytestmark = pytest.mark.skipif(not INFRA.exists(), reason=_NOT_IN_IMAGE)

_EXACT = re.compile(r"^[A-Za-z0-9_.-]+==[0-9][0-9A-Za-z.]*$")
# A collection entry's version: exactly X.Y.Z, quoted or not. Anchored to the
# key, so a comment mentioning a version is never read as one.
_COLLECTION = re.compile(r"^\s*-\s*name:\s*(?P<name>\S+)", re.M)
_VERSION = re.compile(r"^\s+version:\s*\"?(?P<v>[^\"\s#]+)\"?", re.M)
# Any spelling of an ansible-core pin a requirements or config file could carry.
_ANY_ANSIBLE_PIN = re.compile(r"^\s*ansible(?:-core)?\s*(?:==|~=|>=|<=|!=|<|>)", re.M)


def _requirement_lines(text):
    return [
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def unpinned_requirements(text):
    return [line for line in _requirement_lines(text) if not _EXACT.match(line)]


def collection_versions(text):
    """{name: version} for each collection entry, version None if absent."""
    out = {}
    names = list(_COLLECTION.finditer(text))
    for i, m in enumerate(names):
        end = names[i + 1].start() if i + 1 < len(names) else len(text)
        v = _VERSION.search(text, m.end(), end)
        out[m.group("name")] = v.group("v") if v else None
    return out


def test_ansible_core_is_pinned_exactly():
    lines = _requirement_lines(REQS.read_text())
    assert any(line.startswith("ansible-core==") for line in lines)
    assert unpinned_requirements(REQS.read_text()) == []


def test_every_collection_is_pinned_exactly():
    versions = collection_versions(COLLECTIONS.read_text())
    assert versions, "found no collections — is the pattern still matching?"
    loose = {n: v for n, v in versions.items() if not (v and re.fullmatch(r"\d+\.\d+\.\d+", v))}
    assert loose == {}, f"collections not pinned to an exact X.Y.Z: {loose}"


def test_ansible_core_is_pinned_in_one_file_only():
    hits = []
    for path in REPO_ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in {".txt", ".toml", ".cfg", ".yml", ".yaml", ".in"}:
            continue
        if any(part in {".git", ".venv", "venv", "collections", "node_modules"} for part in path.parts):
            continue
        if _ANY_ANSIBLE_PIN.search(path.read_text(errors="ignore")):
            hits.append(path.relative_to(REPO_ROOT).as_posix())
    assert hits == ["infra/requirements-infra.txt"]


# --- the detectors themselves can fail ---------------------------------------

@pytest.mark.parametrize("line", ["ansible-core>=2.21", "ansible-core", "ansible-core~=2.21.0"])
def test_a_loose_requirement_is_caught(line):
    assert unpinned_requirements(line + "\n") == [line]


def test_a_collection_without_an_exact_version_is_caught():
    text = (
        "collections:\n"
        "  - name: community.general   # version: 1.2.3 in a comment is not a pin\n"
        "  - name: ansible.posix\n"
        '    version: ">=2.0.0"\n'
    )
    assert collection_versions(text) == {"community.general": None, "ansible.posix": ">=2.0.0"}
