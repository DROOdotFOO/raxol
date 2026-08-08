# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately through GitHub security
advisories: [Report a vulnerability](https://github.com/DROOdotFOO/raxol/security/advisories/new).

Do not open a public issue for anything you believe is exploitable. You can
expect an acknowledgement within a few days; please include a reproduction
and the commit or release you tested.

## Supported versions

Only the latest published release line (2.6.x) and master receive security
fixes. Pre-alpha packages (`raxol_earn`, `raxol_symphony`, `raxol_gateway`,
`raxol_cli`, `raxol_console`, `raxol_agent_client_protocol`) carry no
support commitment yet.

## Scope worth knowing about

- The coding agent's interactive surface (`mix raxol.code`) gates every
  mutating tool call through an ALLOW/ASK/DENY authorization engine; its
  headless twin (`mix raxol.p`) denies mutating tools by default and only
  exposes them behind the explicit `--write` opt-in. File tools scope to
  the working directory, and raw API keys are never persisted (1Password
  references only). Findings that bypass any of those properties are in
  scope and high priority.
- `packages/raxol_payments` and `packages/raxol_earn` move funds on
  mainnets. Anything touching signing, spend limits, or settlement is in
  scope and highest priority.
- The SSH server (`Raxol.SSH.Server`) is fail-closed by design (no anonymous
  access unless explicitly configured); configuration-dependent findings are
  still welcome.
- Multi-tenant coding-agent hosting (`--ssh-tenants`, `RAXOL_SSH_CODE`) puts
  an untrusted principal at the keyboard of a session that holds the host's
  provider credential. The boundary is one BEAM under one uid, NOT separate
  OS users: it rests on the fs tools' path resolution, the `:jail` refusal of
  the shell tool, and the refusal to load workspace-configured commands
  (`.raxol/hooks.json`, `.mcp.json`) in a jailed session. Anything that
  executes code outside a tenant's `work/` jail, reads another tenant's
  workspace, sessions, or journal, or spends past that tenant's budget is in
  scope and high priority. Deployments handling mutually hostile tenants
  should add OS-level isolation on top.

## Dependency scanning

CI runs dependency and vulnerability scanning on every push
(`.github/workflows/security.yml`); reports for third-party advisories are
better filed upstream unless Raxol's usage is what makes them exploitable.
