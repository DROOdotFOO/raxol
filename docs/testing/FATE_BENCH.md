# FATE Cross-Platform Test Bench

The FATE bench (after FFmpeg's Fast Audio Video Evaluation, plus checkasm's
reference-oracle idea) proves Raxol behaves identically across architectures, with
Nix pinning the toolchain so architecture is the only variable. The high-level layer
map lives in [ROADMAP.md](../../ROADMAP.md); this guide is the operator runbook for
Layer 1: running the `termbox2` NIF suite on self-hosted runners.

## Why self-hosted

GitHub-hosted CI sets `SKIP_TERMBOX2_TESTS=true` everywhere, so the `termbox2` NIF is
never built or exercised, and there is no aarch64-linux tier at all. Self-hosted
runners with real terminals close both gaps. The `.github/workflows/fate-selfhosted.yml`
workflow builds the NIF and runs the tty-dependent suite on both Linux architectures,
then compares the golden render hashes against `priv/fate/golden.refs`.

## The workflow

`fate-selfhosted.yml` runs one matrix job per architecture (`ARM64`, `X64`) on runners
carrying the `self-hosted`, `linux`, arch, and `raxol` labels. Each job, inside
`nix develop` (so the toolchain is flake-pinned and identical on every host):

1. Builds the NIF and runs the `:docker` suite under a pseudo-terminal (loading
   tests, the direct NIF tests, and the oracle equivalence test below).
2. Runs the platform `:requires_terminal` suite under a pseudo-terminal.
3. Runs the FATE golden render (pure, no terminal) to compare this architecture's
   hashes against the committed references.

Two mechanics matter:

- **`--include docker`, not `--only docker`.** The NIF-exercising tests in
  `packages/raxol_terminal/test/termbox2_nif/termbox2_nif_test.exs` are untagged (only
  the skip-branch placeholder carries `@moduletag :docker`). `--only docker` would skip
  the tests that actually drive the NIF, so the workflow names the files explicitly and
  uses `--include docker` to un-exclude the loading tests.
- **A pseudo-terminal wraps the whole `mix test`.** `Raxol.Terminal.TerminalUtils.real_tty?/0`
  gates the real test module, and that guard runs at compile time. `script -qec "<cmd>" /dev/null`
  (from `util-linux`, present in the devShell) gives the process both a tty on stdin/stdout
  (so `:io.columns/0` succeeds) and a controlling terminal (so `tb_init` can open
  `/dev/tty`). `TERM=xterm-256color` plus the `ncurses` terminfo let cap loading succeed.

### Reference-oracle equivalence

The oracle half of Layer 2 is the checkasm analogue: the termbox2 NIF (the optimized
path) must produce the same back buffer as a pure reference for the same op stream.

- `Raxol.Terminal.Termbox.Model` (in `packages/raxol_terminal/test/support/`) is the
  reference oracle: a small pure model of termbox2's cell semantics (cleared cell
  `{0x20, 0, 0}`, `set_cell` in-bounds writes, `print` lead-cell writes and advance).
  `termbox_model_test.exs` verifies the model independently, with no NIF or terminal,
  so it runs anywhere.
- A `tb_cell_buffer/0` NIF reads the back buffer back as a row-major list of
  `{ch, fg, bg}`. `oracle_equivalence_test.exs` applies each fixture op stream to the
  NIF and to the model and asserts the grids are identical, covering the explicit
  edges FATE requires: empty, wide CJK codepoints, attribute saturation, out-of-bounds
  writes, print clipping, and newlines. It needs `tb_init`, so it runs on the runners
  under the pseudo-terminal alongside the other `:docker` tests.

A failure names the fixture and the first few diverging cell indices. Print fixtures use
printable ASCII (advance is one column per cell); wide characters are covered through
`set_cell` storage, so the model never has to replicate `tb_wcwidth`.

### Security

`raxol` is a public repository, so these jobs must never run untrusted code on the
homelab. The workflow triggers only on `workflow_dispatch`, pushes to `master`, and the
nightly schedule (all trusted refs). There is no `pull_request` trigger, and an
`if: github.repository_owner == 'DROOdotFOO'` guard fences out forks. Run the runner
under an unprivileged user with no cloud credentials on the box.

Trigger fencing is only the first gate. A self-hosted runner is a remote-code-execution
surface and, on the tailnet, a lateral-movement pivot. Apply every layer in
[FATE_RUNNER_HARDENING.md](FATE_RUNNER_HARDENING.md) (ephemeral runners, process
isolation, resource caps, a default-deny Tailscale ACL, host firewall, minimal PAT scope)
before pointing real jobs at the hardware.

## Runner hosts

The homelab is 3 aarch64 Turing Pi boards, 1 x86_64 box, and 1 x86_64 NixOS laptop,
all on a Tailscale mesh. The build toolchain is flake-pinned on every host through
`nix develop`, so a hash divergence between architectures is a real determinism bug,
not environment drift.

### NixOS laptop

Import the `nixosModules.githubRunner` flake output into the host config and provide
the token and Tailscale key files with agenix. This is an example stanza (kept in docs
rather than as a live `nixosConfigurations` output so the hosted flake check does not
need this machine's hardware config):

```nix
{
  inputs.raxol.url = "github:DROOdotFOO/raxol";
  inputs.agenix.url = "github:ryantm/agenix";

  outputs =
    { nixpkgs, raxol, agenix, ... }:
    {
      nixosConfigurations.nixlaptop = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hardware-configuration.nix
          agenix.nixosModules.default
          raxol.nixosModules.githubRunner
          (
            { config, ... }:
            {
              age.secrets.gh-runner-token.file = ./secrets/gh-runner-token.age;
              age.secrets.ts-authkey.file = ./secrets/ts-authkey.age;

              raxol.ci.githubRunner = {
                enable = true;
                tokenFile = config.age.secrets.gh-runner-token.path;
                tailscaleAuthKeyFile = config.age.secrets.ts-authkey.path;
                extraLabels = [ "laptop" ];
              };
            }
          )
        ];
      };
    };
}
```

Apply with `nixos-rebuild switch --flake .#nixlaptop`. The module registers an ephemeral
runner (a clean workspace per job; a PAT `tokenFile` re-registers automatically after
each job) and joins the mesh. The runner picks up the `raxol`, `nix`, and arch labels.

### Non-NixOS hosts (Turing Pi boards, x86 box)

These run Nix on their base distro; the flake-pinned surface is the devShell, consumed
via `nix develop` in the workflow.

```bash
# 1. Install Nix (this installer enables flakes)
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install

# 2. Warm the flake so `nix develop` is fast (from a raxol checkout)
git clone https://github.com/DROOdotFOO/raxol.git && cd raxol
nix develop --command true

# 3. Install the GitHub Actions runner as a service under an unprivileged user.
#    Download the runner from Settings -> Actions -> Runners -> New self-hosted runner.
./config.sh --url https://github.com/DROOdotFOO/raxol \
  --labels raxol --unattended --token "$REGISTRATION_TOKEN"
sudo ./svc.sh install "$RUNNER_USER"
sudo ./svc.sh start

# 4. Join the Tailscale mesh
sudo tailscale up --auth-key "file:/etc/tailscale/authkey"
```

GitHub adds the `self-hosted`, `linux`, and arch labels (`ARM64` / `X64`) automatically;
the `raxol` label added here is what the workflow targets.

## Reproducibility

Commit `flake.lock` (run `nix flake lock` on a machine with Nix). Without it, both the
hosted flake check and the runner toolchains float on `nixos-unstable` HEAD, which
defeats "architecture is the only variable."

## Running it

Trigger from the Actions tab (`Run workflow`), or let the nightly schedule run it.
Acceptance: on both `ARM64` and `X64`, the NIF (`termbox2_nif.so`) builds, the
`:docker` and `:requires_terminal` suites pass, and `test/fate/golden_test.exs` matches
`priv/fate/golden.refs`.

When you change rendering on purpose and the golden step fails, regenerate the
references with `mix raxol.fate --gen` and commit them. The hashes are
architecture-independent, so a mismatch that appears on one architecture while another
stays green points at a determinism bug worth tracking down.
