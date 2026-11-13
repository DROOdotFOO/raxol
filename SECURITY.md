# Security policy

## Reporting a vulnerability

Report suspected vulnerabilities privately through GitHub security
advisories: [Report a vulnerability](https://github.com/DROOdotFOO/raxol/security/advisories/new).

Do not open a public issue for anything you believe is exploitable. You can
expect an acknowledgement within a few days; please include a reproduction
and the commit or release you tested.

## Supported versions

Only the latest published release line and master receive security fixes. No
specific number is named here on purpose: the previous revision said `2.7.x`,
which was not on Hex, and by exclusion withdrew support from the only versions
that were. Check Hex for what is published.

Pre-alpha packages (`raxol_earn`, `raxol_gateway`, `raxol_cli`,
`raxol_console`, `raxol_agent_client_protocol`, `raxol_web3`, `raxol_broker`)
carry no support commitment yet.

## Scope worth knowing about

- Provider credentials are stored as 1Password references only
  (`Raxol.Agent.Backend.Credentials`); a raw API key is never persisted.
  Findings that bypass that are in scope and high priority.
- `packages/raxol_payments` and `packages/raxol_earn` move funds on
  mainnets. Anything touching signing, spend limits, or settlement is in
  scope and highest priority.
- The SSH server (`Raxol.SSH.Server`) is fail-closed by design (no anonymous
  access unless explicitly configured); configuration-dependent findings are
  still welcome.
- `raxol mcp` serves Raxol apps as MCP tools over stdio to the client that
  spawned it (OMP), so its boundary is that OS process: whoever can write
  its stdin can call every tool it lists. It starts only modules on the
  startable list (the playground demos unless configured), refuses
  `raxol_start`'s `path` argument (starting from a path compiles the file),
  and serves `resources/read`
  only for the sessions it runs and the journals of the agents its `agent_*`
  tools act on; every other read is denied. Its `agent_*` tools start only the modules on
  `config :raxol_agent, :mcp_spawnable_apps` (a reference counter unless
  configured) and act only on agents this process started, or those listed
  in `:mcp_exposed_agents` (none unless configured). stdout is the JSON-RPC
  wire and carries nothing else. Anything that runs code a client chose
  beyond those modules, reads outside those sessions and journals, reaches
  an agent that is neither started by this process nor exposed, or puts a
  non-JSON-RPC byte on stdout is in scope.

## Dependency scanning

CI runs dependency and vulnerability scanning on every push
(`.github/workflows/security.yml`); reports for third-party advisories are
better filed upstream unless Raxol's usage is what makes them exploitable.
