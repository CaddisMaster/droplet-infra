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


def _names(text):
    return {line.split("==")[0].lower() for line in _requirement_lines(text)}


def _pip_entry_directories(text):
    """The `directory:` of each pip block in a dependabot.yml, read as text."""
    blocks = re.split(r"^\s*-\s*package-ecosystem:\s*", text, flags=re.M)[1:]
    return [
        re.search(r'directory:\s*"([^"]+)"', block).group(1)
        for block in blocks
        if block.startswith("pip")
    ]


@pytest.mark.criterion(553, "The control node installs only pinned packages")
def test_the_control_node_installs_only_pinned_packages():
    # ansible-core's own requirements, so they cannot float underneath it.
    assert {"jinja2", "pyyaml", "cryptography", "packaging", "resolvelib"} <= _names(REQS.read_text())

    script = (INFRA / "test.sh").read_text()
    assert 'pip" install -q --no-deps -r' in script
    assert 'pip" check' in script
    # Over an old venv, a leftover package would satisfy pip check.
    assert "-m venv --clear" in script


@pytest.mark.criterion(553, "Dependabot proposes bumps for the control node")
def test_dependabot_proposes_bumps_for_the_control_node():
    config = (REPO_ROOT / ".github/dependabot.yml").read_text()
    assert "/infra" in _pip_entry_directories(config)


def test_the_production_check_names_a_python_ansible_core_can_run_on():
    # #567: the Mac's default python3 is too old for ansible-core 2.21.
    readme = (INFRA / "README.md").read_text()
    assert "python3 -m venv" not in readme
    assert "python3.12\" -m venv" in readme
    assert "--no-deps -r ../requirements-infra.txt && ../.venv/bin/pip check" in readme


# --- Terraform (#533) ---------------------------------------------------------

TERRAFORM = INFRA / "terraform"
_RESOURCE = re.compile(r'^resource\s+"(?P<type>[a-z_]+)"', re.M)
_TF_VERSION = re.compile(r'required_version\s*=\s*"= (?P<v>\d+\.\d+\.\d+)"')
_PROVIDER_VERSION = re.compile(r'^\s+version\s*=\s*"= (?P<v>\d+\.\d+\.\d+)"', re.M)


def terraform_resources(text):
    return _RESOURCE.findall(text)


def has_prevent_destroy(text):
    return re.search(r"^\s*prevent_destroy\s*=\s*true\s*$", text, re.M) is not None


def test_terraform_and_its_provider_are_pinned_exactly():
    main = (TERRAFORM / "main.tf").read_text()
    assert _TF_VERSION.search(main)
    pinned = _PROVIDER_VERSION.search(main).group("v")
    lock = (TERRAFORM / ".terraform.lock.hcl").read_text()
    assert f'version     = "{pinned}"' in lock


def test_the_lock_file_covers_the_mac_and_the_vm():
    # Hashes for one platform only would make init rewrite the lock on the other.
    lock = (TERRAFORM / ".terraform.lock.hcl").read_text()
    assert lock.count('"h1:') >= 2


@pytest.mark.criterion(533, "The droplet cannot be destroyed by accident")
def test_the_droplet_cannot_be_destroyed_by_accident():
    assert has_prevent_destroy((TERRAFORM / "main.tf").read_text())


def test_terraform_holds_the_droplet_and_nothing_else():
    # DNS is at Squarespace, so a domain resource here would create a second copy.
    assert terraform_resources((TERRAFORM / "main.tf").read_text()) == ["digitalocean_droplet"]


@pytest.mark.criterion(533, "Nothing private is committable")
def test_nothing_private_is_committable():
    gitignore = (REPO_ROOT / ".gitignore").read_text().splitlines()
    assert {"*.tfstate", "*.tfstate.*", "*.tfvars", ".terraform/"} <= set(gitignore)
    assert ".terraform.lock.hcl" not in gitignore


def test_the_droplet_address_and_token_are_not_in_the_config():
    main = (TERRAFORM / "main.tf").read_text()
    assert not re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", main)
    assert "dop_v1_" not in main
    assert not re.search(r"^\s*token\s*=", main, re.M)


def test_dependabot_covers_the_provider():
    config = (REPO_ROOT / ".github/dependabot.yml").read_text()
    assert 'package-ecosystem: terraform\n    directory: "/infra/terraform"' in config


# --- the detectors themselves can fail ---------------------------------------

@pytest.mark.parametrize("line", ["ansible-core>=2.21", "ansible-core", "ansible-core~=2.21.0"])
def test_a_loose_requirement_is_caught(line):
    assert unpinned_requirements(line + "\n") == [line]


def test_a_pip_entry_for_another_directory_is_not_mistaken_for_infra():
    text = (
        "updates:\n"
        '  - package-ecosystem: pip\n    directory: "/"\n'
        '  - package-ecosystem: docker\n    directory: "/infra"\n'
    )
    assert _pip_entry_directories(text) == ["/"]


def test_a_collection_without_an_exact_version_is_caught():
    text = (
        "collections:\n"
        "  - name: community.general   # version: 1.2.3 in a comment is not a pin\n"
        "  - name: ansible.posix\n"
        '    version: ">=2.0.0"\n'
    )
    assert collection_versions(text) == {"community.general": None, "ansible.posix": ">=2.0.0"}


def test_a_second_resource_is_noticed():
    text = 'resource "digitalocean_droplet" "a" {}\nresource "digitalocean_domain" "b" {}\n'
    assert terraform_resources(text) == ["digitalocean_droplet", "digitalocean_domain"]


def test_a_commented_out_prevent_destroy_is_not_a_guard():
    assert not has_prevent_destroy("  # prevent_destroy = true\n")
    assert not has_prevent_destroy("  prevent_destroy = false\n")
    assert has_prevent_destroy("    prevent_destroy = true\n")
