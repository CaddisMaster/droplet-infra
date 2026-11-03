# droplet-infra: the shared Droplet as code

One server runs several apps, and no app should own it. This repo holds the layer they share:
the host, the Droplet itself in Terraform, and the one narrow way backups leave it. The apps are
tenants, and each keeps its own layer in its own repo.

| Here | Layer |
|---|---|
| `infra/ansible/roles/droplet_host/` | the host: `deploy` user, sshd, ufw, Docker + Compose, Nginx base, Certbot, UTC |
| `infra/ansible/roles/droplet_export/` | `backup-export` and the VM's pull key, bound to its forced command |
| `infra/terraform/` | the Droplet itself, imported. Not DNS, which stays at Squarespace by hand |

| Tenant | Its layer |
|---|---|
| [`budget-buddy`](https://github.com/CaddisMaster/budget-buddy) | `/opt/budget-buddy`, its Nginx site, its dump script and timer, its release workflow |
| [`orbit-ops`](https://github.com/CaddisMaster/orbit-ops) | `/opt/orbit-ops`, its Nginx site, its dumps |
| [`seandesmet.com`](https://github.com/CaddisMaster/seandesmet.com) | the landing page and its Nginx site |

**Issue numbers:** this repo was split out of Budget Buddy with its history. In commit messages
that history says `BB-530`, and in file comments an older `#530` also means Budget Buddy's #530,
not an issue here.

## The rules a tenant relies on

⚠️ **`droplet_host`'s path and its `droplet_host_*` variables are an interface.** Tenants pin this
repo by commit SHA and run their own roles on top. A rename needs a pin bump in each, so a PR that
renames one says so. Apps pin it **for testing only, and never run `host.yml` on production.**

What the host role will **never** do, because the box is shared:

- **Remove an Nginx site it didn't create.** It never lists or purges `sites-available` or
  `sites-enabled`. The one exception is the packaged `default` link, by that name only, which
  production has disabled.
- **Rewrite `deploy`'s `authorized_keys`.** It adds the keys it declares (`exclusive: false`).
  Every tenant's deploy key and the `backup-export` key are other lines and stay as they are.
- **Request a certificate.** Certbot and its timer are installed, but issuing a certificate is
  per site, so it belongs to the tenants.
- **Write `.env` or `docker-compose.yml`.** Each app's release workflow owns its own.

`backup-export` names each app's database or dump folder. That's accepted: the server knows its
tenants. Its contract for Orbit Ops is that finished dumps are `*.sql.gz` in `/opt/orbit-ops/backups`.
A new `backup-export` command is a change here, made together with the app that needs it.

## Testing in LXD (on the `jupiter` VM)

```bash
infra/test.sh           # launch → run → run again (changed=0) → verify → delete
KEEP=1 infra/test.sh    # leave the container up to poke at
```

⚠️ **Warn Sean before a run.** The VM is on his Mac, and each run is about 5 minutes of load.

It builds the control node from the pins (`infra/requirements-infra.txt` and
`infra/ansible/requirements.yml`, both checked by `tests/test_infra_pins.py`) into `infra/.venv`.
It creates and deletes **only** containers named `di-*`, and uses containers, never `--vm`,
because the VM has no `/dev/kvm`.

The rest of the checks need no container:

```bash
pip install -r requirements-dev.txt && ruff check . && pytest -q
```

### LXD on the VM (initialised 2026-10-30)

Every project's tests reuse this setup. It was made with a preseed, so it can be rebuilt exactly:

```yaml
# lxd init --preseed < this
networks:
- name: lxdbr0
  type: bridge
  config: {ipv4.address: 10.111.0.1/24, ipv4.nat: "true", ipv6.address: none}
storage_pools:
- name: default
  driver: dir
profiles:
- name: default
  devices:
    root: {path: /, pool: default, type: disk}
    eth0: {name: eth0, network: lxdbr0, type: nic}
```

`dir` storage needs no loop file to size. `10.111.0.0/24` is clear of Docker's `172.x`
bridges. Each test container sets `security.nesting=true`, so Docker runs inside it.

### Docker and LXD on one host

⚠️ **Docker sets the VM's iptables `FORWARD` policy to `DROP`, which blackholes `lxdbr0`.** A
container gets an address and then cannot reach anything (verified 2026-10-30: `curl` to
the Ubuntu archive timed out). `infra/test.sh` checks for this first and stops with a
pointer here. The fix is two rules in Docker's `DOCKER-USER` chain, which Docker leaves alone:

```bash
sudo iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT
sudo iptables -I DOCKER-USER -o lxdbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```

They don't survive a reboot. Making them persistent is a VM setting, not this repo's. A
oneshot systemd unit ordered `After=docker.service` belongs in `personal-vault/infra/vm/`.

## Checking production

**Check mode first, always.** A real run is a separate decision for Sean, on a diff he has read.
`host.yml` has never run for real. This runs from a **Mac terminal**: the VM can't reach production
(since 2026-11-01). The Mac keeps **no clone** of this repo, and the decision on Budget Buddy's #530
(2026-10-29) was **a throwaway clone pinned to the reviewed commit, deleted afterwards.**

```bash
SHA=<the reviewed commit on main>
tmp=$(mktemp -d) && git -C "$tmp" init -q \
  && git -C "$tmp" fetch -q --depth 1 https://github.com/CaddisMaster/droplet-infra.git "$SHA" \
  && git -C "$tmp" checkout -q FETCH_HEAD && cd "$tmp/infra/ansible"
brew install python@3.12
"$(brew --prefix python@3.12)/bin/python3.12" -m venv ../.venv \
  && ../.venv/bin/pip install -q --no-deps -r ../requirements-infra.txt && ../.venv/bin/pip check
../.venv/bin/ansible-galaxy collection install -r requirements.yml -p ./collections
cp inventory.example.yml inventory.yml
nano inventory.yml
../.venv/bin/ansible-playbook host.yml --check --diff
cd ~ && rm -rf "$tmp"
```

Run these one at a time: `nano` is where you fill in the address and the real `deploy` key, and
`#` isn't a comment in an interactive zsh, so these boxes hold none. ansible-core needs Python 3.12
or newer, and the Mac's default `python3` is older. **The key's options must match the Droplet's line
exactly**, or check mode reports a false difference. Read it from the Mac:
`ssh root@<droplet> "grep github-actions /home/deploy/.ssh/authorized_keys"`.

Every difference it reports gets one of two outcomes: **fix the role**, or **record it below as
deliberate**. Production is never changed just to match a role.

### Where the host role and production differ, deliberately

- **The role's SSH drop-in (`Keys only, never a password`).** Production's SSH settings
  predate the role, and its first real run adds the role's own file under
  `/etc/ssh/sshd_config.d/`. That file restricts root to key logins. Password and
  keyboard-interactive logins are already off on production, so **nobody's access
  changes**: every login that works today is a key login, and still works. Check mode
  reports this task as `changed`, and that's expected. Checked 2026-10-30.

## Terraform

`infra/terraform/main.tf` describes the Droplet so that `plan` can compare it with what exists.
**Nothing here runs `apply`.** Any plan that says the Droplet must be replaced is a stop, and
`prevent_destroy` makes that plan fail.

- **Mac only.** The token is a DigitalOcean **Read Only** token kept in Bitwarden, never on the VM
  or GitHub.
- **State lives in `~/.budget-buddy-terraform/`** on the Mac, outside the throwaway clone. The
  directory keeps that name because moving this repo didn't need to touch the state. That Mac has
  no backup, and that's accepted: losing the file means running `import` again.
- **DNS isn't here.** `seandesmet.com`'s nameservers are Squarespace's, and no Terraform provider
  for them turned up. Moving DNS to DigitalOcean would be its own issue.

```bash
SHA=<the reviewed commit on main>
tmp=$(mktemp -d) && git -C "$tmp" init -q \
  && git -C "$tmp" fetch -q --depth 1 https://github.com/CaddisMaster/droplet-infra.git "$SHA" \
  && git -C "$tmp" checkout -q FETCH_HEAD && cd "$tmp/infra/terraform"
curl -fsSO https://releases.hashicorp.com/terraform/1.17.1/terraform_1.17.1_darwin_arm64.zip
echo "b1ecb3fe0d0a0290c1ab6f83d967d43f25da05d0b671ee0fb355252268dce95a  terraform_1.17.1_darwin_arm64.zip" \
  | shasum -a 256 -c && unzip -q terraform_1.17.1_darwin_arm64.zip -d ../.tf-bin
read -rs "T?DigitalOcean Read Only token: "; echo; export DIGITALOCEAN_TOKEN="$T"; unset T
mkdir -p -m 700 ~/.budget-buddy-terraform
../.tf-bin/terraform init -backend-config="path=$HOME/.budget-buddy-terraform/terraform.tfstate"
../.tf-bin/terraform plan
unset DIGITALOCEAN_TOKEN; cd ~ && rm -rf "$tmp"
```

Run the `read` line on its own, because it takes the next line of a paste as the token.

On a lost state file, run `terraform import digitalocean_droplet.main <droplet id>` before the
plan. The API's `/v2/droplets` gives the ID.
