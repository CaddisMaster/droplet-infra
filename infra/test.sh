#!/usr/bin/env bash
# Test the host role (#530) in a throwaway LXD system container on the VM:
#   launch -> run -> plant unmanaged things -> run again (changed=0) -> verify -> delete
#
#   infra/test.sh            # keeps nothing
#   KEEP=1 infra/test.sh     # leaves the container up to poke at
#
# It creates and deletes ONLY containers named bb-*. Containers, never --vm:
# the VM has no /dev/kvm. LXD must be initialised first (infra/README.md).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ansible_dir=$here/ansible
venv=$here/.venv
name="bb-host-$(date +%s)"

die() { echo "infra/test.sh: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

delete_container() {
  [[ $1 == bb-* ]] || die "refusing to delete '$1': not a bb- container"
  lxc delete --force "$1" >/dev/null 2>&1 || true
}

command -v lxc >/dev/null || die "lxc not found; LXD is not installed"
lxc storage show default >/dev/null 2>&1 || die "LXD is not initialised; see infra/README.md"

# --- the control node: pinned ansible-core and collections ------------------
step "control node"
if [[ ! -x $venv/bin/ansible-playbook ]] || ! cmp -s "$here/requirements-infra.txt" "$venv/.requirements"; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install -q -r "$here/requirements-infra.txt"
  cp "$here/requirements-infra.txt" "$venv/.requirements"
fi
export PATH="$venv/bin:$PATH"
cd "$ansible_dir"
ansible-galaxy collection install -r requirements.yml -p ./collections >/dev/null
ansible --version | head -1

# --- nothing private is committable ------------------------------------------
step "the real inventory is gitignored"
git -C "$here/.." check-ignore -q infra/ansible/inventory.yml \
  || die "infra/ansible/inventory.yml is NOT gitignored; the Droplet's address would be committable"
echo "ok: infra/ansible/inventory.yml is ignored"

# --- launch ------------------------------------------------------------------
step "launch $name"
[[ ${KEEP:-} == 1 ]] || trap 'delete_container "$name"' EXIT
# A stalled image fetch once hung here for 14 minutes with no LXD operation
# running; bound it so a hang is a failure that says so.
timeout 300 lxc launch -q ubuntu:24.04 "$name" -c security.nesting=true \
  || die "lxc launch failed or took over 5 minutes (try: lxc image list; lxc launch by hand)"
lxc exec "$name" -- cloud-init status --wait >/dev/null || true

# Docker on the VM sets the FORWARD policy to DROP, which silently blackholes
# LXD's bridge. Fail here, naming the fix, rather than in apt ten minutes later.
if ! lxc exec "$name" -- timeout 15 curl -fsS -o /dev/null https://download.docker.com/; then
  die "the container has no internet. Docker's FORWARD DROP is blocking lxdbr0; see infra/README.md, 'Docker and LXD on one host'"
fi

# A request to Let's Encrypt's production endpoint cannot succeed from here,
# whatever runs. The role is also checked below never to have registered.
lxc exec "$name" -- sh -c 'echo "127.0.0.1 acme-v02.api.letsencrypt.org" >> /etc/hosts'

# --- the inventory, with one declared key ------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; [[ ${KEEP:-} == 1 ]] || delete_container "$name"' EXIT
ssh-keygen -q -t ed25519 -N '' -C 'bb-test declared' -f "$tmp/declared"
cat > "$tmp/inventory.yml" <<EOF
droplet:
  hosts:
    $name:
      ansible_connection: community.general.lxd
  vars:
    droplet_host_deploy_authorized_keys:
      - key: "$(cat "$tmp/declared.pub")"
        key_options: "no-agent-forwarding,no-port-forwarding,no-X11-forwarding"
EOF

# --- first run ---------------------------------------------------------------
step "first run"
ansible-playbook -i "$tmp/inventory.yml" host.yml

# --- plant what the role did not create --------------------------------------
step "plant an unmanaged Nginx site and an unmanaged key"
lxc exec "$name" -- sh -c '
  printf "server {\n  listen 127.0.0.1:8099;\n  return 204;\n}\n" > /etc/nginx/sites-available/bb-unmanaged
  ln -s /etc/nginx/sites-available/bb-unmanaged /etc/nginx/sites-enabled/bb-unmanaged
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbUnmanagedKeyForTheTestOnlyxxxxxxxxxxxxxxx github-actions orbit-ops deploy" \
    >> /home/deploy/.ssh/authorized_keys'
unmanaged_line=$(lxc exec "$name" -- tail -1 /home/deploy/.ssh/authorized_keys)

# --- second run: nothing to do -----------------------------------------------
step "second run (must report changed=0)"
ansible-playbook -i "$tmp/inventory.yml" host.yml | tee "$tmp/second.log"
grep -qE "^$name +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0" "$tmp/second.log" \
  || die "the second run changed something or failed; see the recap above"

# --- verify --------------------------------------------------------------------
step "verify"
ct() { lxc exec "$name" -- "$@"; }

# RUNBOOK §2: deny incoming, allow outgoing, 22 and Nginx Full, nothing else.
ufw=$(ct ufw status verbose)
echo "$ufw"
grep -q '^Status: active' <<<"$ufw" || die "ufw is not active"
grep -q 'Default: deny (incoming), allow (outgoing)' <<<"$ufw" || die "ufw defaults differ from RUNBOOK §2"
rules=$(grep -E 'ALLOW IN' <<<"$ufw" | grep -v '(v6)' | awk '{print $1}' | sort | tr '\n' ' ')
[[ $rules == "22 80,443/tcp " ]] || die "ufw allows '$rules', RUNBOOK §2 says '22 80,443/tcp'"

ct docker compose version
# #548: production's engine is Ubuntu's docker.io, with only the Compose plugin
# from Docker's repository. A role that installs docker-ce would swap the engine
# under both apps on its first real run.
pkgs=$(ct dpkg-query -W -f='${Package} ${Status}\n' docker.io docker-ce docker-compose-plugin 2>/dev/null || true)
echo "$pkgs"
grep -qx 'docker.io install ok installed' <<<"$pkgs" || die "docker.io is not installed; production runs docker.io"
! grep -qx 'docker-ce install ok installed' <<<"$pkgs" || die "docker-ce is installed; production runs docker.io"
grep -qx 'docker-compose-plugin install ok installed' <<<"$pkgs" || die "Docker's Compose plugin is not installed"
ct test -f /etc/apt/sources.list.d/docker.list || die "Docker's repository is not in docker.list, where production has it"
ct test ! -e /etc/apt/sources.list.d/docker.sources || die "docker.sources exists; production's repository is docker.list, and both would duplicate it"
ct nginx -t
ct test -f /etc/nginx/sites-available/bb-unmanaged || die "the unmanaged site file was removed"
ct test -L /etc/nginx/sites-enabled/bb-unmanaged || die "the unmanaged sites-enabled link was removed"
ct test ! -e /etc/nginx/sites-enabled/default || die "the packaged default site is still enabled"

ct grep -qxF "$unmanaged_line" /home/deploy/.ssh/authorized_keys || die "the unmanaged key line changed or vanished"
ct grep -qF "$(cut -d' ' -f2 "$tmp/declared.pub")" /home/deploy/.ssh/authorized_keys || die "the declared key is missing"
# Output is captured before grep, never piped: `grep -q` stops reading at its
# match, the writer dies of SIGPIPE, and pipefail turns a correct setting into
# an intermittent failure (sshd -T did exactly that, 1 run in 2).
groups=$(ct id -nG deploy)
grep -qw docker <<<"$groups" || die "deploy is not in the docker group"
! grep -qw sudo <<<"$groups" || die "deploy is in the sudo group"
sshd_config=$(ct sshd -T)
grep -qx 'passwordauthentication no' <<<"$sshd_config" || die "sshd still accepts passwords"
[[ $(ct date +%Z) == UTC ]] || die "the host is not on UTC"

# No certificate was requested: no ACME account, no live lineage.
ct test ! -e /etc/letsencrypt/accounts || die "an ACME account exists; something asked Let's Encrypt"
ct test ! -e /etc/letsencrypt/live || die "a certificate lineage exists"

echo
echo "PASS: $name built from nothing, second run changed=0, unmanaged site and key survived"
if [[ ${KEEP:-} == 1 ]]; then
  echo "KEEP=1: left $name running; delete it with: lxc delete --force $name"
fi
