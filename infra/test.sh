#!/usr/bin/env bash
# Test the server layer in a throwaway LXD system container on the VM:
#   launch -> run -> plant unmanaged things -> run again (changed=0) -> verify
#     -> the backup key's refusals, and both exports through it -> delete
#
#   infra/test.sh            # keeps nothing
#   KEEP=1 infra/test.sh     # leaves the container up to poke at
#
# It creates and deletes ONLY containers named di-*. Containers, never --vm:
# the VM has no /dev/kvm. LXD must be initialised first (README.md).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ansible_dir=$here/ansible
venv=$here/.venv
name="di-host-$(date +%s)"

die() { echo "infra/test.sh: $*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

delete_container() {
  [[ $1 == di-* ]] || die "refusing to delete '$1': not a di- container"
  lxc delete --force "$1" >/dev/null 2>&1 || true
}

command -v lxc >/dev/null || die "lxc not found; LXD is not installed"
lxc storage show default >/dev/null 2>&1 || die "LXD is not initialised; see README.md"

# --- the control node: pinned ansible-core and collections ------------------
step "control node"
if [[ ! -x $venv/bin/ansible-playbook ]] || ! cmp -s "$here/requirements-infra.txt" "$venv/.requirements"; then
  # --clear: over an old venv, a package already installed would satisfy pip check
  # and hide a dependency this list has lost (#553).
  python3 -m venv --clear "$venv"
  "$venv/bin/pip" install -q --no-deps -r "$here/requirements-infra.txt"
  "$venv/bin/pip" check || die "requirements-infra.txt is missing a dependency; pin it there"
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
# </dev/null: off a terminal, lxc launch reads its config from stdin, so an open
# pipe or socket hangs it forever with no LXD operation running. Measured from a
# Claude Code session: 5 of 5 hung without it, 5 of 5 took 2s with it. The timeout
# stays so any other hang is a failure that says so.
timeout 300 lxc launch -q ubuntu:24.04 "$name" -c security.nesting=true </dev/null \
  || die "lxc launch failed or took over 5 minutes (try: lxc image list; lxc launch by hand)"
lxc exec "$name" -- cloud-init status --wait >/dev/null || true

# Docker on the VM sets the FORWARD policy to DROP, which silently blackholes
# LXD's bridge. Fail here, naming the fix, rather than in apt ten minutes later.
if ! lxc exec "$name" -- timeout 15 curl -fsS -o /dev/null https://download.docker.com/; then
  die "the container has no internet. Docker's FORWARD DROP is blocking lxdbr0; see README.md, 'Docker and LXD on one host'"
fi

# A request to Let's Encrypt's production endpoint cannot succeed from here,
# whatever runs. The role is also checked below never to have registered.
lxc exec "$name" -- sh -c 'echo "127.0.0.1 acme-v02.api.letsencrypt.org" >> /etc/hosts'

# --- the inventory, with one declared key ------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; [[ ${KEEP:-} == 1 ]] || delete_container "$name"' EXIT
ssh-keygen -q -t ed25519 -N '' -C 'di-test declared' -f "$tmp/declared"
ssh-keygen -q -t ed25519 -N '' -C 'di-test backup' -f "$tmp/backup"
cat > "$tmp/inventory.yml" <<EOF
droplet:
  hosts:
    $name:
      ansible_connection: community.general.lxd
  vars:
    droplet_host_deploy_authorized_keys:
      - key: "$(cat "$tmp/declared.pub")"
        key_options: "no-agent-forwarding,no-port-forwarding,no-X11-forwarding"
    # A throwaway key with production's options, so the forced command can be driven.
    droplet_export_key: "$(cat "$tmp/backup.pub")"
EOF

# --- first run ---------------------------------------------------------------
step "first run"
ansible-playbook -i "$tmp/inventory.yml" host.yml

# --- plant what the role did not create --------------------------------------
step "plant an unmanaged Nginx site and an unmanaged key"
lxc exec "$name" -- sh -c '
  printf "server {\n  listen 127.0.0.1:8099;\n  return 204;\n}\n" > /etc/nginx/sites-available/di-unmanaged
  ln -s /etc/nginx/sites-available/di-unmanaged /etc/nginx/sites-enabled/di-unmanaged
  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBdiUnmanagedKeyForTheTestOnlyxxxxxxxxxxxxxxx github-actions orbit-ops deploy" \
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
ct test -f /etc/nginx/sites-available/di-unmanaged || die "the unmanaged site file was removed"
ct test -L /etc/nginx/sites-enabled/di-unmanaged || die "the unmanaged sites-enabled link was removed"
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

# --- the export (BB #532, #535) --------------------------------------------------
step "the export is installed"
cmp -s <(ct cat /usr/local/bin/backup-export) "$ansible_dir/roles/droplet_export/files/backup-export" || die "backup-export differs from the role's"
[[ $(ct stat -c '%a %U:%G' /usr/local/bin/backup-export) == '755 root:root' ]] || die "backup-export is not 755 root:root"

# The script names Budget Buddy's container and user, so a stand-in carries them.
# The real schema stays in that repo; one table is enough to prove a dump comes out.
ct docker run -d -q --name budget-buddy-db-1 -e POSTGRES_USER=admin -e POSTGRES_PASSWORD=test-only -e POSTGRES_DB=budget postgres:16 >/dev/null
for _ in $(seq 1 60); do
  ct docker exec budget-buddy-db-1 pg_isready -q -U admin -d budget && break
  sleep 2
done
ct docker exec budget-buddy-db-1 pg_isready -q -U admin -d budget || die "the stand-in database never came up"
ct docker exec budget-buddy-db-1 psql -q -U admin -d budget -c 'CREATE TABLE public.transactions (id int)' >/dev/null

step "the forced command refuses everything else"
lxc file push -q --mode 600 "$tmp/backup" "$name/root/backup-key"
key_ssh=(ssh -T -i /root/backup-key -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR deploy@127.0.0.1)
dump_over_key=$(ct "${key_ssh[@]}" budget) || die "the backup key couldn't run 'budget': is it bound to the forced command?"
grep -q 'CREATE TABLE public.transactions' <<<"$dump_over_key" || die "the backup key couldn't run 'budget'; the refusals below would prove nothing"
for attempt in 'cat /etc/shadow' 'id' 'budget; id' 'budget extra' 'configs /etc/shadow' 'ping/evil' 'BUDGET'; do
  if out=$(ct "${key_ssh[@]}" "$attempt" 2>&1); then die "the backup key ran '$attempt'"; fi
  grep -q 'backup-export: refused' <<<"$out" || die "'$attempt' failed without the refusal: $out"
done
if out=$(ct "${key_ssh[@]}" 2>&1 </dev/null); then die "the backup key got an interactive login"; fi
grep -q 'backup-export: refused' <<<"$out" || die "an empty command failed without the refusal: $out"
echo "ok: 'budget' works; shell commands, extra arguments and an empty command are refused"

step "Orbit Ops's dumps go through the backup key (#535)"
ct sh -c 'install -d -o deploy -g deploy -m 750 /opt/orbit-ops && install -d -o deploy -g deploy -m 700 /opt/orbit-ops/backups'
if out=$(ct "${key_ssh[@]}" orbit-ops 2>&1); then die "orbit-ops succeeded with no dump"; fi
grep -q 'no Orbit Ops dump' <<<"$out" || die "no dump failed without naming it: $out"
dump_over_key=$(ct "${key_ssh[@]}" budget) || die "with no Orbit Ops dump, 'budget' stopped working"
grep -q 'CREATE TABLE public.transactions' <<<"$dump_over_key" || die "with no Orbit Ops dump, 'budget' returned no dump"
ct sudo -u deploy sh -c 'cd /opt/orbit-ops/backups &&
  echo older | gzip > nightly-20260101-000000.sql.gz && sleep 1.1 &&
  echo newest | gzip > nightly-20260102-000000.sql.gz && sleep 1.1 &&
  echo partial | gzip > nightly-20260103-000000.sql.gz.partial'
got=$(ct sh -c "$(printf '%q ' "${key_ssh[@]}") orbit-ops | gunzip -c")
[[ $got == newest ]] || die "orbit-ops returned '$got', not the newest finished dump"
for attempt in 'orbit-ops /etc/shadow' 'orbit-ops ../../etc/shadow' 'orbit-ops; id' 'ORBIT-OPS'; do
  if out=$(ct "${key_ssh[@]}" "$attempt" 2>&1); then die "the backup key ran '$attempt'"; fi
  grep -q 'backup-export: refused' <<<"$out" || die "'$attempt' failed without the refusal: $out"
done
echo "ok: named error with no dump, newest finished dump served, and no argument accepted"

[[ $(ct docker ps -q | wc -l) == 1 ]] || die "expected only the stand-in database running"
ct test ! -e /etc/letsencrypt/accounts || die "an ACME account exists; something asked Let's Encrypt"

echo
echo "PASS: $name built from nothing, the second run changed=0, the unmanaged site and key"
echo "      survived, the backup key refused everything else, and both exports went through it"
if [[ ${KEEP:-} == 1 ]]; then
  echo "KEEP=1: left $name running; delete it with: lxc delete --force $name"
fi
