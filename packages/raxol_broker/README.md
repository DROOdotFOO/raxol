# Raxol Broker

Fail-closed brokerage policy parsing, initialization and order evaluation,
plus a read-only Robinhood MCP session, for Raxol. The package is pre-alpha.
This release does not include order execution, arming, review, or journaling.

## Policy

Initialize a policy with explicit monetary caps:

```sh
mix raxol.broker.init --max-notional 1000 --daily-cap 5000
```

The command writes `broker.policy.exs` in the current directory. If either flag
is omitted, it prompts only when connected to a real terminal; noninteractive
use must supply both flags. A prompt accepts the entered line with surrounding
whitespace trimmed; end of input (EOF) fails with a `Mix.Error` and writes
nothing.

The generated policy has all thirteen required keys. `Raxol.Broker.PolicyFile.new/2`
is the single constructor for it: given the two required caps it returns
`{:ok, policy}` with every default filled in, or `{:error, reason}`:

```elixir
{:ok, policy} =
  Raxol.Broker.PolicyFile.new(Decimal.new("1000"), Decimal.new("5000"))
```

The rendered file is:

```elixir
[
  max_notional_per_order: Decimal.new("1000"),
  daily_notional_cap: Decimal.new("5000"),
  max_position_weight: :unset,
  order_types: [:limit],
  options: false,
  advanced_orders: false,
  after_hours_market: false,
  symbols_allow: :unset,
  symbols_deny: [],
  max_orders_per_minute: :unset,
  drawdown_halt: :unset,
  llm_ask_above: :unset,
  ask_timeout: 30_000
]
```

| Key | Accepted value |
| --- | --- |
| `max_notional_per_order` | A `Decimal` strictly greater than zero. This cap is required and cannot be `:unset`. |
| `daily_notional_cap` | A `Decimal` strictly greater than zero. This cap is required and cannot be `:unset`. |
| `max_position_weight` | `:unset`, or a `Decimal` greater than zero and less than or equal to one. |
| `order_types` | A nonempty, duplicate-free list containing only the approved atoms `:market`, `:limit`, `:stop_limit` and `:stop_market`. |
| `options` | A boolean. |
| `advanced_orders` | A boolean. |
| `after_hours_market` | A boolean. |
| `symbols_allow` | `:unset`, or a nonempty, duplicate-free list of uppercase symbol strings such as `"AAPL"` or `"BRK.B"`. |
| `symbols_deny` | A duplicate-free list of uppercase symbol strings; may be empty. |
| `max_orders_per_minute` | `:unset`, or an integer from `1` to `10_000`. |
| `drawdown_halt` | `:unset`, or a `Decimal` greater than zero and less than or equal to one: the share of the start-of-day value today's loss may reach. |
| `llm_ask_above` | `:unset`, or a `Decimal` strictly greater than zero. |
| `ask_timeout` | An integer number of milliseconds from `1` to `4_294_967_295`; the generated default is `30_000` (30 seconds). |

`:unset` means that the corresponding optional threshold is not configured and
its rule abstains, except `llm_ask_above`, where `:unset` asks for every
model-originated order. It is valid only for the optional keys; it never
satisfies either required notional cap.

Policy files are data, not executable Elixir. The loader size-bounds the file,
parses it with existing atoms only, and accepts only the keyword-list literals
shown by this schema. Decimal values must use the exact
`Decimal.new("...")` form. Other calls, variables, operators, any other alias,
`throw`, `exit`, and side effects are rejected without being executed. Invalid,
malformed, or oversized policies fail closed, and a file that is not valid
UTF-8 returns `{:error, {:parse_error, path, :invalid_utf8}}`.

Before parsing, the loader rejects symlinks and applies the trust rules of
`Raxol.Agent.OperatorFile.trusted?/1`: the file must be a regular file owned by
the account the VM runs as, with no group- or other-write bit, in a parent
directory that meets the same owner and mode rule or is sticky. Otherwise
loading returns `{:error, {:untrusted_file, path, reason}}`. A missing file or
a directory returns the missing-file or non-regular-file error instead.

Initialization renders and validates the complete policy before touching the
destination. It creates a same-directory staging file with mode 0600 before
writing to it, writes and syncs it, then applies the same file and directory
trust checks before publishing the final name atomically without replacement.
An unsafe destination directory is refused without leaving a policy or staging
file. An existing file or symlink is left unchanged, and the staging file is
removed after successful publication or an ordinary error.

## Evaluating an order

```elixir
{:ok, intent} = Raxol.Broker.Intent.buy_usd("AAPL", Decimal.new("250"), provenance: :llm)

Raxol.Broker.Policy.evaluate(intent, %Raxol.Broker.Policy.Context{policy: policy, ...})
# => {:allow, intent} | {:ask, [{rule_id, prompt}]} | {:deny, {rule_id, detail}}
```

`Raxol.Broker.Intent` constructors validate model-supplied input and return
`{:error, reason}` instead of raising; `:provenance` (`:strategy`, `:llm`,
`:human` or `{:untrusted, source}`) is required. `Raxol.Broker.Policy.evaluate/2`
reads only the intent and its `Raxol.Broker.Policy.Context` (portfolio value,
positions, quotes, today's notional, orders in the last minute, market session,
review warnings) and does no I/O. Its rules run through
`Raxol.Agent.Authorization.Engine`: any DENY wins, otherwise any ASK, otherwise
ALLOW. `Policy.rule_ids/0` lists the stable rule ids in evaluation order; the
`Raxol.Broker.Policy` moduledoc describes each rule.

Caps are inclusive. A rule that needs a context field left `nil` denies; an
invalid policy or a context field of the wrong type denies before any rule
runs. Untrusted provenance always asks. Cancels are always allowed.

## Robinhood sign-in

```elixir
:ok = Raxol.Broker.Login.run()
{:ok, session} = Raxol.Broker.MCP.Client.start_link([])
{:ok, tools} = Raxol.Broker.MCP.Client.list_tools(session)
{:ok, result} = Raxol.Broker.MCP.Client.call(session, "get_accounts", %{})
```

`Login.run/1` opens the browser on Robinhood's consent page and waits for the
redirect on `http://127.0.0.1:<port>/callback`. The endpoints are pinned in
`Raxol.Agent.Auth.Robinhood`; discovery metadata is fetched only to confirm
them, and any difference stops the sign-in. The client registers itself
(dynamic client registration, public client, PKCE S256), and the callback must
carry the `state` it sent and `iss` equal to
`https://agent.robinhood.com/mcp/trading`. The resulting credential is written
encrypted; nothing is stored if any step fails.

### Credential at rest

`Raxol.Broker.CredentialStore` keeps the credential in
`~/.raxol/broker/robinhood.credential` (override with
`$RAXOL_BROKER_CREDENTIAL`) as an AES-256-GCM envelope. The 256-bit key lives
in 1Password when the `op` CLI is installed, otherwise in the macOS login
keychain (service `raxol.broker.credential-key`, account `robinhood`). On any
other system without `op` there is no key store, and the store returns
`{:error, {:keychain_unavailable, :unsupported_os}}` instead of writing.

The keychain item is created by `security`, so any process running as the
same user can read it without a prompt. The keychain protects copies of
`~/.raxol` that leave the machine (backups, dotfile sync), not the running
account. The key is written over stdin and never appears in a process's
arguments.

### Session

`Raxol.Broker.MCP.Client` is the only path to the MCP server. It refreshes the
token shortly before it expires. On a 401 it refreshes once, however many
callers are waiting, stores the rotated refresh token before using the new
access token, and retries each request once. If the refreshed token is refused
too, every call returns `{:error, :unauthorized}` until you sign in again; the
session stops talking to the server but does not crash.

Only the tools Robinhood marks read-only (`get_*`, `preview_scan`, `run_scan`,
`search`) can be called. Orders, cancels, reviews, watchlist, alert and scan
changes, and unknown names return `{:error, {:tool_denied, name}}` without a
request, and `list_tools/1` lists only the allowed tools.
