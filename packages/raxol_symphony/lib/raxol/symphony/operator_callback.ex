defmodule Raxol.Symphony.OperatorCallback do
  @moduledoc """
  Canonical parser + builder for the `sym:` operator-action callback
  namespace from ADR-0018.

  Channels (Telegram inline keyboards, Watch notification actions,
  MCP `symphony_resume_run` tool, future Slack/Discord/SMS bots)
  send the operator's intent as a string in the `sym:` namespace.
  Without this module each surface invented its own parser; this
  module makes the parser shared so:

  - A multi-channel bot router can dispatch every callback through
    one switch.
  - `build_*` and `parse/1` are round-trip safe: a callback you
    construct on one channel parses identically on another.

  ## Vocabulary (ADR-0018 §3)

  | Callback                          | Returned                              |
  | --------------------------------- | ------------------------------------- |
  | `sym:refresh`                     | `:refresh`                            |
  | `sym:list`                        | `:list`                               |
  | `sym:dismiss`                     | `:dismiss`                            |
  | `sym:stop:<issue_id>`             | `{:stop, issue_id}`                   |
  | `sym:run:<issue_id>`              | `{:run_detail, issue_id}`             |
  | `sym:approve:<issue_id>`          | `{:approve, issue_id}` (legacy)       |
  | `sym:resume:<issue_id>:<decision>`| `{:resume, issue_id, decision}`       |
  | anything else                     | `{:unknown, raw_string}`              |

  `<decision>` is a string -- conventionally `"approved"` or
  `"rejected"` -- forwarded verbatim to the runner via
  `Orchestrator.resume_run/3`. The parser does not coerce.

  ## Examples

      iex> Raxol.Symphony.OperatorCallback.parse("sym:refresh")
      :refresh

      iex> Raxol.Symphony.OperatorCallback.parse("sym:stop:iss-1")
      {:stop, "iss-1"}

      iex> Raxol.Symphony.OperatorCallback.parse("sym:resume:iss-1:approved")
      {:resume, "iss-1", "approved"}

      iex> Raxol.Symphony.OperatorCallback.parse("sym:resume:iss-1:custom-decision")
      {:resume, "iss-1", "custom-decision"}

      iex> Raxol.Symphony.OperatorCallback.parse("not-a-sym-callback")
      {:unknown, "not-a-sym-callback"}
  """

  @typedoc """
  Parsed callback value.
  """
  @type parsed ::
          :refresh
          | :list
          | :dismiss
          | {:stop, binary()}
          | {:run_detail, binary()}
          | {:approve, binary()}
          | {:resume, binary(), binary()}
          | {:unknown, binary()}

  # --- Parsing ---

  @doc """
  Parse a `sym:`-namespace callback string. Returns a tagged tuple
  the caller can pattern-match.
  """
  @spec parse(binary()) :: parsed()
  def parse(raw) when is_binary(raw) do
    raw
    |> String.split(":")
    |> do_parse(raw)
  end

  defp do_parse(["sym", "refresh"], _raw), do: :refresh
  defp do_parse(["sym", "list"], _raw), do: :list
  defp do_parse(["sym", "dismiss"], _raw), do: :dismiss
  defp do_parse(["sym", "stop", id], _raw), do: {:stop, id}
  defp do_parse(["sym", "run", id], _raw), do: {:run_detail, id}
  defp do_parse(["sym", "approve", id], _raw), do: {:approve, id}
  defp do_parse(["sym", "approve"], _raw), do: {:approve, ""}
  defp do_parse(["sym", "resume", id, decision], _raw), do: {:resume, id, decision}
  defp do_parse(_other, raw), do: {:unknown, raw}

  # --- Builders ---
  #
  # Each builder is the inverse of `parse/1` for its tag. Tests pin
  # the round-trip (`parse(build_x(args)) == {:x, args}`).

  @doc "Build the orchestrator-tick callback string."
  @spec build_refresh() :: String.t()
  def build_refresh, do: "sym:refresh"

  @doc "Build the snapshot-list callback string."
  @spec build_list() :: String.t()
  def build_list, do: "sym:list"

  @doc "Build the dismiss-notification callback string."
  @spec build_dismiss() :: String.t()
  def build_dismiss, do: "sym:dismiss"

  @doc "Build a stop-run callback string for `issue_id`."
  @spec build_stop(binary()) :: String.t()
  def build_stop(issue_id) when is_binary(issue_id),
    do: "sym:stop:" <> issue_id

  @doc "Build a per-run detail callback string for `issue_id`."
  @spec build_run_detail(binary()) :: String.t()
  def build_run_detail(issue_id) when is_binary(issue_id),
    do: "sym:run:" <> issue_id

  @doc """
  Build a legacy approve callback string for `issue_id`. ADR-0018
  documents this as legacy; new channels SHOULD use `build_resume/2`
  with `"approved"` instead.
  """
  @spec build_approve(binary()) :: String.t()
  def build_approve(issue_id) when is_binary(issue_id),
    do: "sym:approve:" <> issue_id

  @doc """
  Build a resume-paused-run callback string. `decision` is forwarded
  verbatim to `Orchestrator.resume_run/3`; conventional values are
  `"approved"` and `"rejected"` but any string is allowed.

  ## Examples

      iex> Raxol.Symphony.OperatorCallback.build_resume("iss-1", "approved")
      "sym:resume:iss-1:approved"

      iex> cb = Raxol.Symphony.OperatorCallback.build_resume("iss-1", "approved")
      iex> Raxol.Symphony.OperatorCallback.parse(cb)
      {:resume, "iss-1", "approved"}
  """
  @spec build_resume(binary(), binary()) :: String.t()
  def build_resume(issue_id, decision)
      when is_binary(issue_id) and is_binary(decision),
      do: "sym:resume:" <> issue_id <> ":" <> decision
end
