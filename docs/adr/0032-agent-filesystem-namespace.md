# ADR-0032: A mount namespace for agent filesystem access

## Status

Proposed, 2026-08-26. Nothing is implemented; this records the model and settles the
platform question before code is written.

Supersedes the fix proposed in #912, which treated a Windows path-arithmetic defect as the
problem. The defect is real and half of it is fixed (`Raxol.Core.Boundary.Path` and the ACP
`FsSandbox`, in #910). Its third site, `Raxol.Agent.Actions.Fs`, is left alone here on
purpose: patching the path math would preserve the containment model that is the actual
obstacle.

## Context

`Raxol.Agent.Actions.Fs.resolve/2` is a single-root jail. It expands a request against one
working directory, canonicalizes both sides, and requires a string prefix match
(`contained?/2`). Every fs tool (read, write, edit, list, grep, glob) resolves through it.
The one way out is `resolve_unconfined/2`, reachable only after a per-call operator approval.

One root is the whole model, and three things the coding agent needs do not fit inside it.

### Git worktrees cannot work, at any root

A worktree's `.git` is a file holding `gitdir: <main-repo>/.git/worktrees/<name>`. Every git
operation inside a worktree reads through it into the main repository. So:

| cwd set to | worktree files | `.git` common dir | verdict |
| ---------- | -------------- | ----------------- | ------- |
| main repo | outside | inside | worktree unreadable |
| the worktree | inside | outside | git unusable |
| common parent | inside | inside | jail spans everything, including other worktrees and unrelated repos |

The first two fail. The third succeeds by giving up the containment that was the point.
A single root cannot express "these two disjoint subtrees, and nothing else", which is
precisely what a worktree is.

### Scratch space is outside by construction

`System.tmp_dir!()` is never under a repo root. Agents that need a scratch file today either
get `:outside_cwd` or spend an operator approval per path. The rest of the codebase already
works around this: `Raxol.Symphony.Config` puts workspaces in
`System.tmp_dir!()/symphony_workspaces`, and `Harness.McpToolConfig` mints
`tmp_dir!()/raxol_mcp_<n>`. Those are outside any agent's jail.

### The shell tool is not confined at all

`Raxol.Agent.Actions.Shell` runs `/bin/sh -c` on a Port. A command line can `cd` anywhere or
name an absolute path, and `{:cd, work}` is a starting directory rather than a boundary.
`Raxol.Agent.Code.Tenant` states the consequence plainly, and chooses the safe side:

> The `work/` jail confines the *fs* tools [...]. It does NOT confine the shell [...]. So
> `jail: true` disables the shell tool entirely [...] until per-tenant OS confinement is
> wired.

So a tenant gets a shell or gets containment. An in-process check cannot close this, because
the process doing the reading is not ours.

## Decision

Replace the single root with a **namespace**: an ordered set of named mounts, each carrying
its own policy, resolved through one seam. Enforcement becomes a backend behind that seam
rather than a property of it.

### The model

```
namespace
  /repo       -> /Users/droo/CODE/raxol            rw
  /work       -> /tmp/raxol-wt/issue-912           rw
  /gitcommon  -> /Users/droo/CODE/raxol/.git       ro    <- makes /work usable
  /scratch    -> /tmp/raxol-scratch-a1b2           rw    (owned, auto-reaped)
  /system     -> /usr/lib, /etc/ssl                ro
```

A mount is `{name, host_path, mode}` with `mode` in `:ro | :rw | :none`. Resolution takes a
request, selects the longest matching mount prefix, and confines the remainder under that
mount's host path using the containment already proven in
`Raxol.Core.Boundary.Path.confine/3`: real-path resolution of both sides, re-checked after
symlink resolution, so a link out of a mount is refused rather than followed. The change is
that confinement is asked per mount instead of once against a lone root.

Two properties are load-bearing. Mounts are **disjoint by construction**: a path resolves
into exactly one mount, so `/work` reaching `/gitcommon` is an explicit grant rather than an
accident of a shared ancestor. And `:none` is representable, so a subtree can be carved out
of an otherwise granted mount.

### The enforcement seam

```
Raxol.Agent.Fs.Namespace        the model: mounts, policy, resolution
Raxol.Agent.Fs.Enforcement      behaviour: resolve/2, open/3, list/2
  Enforcement.InProc            in-BEAM checks; binds the fs tools; every platform
  Enforcement.Fuse              a real mount; binds every process; POSIX only
```

`InProc` is what `Actions.Fs.resolve/2` does today, taught to consult a namespace. `Fuse`
serves the same namespace as an actual filesystem, so a subprocess sees it too. The tools
call the seam and never learn which backend answered.

This ordering is not merely convenient. A FUSE filesystem has to be told what to serve, and
the namespace is that description. Building FUSE first would mean inventing the namespace
anyway, inside a NIF, untested on the platforms that cannot run it.

## Platform floor

This was the open question. It resolves against two facts already in the tree.

**The shell tool is POSIX-only today.** `Actions.Shell` runs
`System.find_executable("sh") || "/bin/sh"`. There is no Windows shell tool to contain, so
FUSE's inability to run on Windows costs Windows nothing it currently has.

**FUSE cannot be required anywhere.** macFUSE is a user-installed system extension needing
approval and, on Apple Silicon, a reboot. `mix raxol.code` cannot demand that. Containers need
`/dev/fuse` and elevated capability, which the Fly.io deployment does not grant today.

So the floor is: **the namespace is the baseline and the supported configuration on every
platform, and FUSE is an optional enforcement upgrade that, where the host allows it, unlocks
one specific capability: `jail: true` together with a working shell.**

| Host | Backend | fs tools | shell tool |
| ---- | ------- | -------- | ---------- |
| Linux with `/dev/fuse` | `Fuse` | contained | contained, and enabled under `jail: true` |
| Linux or macOS without it | `InProc` | contained | unchanged, still disabled under `jail: true` |
| macOS with macFUSE | `Fuse` | contained | contained |
| Windows | `InProc` | contained | absent, as today |

Selection is explicit rather than probed: a deployment asks for `Fuse` and start-up fails
closed if the host cannot provide it. A jailed session silently degrading to a weaker backend
is the failure mode worth designing out.

## Alternatives considered

**FUSE first, as the containment.** Strongest isolation, and the honest answer to
cross-tenant separation. Rejected as the starting point: it cannot be the only mechanism while
Windows is supported and macFUSE is optional, so a portable path is needed regardless, and
building it second means building it twice. Worth revisiting once `Fuse` exists and the
namespace has settled.

**Namespace only, no FUSE.** Fixes worktrees and scratch, portable, no packaging cost.
Rejected as the destination because it leaves `jail: true` and the shell mutually exclusive
permanently, which is the constraint multi-tenant hosting actually runs into.

**Keep the single root, widen the escalations.** Cheapest. Rejected: per-call operator
approval is the wrong shape for a workspace, and a worktree would need approvals in a loop
for a boundary the operator cannot reason about, which trains the operator to approve
blindly.

**OS-level isolation instead: uids or containers per tenant.** Complementary rather than
competing, and stronger for cross-tenant separation, which `Tenant` already notes this
design does not solve ("one BEAM, one uid"). It does not address worktrees or scratch inside
a session, and does not remove the need for a namespace to describe what a session may see.

## Consequences

Worktrees and scratch space become expressible, so an agent can hold a repo, a worktree, its
git common dir, and a scratch area at once, with the grants visible in one place.

`jail: true` and the shell tool can coexist on hosts that run `Fuse`, which is the blocker
`Tenant` documents.

`Actions.Fs.resolve/2` becomes a namespace with one `rw` mount, so existing single-root
callers keep working while the model generalizes underneath them. #912's third site is then
fixed by construction: the drive-anchor handling lives in `Boundary.Path.confine/3`, which is
already fixed and becomes the per-mount primitive, retiring the hand-rolled `walk/3` that
hardcodes `"/"` as the filesystem root.

Costs: a NIF or port for `Fuse`, plus deployment changes to grant it. A namespace is more
surface to get wrong than a prefix check, which argues for property tests over the existing
`boundary_vectors` corpus rather than a fresh set. And `Fuse` is the first thing in the tree
whose behaviour genuinely cannot be tested on a developer Mac without macFUSE, so its tests
need a Linux CI lane.

That last point runs into a gap this work should not paper over: **`raxol_agent` and
`raxol_core` have no per-PR CI job**, per the `package-tests` matrix and the note at
`ci-unified.yml:184` that `raxol_agent` is "a local gate, not a per-PR CI package". A
containment boundary should not land in a package nothing gates. Adding both to the matrix is
a prerequisite, not a follow-up.

## References

- #912: the Windows defect that surfaced the model, and the one site left for this ADR
- #910: `Boundary.Path.confine/3` and `FsSandbox` drive-anchor fix, and the shared vectors
- `packages/raxol_agent/lib/raxol/agent/actions/fs.ex`: the single-root jail
- `packages/raxol_agent/lib/raxol/agent/code/tenant.ex`: the shell hole, stated in the tree
- `packages/raxol_core/lib/raxol/core/boundary/path.ex`: the per-mount containment primitive
- `packages/raxol_core/test/support/boundary_vectors/`: the shared conformance corpus
- ADR-0023: the gateway, for how a frozen contract plus optional backends has worked before
