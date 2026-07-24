defmodule Raxol.Agent.Harness.ToolClassifier do
  @moduledoc """
  The ONE place that decides whether a tool call is consequential — i.e.
  whether it must be held on a keyboard approval before it runs.

  Read-only tools (`read_file`, `list_dir`, `file_stat`, `glob`, `grep`)
  are auto-allowed: they observe the world, they do not change it, so
  gating them would be approval theater. Mutating / executing tools
  (`write_file`, `edit_file`, `run_shell`) are consequential: they change
  the filesystem or run arbitrary code, so they route through the live
  approvals path by default.

  The classification is by tool NAME (the LLM-facing `__action_meta__.name`),
  not by a `sensitive:` Action flag — `sensitive` means "deny outright"
  (fund-movers), which is a different verdict from "ask first". Keeping the
  list here means the gate (`Raxol.Agent.Harness.SessionInbox`) and its
  tests read the SAME truth; a new consequential tool is one line here, not
  a scattered set of string literals.

  An UNKNOWN tool name is treated as consequential (fail-closed): a tool the
  classifier has never heard of is exactly the case where a silent
  auto-allow would be the dangerous default.
  """

  @auto_allow ~w(read_file list_dir file_stat glob grep)
  @consequential ~w(write_file edit_file run_shell)

  @doc "Tool names that run without approval (read-only)."
  @spec auto_allowed() :: [String.t()]
  def auto_allowed, do: @auto_allow

  @doc "Tool names that require approval by default (mutating / executing)."
  @spec consequential() :: [String.t()]
  def consequential, do: @consequential

  @doc """
  Whether a tool call for `name` needs approval. Read-only names are
  `false`; everything else (known-consequential OR unknown) is `true` —
  fail-closed on an unrecognized name.
  """
  @spec consequential?(String.t() | nil) :: boolean()
  def consequential?(name) when is_binary(name), do: name not in @auto_allow
  def consequential?(_name), do: true
end
