defmodule Raxol.Agent.NativeHarness do
  @moduledoc """
  Behaviour for a native CLI harness: an external coding-agent CLI (Claude Code,
  Cursor, ...) that owns its own agent loop and tool dispatch.

  This is the "vendor owns the loop" half of the meta-harness. A backend built on
  a native harness reports `handles_tools_internally?() == true`, so the
  framework's ReAct loop does NOT drive tool calls; instead the CLI runs its own
  loop and Raxol's tools are injected into it over MCP (see
  `Raxol.Agent.Harness.McpToolConfig`).

  A harness driver is a small, mostly-pure module that knows three things about
  its CLI:

  - `executable/0` -- the binary name to look up on `PATH`.
  - `args/1` -- the argv (after the executable) to spawn one non-interactive run.
  - `parse_line/1` -- turn one line of the CLI's stdout into normalized events.

  The generic Port runtime (`Raxol.Agent.Backend.Native`) handles spawning,
  line framing, streaming, and exit/timeout. Drivers stay protocol-only and are
  trivially unit-testable.

  ## Normalized events

  `parse_line/1` returns a (possibly empty) list of these tuples, in order:

  - `{:text, binary}` -- assistant text to surface to the user.
  - `{:reasoning, binary}` -- chain-of-thought / thinking text.
  - `{:tool_call, map}` -- the CLI invoked a tool (observability only; the tool
    itself is served by the injected MCP server, not by the framework).
  - `{:done, %{content: binary, usage: usage()}}` -- the run finished;
    `content` is the final answer, `usage` is token accounting (may be empty).
  - `{:error, term}` -- the CLI reported an error.

  ## Usage must be translated, not passed through

  A `{:done, _}` event's `usage` map is required to speak raxol's vocabulary
  (`:input_tokens`, `:output_tokens`), never the vendor's. Nothing downstream
  translates, and a driver that forwards a vendor's own keys -- pi's
  `"input"`/`"output"`, say -- does not fail loudly. It disables three things
  at once (ADR-0034, "Gap 2"), each of which looks healthy in isolation:

  1. `Raxol.Agent.BenchmarkProfile.add_usage/2` (`benchmark_profile.ex:114-134`)
     reads only `:input_tokens`/`:prompt_tokens` and
     `:output_tokens`/`:completion_tokens`, atom or string. An unrecognized key
     accumulates as zero, so the turn prices at $0.00.
  2. `Raxol.Agent.Code.CostLedger.record/4` guards on `cost_usd > 0.0`
     (`code/cost_ledger.ex:33-34`), so that $0.00 turn is never recorded.
  3. `flag_unpriced/4` (`code/app.ex`) exists to catch exactly a $0.00 turn
     that burned tokens, but it asks `billed?/1` over `token_counts/1`, which
     calls that same `add_usage/2` and therefore also sees zero tokens. The
     fail-closed halt never arms.

  Net effect: a ledger reading $0.00 forever and a `RAXOL_MAX_COST_USD` that
  never trips. A budget that looks enforced and is not is worse than no budget,
  which is why this is a contract on every driver rather than a fix applied to
  one.

  ### Per-call usage is summed, not overwritten

  Where the CLI reports usage per LLM call and re-sends the conversation on
  each call, the driver reports the SUM across calls, not the last call's
  figure: each call's input is separately billed, so the last figure
  understates a tool loop by roughly its depth. The sum has to be in the single
  `{:done, _}` payload, because `Raxol.Agent.Backend.Native` forwards that map
  verbatim and never merges usage across events (`backend/native.ex:182-186`).
  """

  @type event ::
          {:text, binary()}
          | {:reasoning, binary()}
          | {:tool_call, map()}
          | {:done, %{content: binary(), usage: usage()}}
          | {:error, term()}

  @typedoc """
  Token accounting carried by a `{:done, _}` event, in raxol's vocabulary.

  `:input_tokens` and `:output_tokens` are the keys every consumer reads (the
  same names as strings are also accepted, since `BenchmarkProfile.add_usage/2`
  takes either). Extra provider-raw keys may ride along; the pricing path
  ignores what it does not recognize.

  An empty map is legal and means "this CLI reports no usage". A map keyed in
  the vendor's vocabulary is not: it is indistinguishable from the empty map to
  every consumer, and silently so. See "Usage must be translated, not passed
  through" above.
  """
  @type usage :: %{optional(atom() | binary()) => term()}

  @typedoc """
  Run configuration passed to `args/1`. Keys:

  - `:prompt` -- the user prompt for this run.
  - `:model` -- model id, or `nil` for the CLI default.
  - `:system_prompt` -- optional system/append prompt.
  - `:mcp_config_path` -- path to the MCP config file injecting Raxol tools, or
    `nil` when no tools are exposed.
  - `:cwd` -- working directory.
  - `:extra_args` -- raw argv appended verbatim.
  """
  @type run_config :: %{
          optional(:prompt) => binary(),
          optional(:model) => binary() | nil,
          optional(:system_prompt) => binary() | nil,
          optional(:mcp_config_path) => Path.t() | nil,
          optional(:cwd) => Path.t() | nil,
          optional(:extra_args) => [binary()]
        }

  @doc "The CLI binary name, looked up on `PATH`."
  @callback executable() :: String.t()

  @doc "The argv (after the executable) for one non-interactive run."
  @callback args(run_config()) :: [String.t()]

  @doc """
  Parse one stdout line into zero or more normalized events.

  A `{:done, _}` event's `usage` must already be in raxol's vocabulary
  (`t:usage/0`) when it leaves the driver, and must be the run's total rather
  than the last LLM call's. Both requirements are load-bearing for cost
  metering; see the moduledoc for what breaks when they are missed.
  """
  @callback parse_line(line :: String.t()) :: [event()]

  @doc "Human-readable harness name."
  @callback name() :: String.t()

  @doc """
  Whether this harness exposes Raxol tools to the CLI over MCP.

  When `true` (the default for tool-using harnesses), the runtime builds an MCP
  config from the agent's Actions and passes its path in `run_config.mcp_config_path`.
  """
  @callback injects_mcp_tools?() :: boolean()

  @optional_callbacks injects_mcp_tools?: 0

  @doc "Whether the CLI for `driver` is available on this machine."
  @spec available?(module()) :: boolean()
  def available?(driver) when is_atom(driver) do
    not is_nil(System.find_executable(driver.executable()))
  end

  @doc "Query `injects_mcp_tools?/0`, defaulting to `true`."
  @spec injects_mcp_tools?(module()) :: boolean()
  def injects_mcp_tools?(driver) when is_atom(driver) do
    if function_exported?(driver, :injects_mcp_tools?, 0) do
      driver.injects_mcp_tools?()
    else
      true
    end
  end
end
