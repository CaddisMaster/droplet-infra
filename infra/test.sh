#!/usr/bin/env bash
# Test the roles in a throwaway LXD system container on the VM:
#   host role (#530): launch -> run -> plant unmanaged things -> run again (changed=0) -> verify
#   app roles (#531): refusals -> run -> run again (changed=0) -> a deploy is not drift -> verify
#   then delete
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

# --- the app layer (#531) -------------------------------------------------------
play() { ansible-playbook -i "$tmp/inventory.yml" "$@"; }
recap_ok() { grep -qE "^$name +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0" "$1"; }
refused() { # refused <log name> <text the failure must name>
  if play app.yml >"$tmp/$1.log" 2>&1; then die "the app playbook passed: $1"; fi
  grep -qF "$2" "$tmp/$1.log" || { cat "$tmp/$1.log"; die "$1: the failure doesn't name '$2'"; }
  echo "ok: refused, named $2"
}

step "no .env: the run must fail and name the file"
refused no-env '/opt/budget-buddy/.env must exist'
ct test ! -e /opt/budget-buddy/.env || die "the role created .env"

step ".env mode 644: the run must fail and leave it alone"
ct sh -c 'printf "SECRET_KEY=test-only-not-a-secret\nTAG=0.0.1\n" > /opt/budget-buddy/.env && chown deploy:deploy /opt/budget-buddy/.env && chmod 644 /opt/budget-buddy/.env'
before=$(ct sha256sum /opt/budget-buddy/.env)
refused bad-mode '/opt/budget-buddy/.env must exist'
[[ $(ct stat -c %a /opt/budget-buddy/.env) == 644 ]] || die "the role changed .env's mode"
[[ $(ct sha256sum /opt/budget-buddy/.env) == "$before" ]] || die "the role changed .env's contents"
! grep -q 'test-only-not-a-secret' "$tmp/bad-mode.log" || die "the run printed .env's contents"
ct chmod 600 /opt/budget-buddy/.env

step "no docker-compose.yml: the run must fail and name it"
refused no-compose '/opt/budget-buddy/docker-compose.yml is missing'
ct sh -c 'echo "name: as-release-left-it" > /opt/budget-buddy/docker-compose.yml && chown deploy:deploy /opt/budget-buddy/docker-compose.yml'

step "no certificate: the run must fail and name it"
refused no-budget-cert 'live/budget.seandesmet.com/fullchain.pem is missing'
ct sh -c '
  set -e
  for domain in budget.seandesmet.com seandesmet.com; do
    d=/etc/letsencrypt/live/$domain && mkdir -p "$d"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$domain" \
      -keyout "$d/privkey.pem" -out "$d/fullchain.pem" 2>/dev/null
  done
  cp "$(find /usr/lib/python3/dist-packages -name options-ssl-nginx.conf | head -1)" /etc/letsencrypt/
  cp "$(find /usr/lib/python3/dist-packages -name ssl-dhparams.pem | head -1)" /etc/letsencrypt/'

step "no www headers snippet: the run must fail and name it"
refused no-snippet 'seandesmet-security-headers.conf is missing'
ct test ! -e /etc/nginx/sites-enabled/seandesmet.com || die "the www site was enabled before its snippet existed"
ct sh -c 'echo "add_header X-BB-Stand-In www;" > /etc/nginx/snippets/seandesmet-security-headers.conf'

step "first run of the app playbook"
play app.yml

step "second run of the app playbook (must report changed=0)"
play app.yml | tee "$tmp/app-second.log"
recap_ok "$tmp/app-second.log" || die "the second run changed something or failed; see the recap above"

step "a deploy is not drift (check mode must report changed=0)"
# As release.yml would leave them: a new compose file and a new TAG= line.
ct sh -c 'echo "name: the-next-release" > /opt/budget-buddy/docker-compose.yml && sed -i "s/^TAG=.*/TAG=0.0.2/" /opt/budget-buddy/.env'
deployed=$(ct sha256sum /opt/budget-buddy/docker-compose.yml /opt/budget-buddy/.env)
play app.yml --check --diff | tee "$tmp/app-check.log"
recap_ok "$tmp/app-check.log" || die "check mode reports a change after a deploy"
play app.yml | tee "$tmp/app-third.log"
recap_ok "$tmp/app-third.log" || die "a real run changed something after a deploy"
[[ $(ct sha256sum /opt/budget-buddy/docker-compose.yml /opt/budget-buddy/.env) == "$deployed" ]] \
  || die "the role changed a file release.yml owns"

step "verify the app layer"
[[ $(ct stat -c '%a %U:%G' /opt/budget-buddy) == '755 deploy:deploy' ]] || die "/opt/budget-buddy is not 755 deploy:deploy"
[[ $(ct stat -c '%a %U:%G' /opt/budget-buddy/sql) == '755 deploy:deploy' ]] || die "sql/ is not 755 deploy:deploy"
[[ $(ct stat -c '%a %U:%G' /opt/budget-buddy/backups) == '700 deploy:deploy' ]] || die "backups/ is not 700 deploy:deploy"
ct test ! -e /opt/budget-buddy/.git || die "the deploy directory has a git checkout"
[[ $(ct stat -c '%a %U:%G' /opt/budget-buddy/.env) == '600 deploy:deploy' ]] || die ".env changed"
for site in budget-buddy seandesmet.com; do
  [[ $(ct readlink "/etc/nginx/sites-enabled/$site") == "/etc/nginx/sites-available/$site" ]] || die "$site is not enabled"
done
cmp -s <(ct cat /etc/nginx/sites-available/budget-buddy) "$ansible_dir/roles/budget_buddy_app/files/budget-buddy" || die "the budget site differs from the role's"
cmp -s <(ct cat /etc/nginx/sites-available/seandesmet.com) "$ansible_dir/roles/www_site/files/seandesmet.com" || die "the www site differs from the role's"
ct nginx -t
ct test -L /etc/nginx/sites-enabled/bb-unmanaged || die "the app roles removed a site they did not create"

# The budget site proxies to 5001, and only /transactions/import takes a large body.
ct sh -c 'mkdir -p /tmp/be && echo budget-backend > /tmp/be/index.html && cd /tmp/be &&
  nohup python3 -m http.server 5001 --bind 127.0.0.1 >/dev/null 2>&1 &'
sleep 1
budget=(--resolve budget.seandesmet.com:443:127.0.0.1 --resolve budget.seandesmet.com:80:127.0.0.1)
body=$(ct curl -sk "${budget[@]}" https://budget.seandesmet.com/)
[[ $body == budget-backend ]] || die "https://budget.seandesmet.com/ did not reach 127.0.0.1:5001 (got: $body)"
redirect=$(ct curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "${budget[@]}" http://budget.seandesmet.com/x)
[[ $redirect == '301 https://budget.seandesmet.com/x' ]] || die "port 80 does not redirect to HTTPS (got: $redirect)"
ct sh -c 'head -c 2097152 /dev/zero > /tmp/2mb'
outside=$(ct curl -sk -o /dev/null -w '%{http_code}' "${budget[@]}" --data-binary @/tmp/2mb https://budget.seandesmet.com/x)
[[ $outside == 413 ]] || die "a 2 MB POST outside the import route got $outside, not Nginx's 413"
import=$(ct curl -sk -o /dev/null -w '%{http_code}' "${budget[@]}" --data-binary @/tmp/2mb https://budget.seandesmet.com/transactions/import)
[[ $import != 413 ]] || die "a 2 MB POST to /transactions/import was refused by Nginx"
echo "ok: 2 MB POST got $outside elsewhere and $import at the import route"

# The www site serves the web root, and its headers come from the snippet.
ct test ! -e /var/www/seandesmet.com/index.html || die "the role wrote the page; landing-deploy owns it"
[[ $(ct stat -c '%a %U:%G' /var/www/seandesmet.com) == '755 deploy:deploy' ]] || die "the web root is not 755 deploy:deploy"
ct sh -c 'echo www-page > /var/www/seandesmet.com/index.html'
www=(--resolve seandesmet.com:443:127.0.0.1)
body=$(ct curl -sk "${www[@]}" https://seandesmet.com/)
[[ $body == www-page ]] || die "https://seandesmet.com/ did not serve the web root (got: $body)"
headers=$(ct curl -skI "${www[@]}" https://seandesmet.com/)
grep -qi '^x-bb-stand-in: www' <<<"$headers" || die "the www site does not include its headers snippet"

ct test ! -e /etc/letsencrypt/accounts || die "an ACME account exists; something asked Let's Encrypt"

echo
echo "PASS: $name built from nothing, second runs changed=0, unmanaged site and key survived,"
echo "      app roles refused bad input, and a deploy is not drift"
if [[ ${KEEP:-} == 1 ]]; then
  echo "KEEP=1: left $name running; delete it with: lxc delete --force $name"
fi
