# ADR-0032: Multi-root filesystem grants for agent sessions

## Status

Proposed, 2026-08-26. Nothing is implemented; this records the model and settles the platform
question before code is written.

Completes the `Sandbox.Filesystem` dimension that ADR-0020 named and deferred
(`packages/raxol_agent/lib/raxol/agent/sandbox.ex:22-26`: "Filesystem, Network, and Resource
dimensions are planned but deferred to a follow-up because their enforcement layer is
different"). This is that follow-up, and it lands inside ADR-0020's protocol rather than
beside it.

Supersedes the fix proposed in #912, which treated a Windows path-arithmetic defect as the
problem. The defect is real and two of its three sites are fixed (`Raxol.Core.Boundary.Path`
and the ACP `FsSandbox`, in #910). Its third site, `Raxol.Agent.Actions.Fs`, is left alone
here on purpose: patching the path math would preserve the containment model that is the
actual obstacle.

Revised 2026-08-26 during review. The single-root diagnosis and the grant model survive
unchanged. The enforcement mechanism does not: the first draft proposed FUSE, and a FUSE
mount does not confine a process. See "Alternatives considered".

## Context

`Raxol.Agent.Actions.Fs.resolve/2` (`fs.ex:253`) is a single-root jail. It expands a request
against one working directory, canonicalizes both sides, and requires a string prefix match
(`contained?/2`, `fs.ex:272`). Every fs tool resolves through it: `list_dir`, `read_file`,
`file_stat` in `actions/fs.ex`, and `write_file`, `edit_file`, `grep`, `glob` in
`actions/code.ex`. The one way out is `resolve_unconfined/2` (`fs.ex:234`), reachable only
after a per-call operator approval.

One root is the whole model, and five things do not fit inside it.

### Gap 1: one root cannot hold a git worktree

A linked worktree's `.git` is a file, and the path inside it is absolute:

```
$ git worktree add /tmp/wt
$ cat /tmp/wt/.git
gitdir: /Users/droo/CODE/raxol/.git/worktrees/wt

$ cat /Users/droo/CODE/raxol/.git/worktrees/wt/gitdir
/private/tmp/wt/.git
```

Both directions are absolute host paths. Every git operation in the worktree reads through
them into the main repository, so:

| cwd set to | worktree files | git metadata | verdict |
| ---------- | -------------- | ------------ | ------- |
| main repo | outside | inside | worktree unreadable |
| the worktree | inside | outside | git unusable |
| common parent | inside | inside | jail spans every sibling repo and worktree |

The first two fail. The third succeeds by giving up the containment that was the point, and
the tree already demonstrates it: this repository's own agent worktrees live under
`.claude/worktrees/`, inside the repo root, so they are "contained" today only because the
jail reaches every other worktree and the main tree at the same time.

A single root cannot express "these two disjoint subtrees, and nothing else", which is
precisely what a worktree is.

### Gap 2: scratch space is outside by construction

`System.tmp_dir!()` is never under a repo root. Agents that need a scratch file today either
get `:outside_cwd` or spend an operator approval per path. The rest of the codebase already
works around this from the outside: `Raxol.Symphony.Config` puts workspaces in
`tmp_dir!()/symphony_workspaces` (`config.ex:167`), and `Harness.McpToolConfig` mints
`tmp_dir!()/raxol_mcp_<n>` (`mcp_tool_config.ex:138`). Neither is inside any agent's jail.

### Gap 3: the shell is gated by name, never by path

The production shell tool is `Raxol.Agent.Actions.Code.Bash` (`code.ex:178`), which runs
`/bin/sh -c` on a Port (`code.ex:510`). It has two gates, and neither is a path boundary:
`shell_jail_allow/1` (`code.ex:447`) withholds the tool entirely from a jailed session, and
`sandbox_allow/2` (`code.ex:463`) matches the command against a `Raxol.Agent.Sandbox.Shell`
allowlist whose default comparison is the first whitespace token (`sandbox/shell.ex:111`).

A name allowlist is not containment. `sh -c`, `git -c core.pager=...`, and an absolute path in
any argument all pass a check that only reads the binary name. `{:cd, cwd}` is a starting
directory rather than a boundary. `Raxol.Agent.Code.Tenant` states the consequence and chooses
the safe side, and `code.ex:442-444` already names the mechanism this ADR is going to supply:

> until per-tenant OS confinement (separate uid / chroot / bwrap, wired as a
> `:shell_sandbox`) exists, the only safe posture is to withhold the shell entirely from a
> jailed session.

So a tenant gets a shell or gets containment. An in-process check cannot close this, because
the process doing the reading is not ours.

### Gap 4: four confinements, and the centralizing one has no callers

| Implementation | Live |
| -------------- | ---- |
| `Raxol.Agent.Actions.Fs.resolve/2` | yes, every agent fs tool |
| `Raxol.AgentClientProtocol.Client.FsSandbox.resolve/2` | yes, when a client opts into `fs_sandbox:` |
| `Raxol.Core.Boundary.Path.confine/3` | no production callers, only its own test |
| `Raxol.Symphony.PathSafety` | yes, lexical only, no symlink resolution |

`Boundary.Path` was written as the centralization target and the migration never landed, so
the hardened implementation with the 18 shared conformance vectors guards nothing the agent
actually runs. Meanwhile the live one is bound to no vectors at all.

The two disagree on a case that matters. `confine/3` does `Path.join(root, requested)`, so
`/etc/passwd` becomes `<root>/etc/passwd` and is accepted (accept vector
`absolute_requested_jailed_under_root`). `Fs.resolve/2` does `Path.expand(path, cwd)`, so
`/etc/passwd` stays absolute and is rejected (`fs_test.exs:39`). A drop-in swap would flip
behaviour for every tool, which is why the migration stalled.

### Gap 5: ADR-0020 reserved this dimension and deferred it

`Raxol.Agent.Sandbox` is accepted and implemented, with `Shell`, `SendAgent`, and `Async`
dimensions composed by `Sandbox.Chain`. `Sandbox.Filesystem` was specified in ADR-0020's table
(`workspace_only/0`, `allowlist/1`, `denylist/1`, `read_only/0`, `none/0`) and deferred
because its enforcement layer differs from a Directive gate. A new parallel filesystem model
would leave the tree with two, one consulted by the fs tools and one by the directive chain.

## Decision

Replace the single root with a **grant set**: an ordered list of real host paths, each
carrying its own rights, resolved through one seam. Enforcement becomes two consumers of that
one description rather than a property of it.

The grant set lands as `Raxol.Agent.Sandbox.Filesystem`, inside ADR-0020's protocol.

### The grant set

A grant is `{name, host_path, rights}` with `rights` in `:ro | :rw | :none`. Paths are real
host paths. Names are labels for display, policy authoring, and operator prompts, and never
appear inside a path.

```
grants
  repo       /Users/droo/CODE/raxol                 rw     (primary)
  gitdir     .../.git/worktrees/issue-912           rw
  gitcommon  /Users/droo/CODE/raxol/.git            rw
  gitconfig  .../.git/config, .../config.worktree   ro
  work       /tmp/raxol-wt/issue-912                rw
  scratch    /tmp/raxol-scratch-a1b2                rw     (owned, reaped)
```

Grants overlap by construction: `.git` sits inside the repo, and `.git/config` sits inside
`.git`. Resolution is **most-specific host prefix wins**, which is what Seatbelt (last match
wins) and Landlock (a nested rule restricts) already do, so all three enforcers read the same
grant set the same way.

`:none` stays representable and stays load-bearing. It is how a subtree is carved out of an
otherwise granted parent, and a grant set without it cannot express the git case below.

### Resolution

Containment stays `Raxol.Core.Boundary.Path.confine/3`, asked per grant instead of once
against a lone root, so no second containment implementation appears. Resolution runs in four
steps, and the ordering is what removes the `join` versus `expand` clash from Gap 4:

1. Expand the request against the primary grant, preserving today's `Fs.resolve/2` semantics
   for an absolute request.
2. Select the grant whose host path is the longest prefix of the expanded path.
3. Call `confine/3` with that grant's host path as `root` and the remainder as `requested`,
   where `Path.join` and `Path.expand` coincide, so the accept vector and the `Fs` behaviour
   agree instead of contradicting.
4. Check the grant's rights against the operation. A read needs `:ro` or `:rw`, a write needs
   `:rw`, and `:none` refuses both.

Two things fall out of adopting `confine/3` here. It returns the **real** path, where
`Fs.resolve/2` returns the lexical one while deciding containment on the real one, so
`File.read(abs)` currently re-follows symlinks that were only checked. And its five reasons
(`:path_traversal`, `:symlink_escape`, `:too_many_symlinks`, `:malformed_ref`,
`:invalid_input`) replace the single `:outside_cwd`, so an operator prompt can say which
boundary was crossed.

`resolve/2` and `outside_cwd?/2` collapse onto one function. They re-implement the same
decision twice today, kept in agreement only by a docstring saying they must never disagree.

### What the model sees

Paths are displayed relative to the primary grant when they fall inside it, and absolute
otherwise. This is already what `grep` and `glob` do (`Path.relative_to(&1, cwd)`,
`code.ex:337`), and it round-trips through `bash` and `git` because the shell's cwd is that
grant. A path in any other grant prints absolute, so it is unambiguous.

Grant names are deliberately not a path syntax. An agent reads paths and then types them into
free-text shell commands, and un-aliasing an arbitrary command line is not decidable.

### Git grants come from git

The git grants are derived by asking git, not by path arithmetic:

```
$ git rev-parse --path-format=absolute --show-toplevel --git-dir --git-common-dir
/private/tmp/wt
/Users/droo/CODE/raxol/.git/worktrees/wt
/Users/droo/CODE/raxol/.git
```

Three paths, all absolute, covering worktrees, submodules, and `--separate-git-dir` without
the caller reasoning about any of them. `--path-format=absolute` requires git 2.31 or newer;
without it `--git-dir` answers relatively in a normal checkout and absolutely in a worktree,
which is exactly the kind of case-by-case reasoning this avoids.

Both git directories are `:rw`. The first draft of this ADR marked the common dir `:ro` and
annotated it "makes /work usable"; it does the opposite. Git writes into both:

```
$ git -C /tmp/wt rev-parse --git-path index
/Users/droo/CODE/raxol/.git/worktrees/wt/index
$ git -C /tmp/wt rev-parse --git-path objects
/Users/droo/CODE/raxol/.git/objects
```

`git add` writes `index.lock` into the per-worktree directory and `git commit` writes objects,
refs, logs, and `packed-refs` into the common dir. Read-only on either produces
`fatal: Unable to create ... index.lock: Read-only file system`, which is openai/codex#23661
and openai/codex#27418 verbatim. The second of those is a sandbox that resolved the worktree
gitdir itself and marked it read-only, overriding an explicit write grant, which is the
failure mode "ask git" exists to avoid.

`config` and the per-worktree `config.worktree` are `:ro`. Git reads them normally and the
agent cannot repoint `core.hooksPath`, `core.pager`, `core.fsmonitor`, or `core.editor` at
something that would execute under the operator's identity on their next command.

**The hooks directory is asked for too, and the answer is often not `.git/hooks`.** In this
repository:

```
$ git rev-parse --git-path hooks
/Users/droo/CODE/raxol/.githooks
```

`core.hooksPath` points at a tracked directory in the working tree, so `.git/hooks` holds
nothing but samples and denying writes to it would accomplish nothing. Anthropic's
`sandbox-runtime` hardcodes `.git/hooks/` and `.git/config` in its mandatory write-deny list,
and on this repository half of that is a no-op. Where the resolved hooks path lands inside the
working tree it stays `:rw`, because it is source: an agent editing it is editing a tracked
file that shows up in `git status` and in the diff the operator reviews. The control that
holds in both layouts is the read-only config, which is what decides where hooks are read
from.

### The enforcement seam

The first draft defined one behaviour, `Enforcement`, with `resolve/2`, `open/3`, and
`list/2`. That signature is the trap: only a filesystem can answer `open/3` on behalf of a
process that is not ours, so the seam shape forced FUSE. There are two different jobs here,
and they take the same description.

```
Sandbox.Filesystem              the grant set, resolution, rights
  |
  +-- resolve/2                 in-BEAM, binds the fs tools
  |
  +-- compile/2 -> Spawn.wrap/3 compiles grants to an OS policy, binds a subprocess
        Spawn.Seatbelt          macOS, sandbox-exec -p <profile>
        Spawn.Bwrap             Linux, bubblewrap
        Spawn.None              explicit, no containment
```

One grant set, two consumers. The subprocess wrapper is where `:shell_sandbox`
(`code.ex:442-444`) finally gets an implementation, so `shell_jail_allow/1` can start asking
whether the session's shell will actually be contained.

`Spawn.Seatbelt` generates an SBPL profile and runs `/usr/bin/sandbox-exec -p <profile>`,
which ships with macOS and needs no install, no approval, and no reboot. `Spawn.Bwrap`
builds bind mounts from the same grants. Both are what OpenAI Codex and Anthropic's
`sandbox-runtime` converged on independently, and both inherit across every child the command
spawns, so a `postinstall` script is inside the same boundary as the command that ran it.

Selection is explicit rather than probed: a deployment asks for a backend and start-up fails
closed when the host cannot provide it. A jailed session silently degrading to a weaker
backend is the failure mode worth designing out.

### Why the OS layer is a spawn wrapper and never a NIF

Landlock is irreversible and inherited across `fork` and `exec`, and its `no_new_privs`
prerequisite is process-wide and irreversible as well. Calling either from a NIF would confine
the entire VM permanently: every scheduler, all file I/O, the distribution sockets, with no
way back. There is no call that sandboxes another process, only one that sandboxes the caller,
so the only correct shape is a launcher that restricts itself and then execs the target. The
repo already has the pattern in `Raxol.Earn.SignerSidecar`.

### What each layer guarantees

`resolve/2` confines a cooperating tool against path arithmetic and symlink escapes. It cannot
close a resolve-then-open race, because Erlang exposes no `openat` and no `O_NOFOLLOW`, so the
window between deciding and reading stays open. That is a permanent property of doing the I/O
in the BEAM, not a gap to be closed later.

The OS layer has no such window: Landlock rules are pinned by file descriptor, and Seatbelt
evaluates in the kernel at the moment of access. The table below says which guarantee applies
where rather than printing "contained" for both.

## Platform floor

The shell tool is POSIX-only today. `Actions.Code.Bash` runs `/bin/sh` (`code.ex:510`), so
there is no Windows shell to contain and a POSIX-only subprocess backend costs Windows nothing
it currently has.

| Host | Subprocess backend | Requires | fs tools | shell under `jail: true` |
| ---- | ------------------ | -------- | -------- | ------------------------ |
| macOS | `Seatbelt` | nothing, ships with the OS | confined, resolve-time | contained, enabled |
| Linux with bubblewrap and unprivileged userns | `Bwrap` | `bwrap` on PATH | confined, resolve-time | contained, enabled |
| Linux without either | `None` | | confined, resolve-time | disabled, as today |
| Windows | `None` | | confined, resolve-time | absent, as today |

So the floor is: **the grant set is the baseline and the supported configuration on every
platform, and an OS backend is an upgrade that, where the host allows it, unlocks one specific
capability: `jail: true` together with a working shell.**

Two deployment notes. Serving jailed sessions on Fly would need `bubblewrap` added to
`docker/Dockerfile.web`, whose runner is a slim Debian bullseye image
(`Dockerfile.web:6-9`) running as `USER nobody` (`:78`) with no sandbox tooling. And `sandbox-exec` is marked deprecated in its own man page; because the
grant set is data and the profile is generated from it, replacing that backend is a change to
one compile step rather than a redesign.

## Alternatives considered

**FUSE as the enforcement.** The first draft's `Enforcement.Fuse`, a real filesystem serving
the grant set so subprocesses see it too.

Rejected, and this is the change that prompted the revision. A FUSE mount adds a filesystem at
a mountpoint. It does not remove the rest of the tree from any process's view, so `sh -c 'cat
/etc/passwd'` succeeds beside a FUSE mount exactly as it does without one. Confinement needs a
mount namespace plus `pivot_root` (Linux, unprivileged user namespaces) or `chroot` as root
(macOS), and `mix raxol.code` can demand neither. So the backend would not deliver the single
capability it was justified by. It is also unreachable on the deployment target: `fly.toml`
declares no `[[mounts]]`, Fly Machines have no device or capability grant mechanism, and the
runner image carries no libfuse and no `fusermount`. macFUSE compounds it by being a
user-installed system extension needing approval and, on Apple Silicon, a reboot.

**Virtual paths mapped onto host paths.** The first draft's model, where a request names
`/repo/lib/foo.ex` and resolution rewrites it.

Rejected. The remapping is what forced FUSE: a virtual tree is only real to a subprocess if
something serves it. It also breaks git directly, since a worktree's `.git` file and its
backpointer both store absolute host paths, so git resolves its own metadata before any
policy is consulted. Seatbelt cannot remap at all, so the fs tools and the shell would
disagree about what a path means. Host paths make one description compile to every enforcer.

**A clone instead of a worktree.** Give each agent workspace its own `.git` so one root
suffices.

Rejected as a general answer. It removes the worktree case by removing worktrees, at the cost
of a full object copy per workspace, and the clone's `origin` is the main repository's path,
so fetching or pushing reaches outside the root again. It also leaves scratch space and the
shell exactly where they are.

**Keep the single root, widen the escalations.** Cheapest.

Rejected. Per-call operator approval is the wrong shape for a workspace. A worktree would need
approvals in a loop for a boundary the operator cannot reason about, which trains the operator
to approve blindly.

**Per-tenant uids or containers instead.** Complementary rather than competing, and stronger
for cross-tenant separation, which `Tenant` already notes this design does not solve ("one
BEAM, one uid"). It does not address worktrees or scratch inside a session, and does not
remove the need for a description of what a session may see.

**Depend on Anthropic's `sandbox-runtime`.** It already generates Seatbelt and bubblewrap
policy from a settings file and adds proxy-based network filtering.

Rejected as the mechanism, kept as a reference. It is an npm package whose config format is
explicitly a research preview, and taking it would put a Node dependency on the path of every
jailed shell command. Its filesystem model (host paths, allow-only writes, deny-then-allow
reads, a mandatory write-deny list) is close enough to this one that the design borrows from
it directly.

**Ship a static Landlock helper.** A small self-restricting launcher so Linux works without
bubblewrap or user namespaces, with rules pinned by file descriptor.

Deferred rather than rejected. It is the stronger Linux answer and the right one if bubblewrap
turns out to be unavailable where sessions are actually served, but it adds per-architecture
binaries to the Burrito and npm packaging and needs a Linux CI lane. Revisit once `Spawn.Bwrap`
exists and the grant set has settled.

## Consequences

### What becomes possible

Worktrees and scratch space become expressible, so an agent can hold a repo, a worktree, both
git directories, and a scratch area at once, with every grant visible in one place.

`jail: true` and the shell tool can coexist on hosts that run an OS backend, which is the
blocker `Tenant` documents and `code.ex:442-444` names.

`Actions.Fs.resolve/2` becomes a grant set with one `:rw` grant, so existing single-root
callers keep working while the model generalizes underneath them. #912's third site is then
fixed by construction: the drive-anchor handling lives in `Boundary.Path.confine/3`, already
fixed in #910 and now the per-grant primitive, retiring the hand-rolled `walk/3` that
hardcodes `"/"` as the filesystem root (`fs.ex:316`).

`Boundary.Path` stops being dead code, and the 18 shared vectors start guarding the
confinement the agent actually runs.

### What costs we accept

A grant set is more surface to get wrong than a prefix check, which argues for property tests
over the existing `boundary_vectors` corpus rather than a fresh set.

Two policy languages can drift from `resolve/2`. A grant set that the in-BEAM path and the
generated Seatbelt profile read differently is the failure that breaks agents subtly, so it
needs a test rather than a comment.

`resolve/2` keeps a resolve-then-open window on every platform. Stating it is the honest
posture; closing it would mean file I/O primitives Erlang does not expose.

Adopting `confine/3` changes observable behaviour on real repositories, which is why the
migration stalled once already: symlinked configs, `.asdf` shims, and monorepo package links
all resolve differently under it. The migration wants a release note.

### What this ADR does not decide

- **Network grants.** ADR-0020's `Sandbox.Network` dimension stays deferred. Both OS backends
  can express it and `sandbox-runtime` pairs it with an egress proxy, but it is a separate
  decision with its own failure modes.
- **Cross-tenant separation.** One BEAM, one uid, as `Tenant` already says. An OS backend
  contains a subprocess; it does not separate two tenants sharing a VM.
- **Windows subprocess containment.** No shell tool exists there today. Restricted tokens plus
  a dedicated local account is the shape if one ever does.
- **Whether the ACP `FsSandbox` converges.** It stays an intentional duplicate, since
  `raxol_agent_client_protocol` cannot depend on raxol_core. The shared vectors remain the
  drift guard.
- **Whether `Symphony.PathSafety` converges.** It carries a remote SSH root where
  `Path.expand` must not be used, which this model has no answer for.
- **Capability tokens.** ADR-0020 already parked "one token to write this path for five
  minutes" and it stays parked.
- **Grant-set persistence.** Whether a session's grants are recorded in the journal and
  replayed is left open.

## Validation

How we know the design is right, written as the tests an implementation must produce.

- **`Actions.Fs` binds to the shared conformance corpus.** It is the confinement the agent
  actually uses and it is bound to none of the 18 vectors in
  `packages/raxol_core/test/support/boundary_vectors/`. This is the single highest-value
  change in the migration, and it should land before the grant set does.
- **Git vectors.** A write into `.git/worktrees/<name>/index.lock` and into `.git/objects`
  both succeed; a write to the resolved `config` path is refused; a grant set derived from
  `git rev-parse` in a real worktree admits `git add` and `git commit` end to end.
- **An executable drift guard between the two vector trees.** The byte-identical rule lives in
  prose in three places and in nothing runnable, so adding a vector to raxol_core turns
  raxol_core red while the ACP package stays green against its stale copy.
- **A grant-set property**, extending the 500-iteration loop at `path_test.exs:216-243`: no
  accepted path resolves outside the union of granted host paths, and no `:ro` or `:none`
  grant admits a write.
- **A policy-compilation equivalence test**: over a corpus of paths, `resolve/2` and the
  generated Seatbelt profile return the same decision for the same grant set.
- **A fail-closed selection test**: a deployment that asks for `Spawn.Bwrap` on a host without
  it refuses to start rather than falling back to `Spawn.None`.
- **Existing behaviour unchanged**: with one `:rw` grant, every current `fs_test.exs` and
  `fs_context_cwd_test.exs` assertion holds, except the absolute-path case, which is a
  documented behaviour change.

## Prerequisites

A containment boundary should not land in a package nothing gates, and until #915 neither
`raxol_agent` nor `raxol_core` had a per-PR CI job. #915 adds both to the `package-tests`
matrix and is the prerequisite this ADR depends on.

It is not sufficient on its own. `package-tests` runs `ubuntu-latest` only, and the sole
non-Linux lane, `test-cross-platform` (`ci-unified.yml:670-683`), runs the root suite rather
than any package suite. So both packages gated still buys zero Windows coverage for `Fs`,
which is where #912 started. Closing that needs either an OS matrix on those two entries or
the vectors running in the root suite, and the ADR takes no position on which.

One mechanical constraint on editing that matrix:
`test/raxol/formatter_delegation_test.exs` parses it with `^\s*package: \[...\]`, so the list
must stay on one line, and an entry there moves together with the root `.formatter.exs`
`subdirectories` list.

## Defects surfaced while writing this

Both are context for the decision rather than part of it, and both want their own issue.

1. `Actions.Code.shell_jail_allow/1` (`code.ex:447`) re-enables the shell inside a jail for
   any `%Sandbox.Shell{}` present in the context, including `Sandbox.Shell.none()`, whose
   `allowed?/2` returns `true` unconditionally. The check is `match?` on the struct type, so
   the seam reads "a struct is present" where it means "the struct restricts". Nothing sets
   `:shell_sandbox` today, so the gate holds in practice, and this ADR's `Spawn` backends are
   what would first put a value there.
2. `Raxol.Symphony.Runners.RaxolAgent` never reads its `:workspace_path` option, so it passes
   no `:cwd` and no `:jail` into the agent context. Symphony's Raxol-side runs are unconfined
   by construction, while its Codex runner gets `thread_sandbox: "workspace-write"` from
   Codex's own sandbox.

## References

- #912: the Windows defect that surfaced the model, and the one site left for this ADR
- #910: `Boundary.Path.confine/3` and `FsSandbox` drive-anchor fix, and the shared vectors
- #915: gates `raxol_core` and `raxol_agent` in per-PR CI, the prerequisite above
- ADR-0020: `Raxol.Agent.Sandbox`, which reserved and deferred the Filesystem dimension
- ADR-0023: the gateway, for how a frozen contract plus optional backends has worked before
- ADR-0024: pluggable execution backends, for "opt-in behaviour, default stays local"
- `packages/raxol_agent/lib/raxol/agent/actions/fs.ex:200-364`: the single-root jail
- `packages/raxol_agent/lib/raxol/agent/actions/code.ex:434-513`: the shell gates and the spawn
- `packages/raxol_agent/lib/raxol/agent/sandbox.ex:22-26`: the deferred dimension
- `packages/raxol_agent/lib/raxol/agent/code/tenant.ex`: the shell hole, stated in the tree
- `packages/raxol_core/lib/raxol/core/boundary/path.ex:73-158`: the per-grant primitive
- `packages/raxol_core/test/support/boundary_vectors/`: the shared conformance corpus
- `packages/raxol_earn/lib/raxol/earn/signer_sidecar.ex`: the supervised OS helper pattern
- openai/codex#23661 and openai/codex#27418: read-only worktree gitdir, the failure this avoids
- `github.com/anthropic-experimental/sandbox-runtime`: host paths, allow-only writes, and a
  mandatory write-deny list
