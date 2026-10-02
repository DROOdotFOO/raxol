# Raxol Broker

Guarded brokerage agents for Raxol. The package is pre-alpha.

Every order follows one fail-closed path: intent, policy, review, policy recheck,
placement, and journal. The runtime starts dry and requires an explicit arm before
any live order can be placed.

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

The generated policy has all eight required keys. `Raxol.Broker.PolicyFile.new/2`
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
  after_hours_market: false,
  llm_ask_above: :unset,
  ask_timeout: 30_000
]
```

| Key | Accepted value |
| --- | --- |
| `max_notional_per_order` | A `Decimal` strictly greater than zero. This cap is required and cannot be `:unset`. |
| `daily_notional_cap` | A `Decimal` strictly greater than zero. This cap is required and cannot be `:unset`. |
| `max_position_weight` | `:unset`, or a `Decimal` greater than zero and less than or equal to one. |
| `order_types` | A nonempty, duplicate-free list containing only the approved atoms `:market` and/or `:limit`. |
| `options` | A boolean. |
| `after_hours_market` | A boolean. |
| `llm_ask_above` | `:unset`, or a `Decimal` strictly greater than zero. |
| `ask_timeout` | An integer number of milliseconds from `1` to `4_294_967_295`; the generated default is `30_000` (30 seconds). |

`:unset` means that the corresponding optional threshold is not configured. It
is valid only for `max_position_weight` and `llm_ask_above`; it never satisfies
either required notional cap.

Policy files are data, not executable Elixir. The loader size-bounds the file,
parses it with existing atoms only, and accepts only the keyword-list literals
shown by this schema. Decimal values must use the exact
`Decimal.new("...")` form. Other calls, variables, operators, any other alias,
`throw`, `exit`, and side effects are rejected without being executed. Invalid,
malformed, or oversized policies fail closed, and a file that is not valid
UTF-8 returns `{:error, {:parse_error, path, :invalid_utf8}}`.

Before parsing, the loader applies the trust rules of
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
