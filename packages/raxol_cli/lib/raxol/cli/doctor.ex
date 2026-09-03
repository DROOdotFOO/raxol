defmodule Raxol.CLI.Doctor do
  @moduledoc """
  `raxol doctor` — what this install actually is, and why it resolves the way
  it does.

  Two audiences, one command. Someone who just installed and finds the agent
  answering with mock text needs to know no provider resolved, and which one it
  looked for. Someone reporting a bug needs to say which build they are on,
  which is not answerable from the release version alone: a months-old binary
  and one built minutes ago both call themselves `0.2.6`.

  The configuration half is `Raxol.Agent.Code.Inspection`, the same snapshot
  `mix raxol.inspect` and the TUI's `/inspect` render — reused rather than
  reimplemented, so all three agree. What this adds is the install header:
  build provenance, packaging, runtime, and whether the ACP surface is even
  compiled into this build (it is a source-build feature, so a Hex install of
  `raxol_agent` legitimately does not have one, and that is worth saying out
  loud rather than letting `raxol acp` fail later).
  """

  alias Raxol.Agent.Code.Inspection

  @acp_agent Raxol.Agent.ClientProtocol.StdioAgent

  @doc "Print the install report for `cwd`, returning an exit code."
  @spec run([String.t()]) :: non_neg_integer()
  def run(_args \\ []) do
    cwd = File.cwd!()

    IO.puts(header(cwd))
    IO.puts("")
    IO.puts(Inspection.render(Inspection.gather(cwd)))
    IO.puts("")
    IO.puts(next_steps())

    0
  end

  defp header(cwd) do
    [
      "raxol #{Raxol.CLI.version()}",
      row("packaging", packaging()),
      row("runtime", "elixir #{System.version()} / OTP #{otp_release()}"),
      row("acp surface", acp_surface()),
      row("cwd", cwd)
    ]
    |> Enum.join("\n")
  end

  defp row(label, value), do: "  #{String.pad_trailing(label, 12)}#{value}"

  # Burrito sets `__BURRITO=1` in the wrapped process's environment; the same
  # flag `Raxol.CLI.interactive?/0` branches on.
  defp packaging do
    if System.get_env("__BURRITO") == "1" do
      "packaged binary (burrito)"
    else
      "source build"
    end
  end

  defp otp_release, do: List.to_string(:erlang.system_info(:otp_release))

  # A capability question, not a version question: `StdioAgent` is compiled
  # only when `raxol_agent_client_protocol` was on the code path at build time.
  defp acp_surface do
    if Code.ensure_loaded?(@acp_agent) do
      "available (raxol acp)"
    else
      "NOT built in -- needs a source build of raxol_agent with " <>
        ":raxol_agent_client_protocol"
    end
  end

  defp next_steps do
    """
    next:
      connect or inspect providers:
        raxol setup

      start the agent:
        raxol

      coding TUI:
        raxol code

      component catalog:
        raxol playground

      scaffold an Elixir/Mix app:
        raxol new counter
    """
    |> String.trim_trailing()
  end
end
