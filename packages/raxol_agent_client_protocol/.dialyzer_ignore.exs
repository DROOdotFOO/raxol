[
  # ================================================================================
  # DIALYZER SUPPRESSIONS
  # ================================================================================
  #
  # Only warnings with a clear, documented cause are suppressed here. Each
  # entry names the exact pattern and why it's benign. See the sibling
  # `mix.exs` for the check's own flags (`:error_handling`, `:underspecs`).
  #
  # W7b hygiene pass, 2026-07-17.
  #
  # ================================================================================

  # ------------------------------------------------------------------------------
  # BROAD PUBLIC API SPECS (contract_supertype)
  # ------------------------------------------------------------------------------
  # These functions return a single constant/struct literal (an error code,
  # a protocol version, a `new/0` struct with its defaults, a registry atom,
  # etc.) but are deliberately spec'd against the wider public type
  # (`integer()`, `t()`, `atom()`, `map()`, ...) rather than the narrow
  # literal dialyzer infers, so the contract stays stable if the literal
  # ever needs to vary. Matches the main package's "BROAD PUBLIC API SPECS"
  # precedent (`../../.dialyzer_ignore.exs`).
  ~r"agent_client_protocol\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/application\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/error\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/ext/attach_policy\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/ext/attach_policy/token\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/ext/journal/writer\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/method_table\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/rpc\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/schema/agent_types\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/schema/client_types\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/schema/content\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/schema/ext\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/schema/lifecycle_extras\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/schema/session_update\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/schema/tool_call\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/schema/unstable\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/schema/version\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/session\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/transport/framer\.ex:\d+:contract_supertype",
  ~r"agent_client_protocol/transport/paired\.ex:\d+:contract_supertype",

  # tool_call.ex: ToolKind.default/0 and ToolCallStatus.default/0 are
  # spec'd `:: t()` (the full enum) for API consistency even though each
  # always returns its one documented default (`:other` / `:pending`) --
  # same "broad public spec" shape as contract_supertype above, just
  # surfaced as extra_range because t() is a union of literals.
  ~r"agent_client_protocol/schema/tool_call\.ex:\d+:extra_range",

  # ------------------------------------------------------------------------------
  # COMPILE-TIME ENV GUARD (flow narrowing)
  # ------------------------------------------------------------------------------
  # application.ex: `@auto_start Mix.env() != :test` is captured at compile
  # time (see the module's own "captured at COMPILE time" note). Under the
  # :dev env this package is dialyzed in, @auto_start is always `true`, so
  # `if @auto_start, do: children(), else: []` narrows to a single branch
  # and the `false`/empty-list arm reads as dead code to dialyzer. It is
  # very much alive under MIX_ENV=test.
  ~r"agent_client_protocol/application\.ex:\d+:pattern_match",

  # ------------------------------------------------------------------------------
  # DEFENSIVE TOTALITY (pattern_match_cov)
  # ------------------------------------------------------------------------------
  # token.ex: `strict_b64/1`'s `defp strict_b64(_), do: :error` catch-all is
  # unreachable given every current call site (all pass binaries), but the
  # function is spec'd `term()` -> total, no-crash-on-wire-input by design
  # (package convention). Keeping the catch-all is the point; narrowing the
  # spec to `binary()` would just move the warning, not remove the reason
  # for the clause.
  ~r"agent_client_protocol/ext/attach_policy/token\.ex:\d+:\d+:pattern_match_cov"
]
