# Hardening the FATE self-hosted runners

The FATE bench runs on self-hosted GitHub Actions runners on the homelab tailnet. On a
public repository a self-hosted runner is a remote-code-execution surface: every job
runs repository code and its full dependency tree, and once a runner sits on the tailnet
a compromised job can pivot to other nodes. This guide is the paranoid baseline. Register
runners with the walkthrough in `FATE_BENCH.md`, then apply every layer here.

## Threat model

- **Untrusted code on the runner.** A job runs whatever is on the branch plus the mix,
  npm, and nix dependency closures. A malicious commit (compromised account), a poisoned
  dependency, or a workflow-injection bug executes on the runner as the runner user.
- **Lateral movement.** From a compromised runner, the tailnet is the blast radius:
  other homelab nodes, services, and any credentials reachable over the mesh.
- **Persistence.** A foothold that survives between jobs can escalate over time.
- **Credential theft.** The runner registration PAT and any secrets on the box let an
  attacker register more runners or reach external services.

The goal is not to make a compromised job impossible (untrusted code will run). It is to
make one contained, ephemeral, and unable to move laterally or persist.

## Defense in depth

### 0. Trigger fencing (shipped in the workflow)

`fate-selfhosted.yml` never runs untrusted code: triggers are `workflow_dispatch`,
`push` to `master`, and `schedule` only (no `pull_request`), with
`if: github.repository_owner == 'DROOdotFOO'`. Fork code cannot reach the runners. This
is the first gate; everything below assumes it can still fail (a compromised dependency
or maintainer account runs trusted-path code).

### 1. GitHub repository settings (UI)

Settings -> Actions -> General:

- **Fork pull request workflows from outside collaborators**: "Require approval for all
  outside collaborators" (strictest). Defense in depth on top of the missing
  `pull_request` trigger.
- **Workflow permissions**: "Read repository contents and packages permissions" so the
  per-job `GITHUB_TOKEN` is read-only. The workflow also pins `permissions: contents: read`.
- Keep the runners **repo-scoped** (register on the repo, never the org, so no other
  repository can target the hardware).

### 2. Ephemeral runners

Every runner handles one job, then deregisters and is replaced. No workspace or process
survives between jobs, so a foothold cannot persist.

- NixOS: `raxol.ci.githubRunner` sets `ephemeral = true` on the underlying
  `services.github-runners`.
- Manual hosts: pass `--ephemeral` to `config.sh`.

Prefer just-in-time (JIT) runners as an upgrade: a controller mints a single-use config
via `POST /repos/{owner}/{repo}/actions/runners/generate-jitconfig`, so no long-lived PAT
sits on the box. The PAT path below is the simpler baseline.

### 3. OS and process isolation

- **Unprivileged, sandboxed service.** On NixOS the upstream `services.github-runners`
  module runs under `DynamicUser` with a hardened systemd sandbox (`ProtectSystem`,
  `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, syscall filtering). Do not relax those.
  On manual hosts apply the drop-in in the "Non-NixOS hosts" section.
- **Resource caps.** `raxol.ci.githubRunner` sets `MemoryMax` (default 6G) and
  `TasksMax`, with an optional `cpuQuota`, so a runaway or a miner cannot take the host
  down. Set the same via a systemd drop-in on manual hosts.
- **No ambient privilege.** The runner user must not be in `sudo`, `wheel`, or the
  `docker` group, and must have no SSH keys or cloud credentials in its home.
- **Not a Nix trusted-user.** A Nix trusted-user can rewrite Nix config and add
  substituters, which turns a compromised job into host-level code execution. Keep the
  runner user out of `nix.settings.trusted-users`.

### 4. Tailnet isolation (the lateral-movement control)

Tailscale ACLs, not the host, decide what the runners can reach. Tag every runner
`tag:ci` (the module advertises this via `raxol.ci.githubRunner.tailscaleTags`) and apply
a default-deny policy in the Tailscale admin console:

```jsonc
{
  "tagOwners": {
    "tag:ci": ["autogroup:admin"],
    "tag:admin": ["autogroup:admin"]
  },

  // Tailscale is default-deny once ACLs exist: only listed flows are allowed.
  "acls": [
    // Admins reach the runners for management. Runners get no blanket tailnet access.
    { "action": "accept", "src": ["autogroup:admin", "tag:admin"], "dst": ["tag:ci:*"] }

    // Layer 3 (swarm-FATE) only: uncomment to allow runner-to-runner BEAM
    // distribution (epmd + a pinned distribution port range), nothing else.
    // { "action": "accept", "src": ["tag:ci"], "dst": ["tag:ci:4369", "tag:ci:9100-9200"] }
  ],

  "ssh": [
    // Admins may SSH into runners; runners may not SSH anywhere.
    {
      "action": "accept",
      "src": ["autogroup:admin"],
      "dst": ["tag:ci"],
      "users": ["autogroup:nonroot"]
    }
  ]
}
```

What this buys and what it does not:

- A `tag:ci` node has **no grant to any tailnet peer**, so default-deny blocks all
  lateral movement. Admins can still reach it for management.
- ACLs govern tailnet traffic only. They do **not** restrict public-internet egress, and
  CI needs it (GitHub, nix substituters, hex). Treat the runner as internet-connected and
  rely on ephemerality plus no-secrets-on-box to bound exfiltration risk.
- `--shields-up` (option `shieldsUp`) additionally blocks all inbound tailnet
  connections. It also blocks admin SSH in, so leave it off unless the host needs zero
  inbound and you manage it another way.

### 5. Host firewall

Deny inbound at the host too, so a misconfigured ACL is not the only barrier.

- NixOS: `networking.firewall.enable = true` (the host config, not this module) with no
  opened ports; Tailscale manages its own interface.
- Manual hosts: see the nftables ruleset below.

### 6. Supply-chain pinning

- Commit `flake.lock` and keep `mix.lock` current so the toolchain and dependency closure
  are reproducible and reviewed, not floating.
- The runner drives its toolchain through `nix develop` against the committed
  `flake.lock`, so two runs on two arches differ only by architecture.

### 7. Monitoring and incident response

- Ship the runner's journald + auth logs off-box (or at least review them); alert on
  unexpected outbound connections and on `config.sh`/runner-registration events.
- If a runner is suspected compromised: remove it in Settings -> Actions -> Runners,
  rotate the registration PAT and the Tailscale auth key, and rebuild the host. Ephemeral
  runners make rebuild cheap.

## Concrete configs

### NixOS host

Import `nixosModules.githubRunner` and set the paranoid knobs (see `FATE_BENCH.md` for the
full stanza + agenix secrets):

```nix
raxol.ci.githubRunner = {
  enable = true;
  tokenFile = config.age.secrets.gh-runner-token.path;   # minimal-scope PAT, see below
  tailscaleAuthKeyFile = config.age.secrets.ts-authkey.path;
  tailscaleTags = [ "tag:ci" ];
  extraLabels = [ "laptop" ];
  memoryMax = "6G";
  # cpuQuota = "400%";   # optional
};
```

The module keeps the runner ephemeral, tags it for the ACL, caps its resources, and does
not make it a Nix trusted-user.

### Non-NixOS hosts (Turing Pi boards, x86 box)

Register ephemerally and harden the systemd unit `svc.sh` creates. Adjust the user and
work-dir paths.

```bash
# Ephemeral registration with our label
./config.sh --url https://github.com/DROOdotFOO/raxol \
  --labels raxol --ephemeral --unattended --token "$TOKEN"
sudo ./svc.sh install ghrunner
sudo ./svc.sh start
```

```ini
# /etc/systemd/system/actions.runner.DROOdotFOO-raxol.<host>.service.d/harden.conf
[Service]
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictSUIDSGID=true
ReadWritePaths=/home/ghrunner/actions-runner
MemoryMax=6G
TasksMax=4096
# CPUQuota=400%
```

```nft
# /etc/nftables.conf: default-drop inbound, allow loopback, established, and tailscale
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif "lo" accept
    iifname "tailscale0" accept          # tailnet traffic, governed by ACLs above
    # no other inbound
  }
}
```

Then `sudo systemctl daemon-reload && sudo systemctl restart 'actions.runner.*'` and
`sudo nft -f /etc/nftables.conf`. Test that a job still runs (over-tight
`SystemCallFilter` or missing `ReadWritePaths` will break the runner or `nix develop`).

Join the tailnet tagged and with no inbound beyond the ACL:

```bash
sudo tailscale up --advertise-tags=tag:ci
```

### Registration PAT scope

The `tokenFile` should hold a fine-grained PAT, not a classic token:

- Resource owner: your account. Repository access: **only** `DROOdotFOO/raxol`.
- Permissions: **Administration: Read and write** (needed to register runners). Nothing
  else.
- Store it via agenix (NixOS, decrypts to tmpfs, root-only) or a root-owned `0400` file
  (manual hosts). Never in git or the Nix store. Rotate on a schedule and on any
  suspected compromise. This PAT can register runners, so treat it as the crown jewel.

## Verification checklist

- [ ] Runners show in Settings -> Actions -> Runners as ephemeral, repo-scoped, labelled
      `self-hosted, Linux, ARM64|X64, raxol`.
- [ ] Fork PR approval is required for all outside collaborators; `GITHUB_TOKEN` default
      is read-only.
- [ ] From a runner, `tailscale ping <another-non-ci-node>` fails (ACL denies lateral).
- [ ] From an admin node, SSH into a runner succeeds; from a runner, SSH to any node fails.
- [ ] The runner user has no sudo, no docker group, no SSH keys, and is not a Nix
      trusted-user.
- [ ] `systemctl show actions.runner.* -p MemoryMax,TasksMax` shows the caps (or the
      NixOS unit does).
- [ ] Host firewall drops inbound except loopback, established, and `tailscale0`.
- [ ] `flake.lock` and `mix.lock` are committed and current.
