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

- The coding agent (`mix raxol.code` / `mix raxol.p`) gates every mutating
  tool call through an ALLOW/ASK/DENY authorization engine, scopes file and
  shell tools to the working directory, and never persists raw API keys
  (1Password references only). Findings that bypass any of those properties
  are in scope and high priority.
- `packages/raxol_payments` and `packages/raxol_earn` move funds on
  mainnets. Anything touching signing, spend limits, or settlement is in
  scope and highest priority.
- The SSH server (`Raxol.SSH.Server`) is fail-closed by design (no anonymous
  access unless explicitly configured); configuration-dependent findings are
  still welcome.

## Dependency scanning

CI runs dependency and vulnerability scanning on every push
(`.github/workflows/security.yml`); reports for third-party advisories are
better filed upstream unless Raxol's usage is what makes them exploitable.
