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
  - `{:done, %{content: binary, usage: map}}` -- the run finished; `content` is
    the final answer, `usage` is token accounting (may be empty).
  - `{:error, term}` -- the CLI reported an error.
  """

  @type event ::
          {:text, binary()}
          | {:reasoning, binary()}
          | {:tool_call, map()}
          | {:done, %{content: binary(), usage: map()}}
          | {:error, term()}

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

  @doc "Parse one stdout line into zero or more normalized events."
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
