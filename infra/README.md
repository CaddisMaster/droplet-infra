# infra/: the Droplet as code

The shared Droplet was built by hand from `RUNBOOK.md` §1–4. These roles describe it so it
can be rebuilt (the 26.04 upgrade is a rebuild, not an in-place upgrade) and checked.

| Role | Layer | Issue |
|---|---|---|
| `ansible/roles/droplet_host/` | the host: `deploy` user, sshd, ufw, Docker + Compose, Nginx base, Certbot, UTC | #530 |
| *(next)* | Budget Buddy's app layer, and www's site | #531 |

⚠️ **`droplet_host`'s path and its `droplet_host_*` variables are an interface.** Orbit Ops
pins this role by commit SHA (orbit-ops #322) and runs its own app role on top. A rename
needs a pin bump there, so a PR that renames one says so.

What the host role will **never** do, because the box is shared:

- **Remove an Nginx site it didn't create.** It never lists or purges `sites-available` or
  `sites-enabled`. The one exception is the packaged `default` link, by that name only, which
  production has disabled.
- **Rewrite `deploy`'s `authorized_keys`.** It adds the keys it declares (`exclusive: false`).
  Orbit Ops's deploy key and the `backup-export` key are other lines and stay as they are.
- **Request a certificate.** Certbot and its timer are installed, but issuing a certificate is
  per site, so it belongs to the app roles.
- **Write `.env` or `docker-compose.yml`.** `release.yml` owns both.

## Testing in LXD (on the `jupiter` VM)

```bash
infra/test.sh           # launch → run → run again (changed=0) → verify → delete
KEEP=1 infra/test.sh    # leave the container up to poke at
```

It builds the control node from the pins (`requirements-infra.txt` and
`ansible/requirements.yml`, both checked by `tests/test_infra_pins.py`) into `infra/.venv`.
It creates and deletes **only** containers named `bb-*`, and uses containers, never `--vm`,
because the VM has no `/dev/kvm`.

### LXD on the VM (initialised 2026-10-30)

Orbit Ops's tests reuse this setup. It was made with a preseed, so it can be rebuilt exactly:

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

Check mode only, never a real run (#530's scope). Since 2026-10-30 the VM can reach production
(while the editor connection is up), so the check can run from this clone, checked out at the
reviewed commit. The recipe below is the **Mac** route: the Mac keeps **no clone** of this
repo, and Sean's decision on #530 (2026-10-29) was **a throwaway clone pinned to the reviewed
commit, deleted afterwards.**

```bash
SHA=<the reviewed commit on main>
tmp=$(mktemp -d) && git -C "$tmp" init -q \
  && git -C "$tmp" fetch -q --depth 1 https://github.com/CaddisMaster/budget-buddy.git "$SHA" \
  && git -C "$tmp" checkout -q FETCH_HEAD && cd "$tmp/infra/ansible"
python3 -m venv ../.venv && ../.venv/bin/pip install -q -r ../requirements-infra.txt
../.venv/bin/ansible-galaxy collection install -r requirements.yml -p ./collections
cp inventory.example.yml inventory.yml   # then fill in the address and the real public keys
../.venv/bin/ansible-playbook host.yml --check --diff
cd ~ && rm -rf "$tmp"
```

Every difference it reports gets one of two outcomes: **fix the role**, or **record it in
RUNBOOK as deliberate** (RUNBOOK §8, "Where the host role and production differ"). Production is never changed to match the role.
