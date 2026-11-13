defmodule Raxol.CLI.Doctor do
  @moduledoc """
  `raxol doctor` — what this install actually is.

  Someone reporting a bug needs to say which build they are on, which is not
  answerable from the release version alone: a months-old binary and one built
  minutes ago both call themselves `0.2.6`. So this prints build provenance,
  packaging, runtime, and whether the ACP surface is compiled into this build
  (a Hex install of `raxol_agent` has none) and can start an agent on this
  platform.

  It then lists the providers an agent could reach from this environment, from
  `Raxol.Agent.Setup.status/0`: each one that resolves, each one whose stored
  1Password reference cannot be read, and the state of the `op` CLI. A key or a
  reference is never printed.
  """

  alias Raxol.Agent.ClientProtocol.Serve
  alias Raxol.Agent.McpTools
  alias Raxol.Agent.Setup

  @doc "Print the install report for `cwd`, returning an exit code."
  @spec run([String.t()]) :: non_neg_integer()
  def run(_args \\ []) do
    IO.puts(header(File.cwd!()))
    IO.puts("")
    IO.puts(providers(Setup.status()))
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

  @doc false
  @spec acp_surface({atom(), atom()}) :: String.t()
  def acp_surface(os_type \\ :os.type()) do
    cond do
      not Serve.available?() ->
        "NOT built in -- needs a source build of raxol_agent with " <>
          ":raxol_agent_client_protocol"

      refusal = platform_refusal(os_type) ->
        "NOT available -- #{refusal}"

      true ->
        "available (raxol acp --agent <app>)"
    end
  end

  # Every `session/new` would be refused with the same words.
  defp platform_refusal(os_type) do
    case McpTools.platform_refusal(os_type) do
      :ok -> nil
      {:error, message} -> message
    end
  end

  @doc false
  @spec providers(%{op: atom(), providers: [map()]}) :: String.t()
  def providers(%{op: op, providers: providers}) do
    rows =
      providers
      |> Enum.filter(&(&1.available? or &1.note != nil))
      |> Enum.map(&provider_row/1)

    Enum.join(
      ["providers (op CLI: #{op_state(op)})" | rows_or_none(rows)],
      "\n"
    )
  end

  defp rows_or_none([]), do: ["  none connected"]
  defp rows_or_none(rows), do: rows

  defp provider_row(%{available?: true} = provider) do
    row(
      to_string(provider.harness),
      "#{provider.label}, via #{source(provider.source)}"
    )
  end

  defp provider_row(provider) do
    row(
      to_string(provider.harness),
      "#{provider.label}, not usable: #{provider.note}"
    )
  end

  defp op_state(op), do: op |> to_string() |> String.replace("_", " ")

  defp source(:op), do: "1Password reference"
  defp source(:env), do: "environment variable"
  defp source(:configured), do: "stored entry"
  defp source(other), do: to_string(other)

  defp next_steps do
    """
    next:
      serve a Raxol agent to an ACP editor:
        raxol acp --agent <app>

      serve Raxol apps as MCP tools:
        raxol mcp

      component catalog:
        raxol playground

      scaffold an Elixir/Mix app:
        raxol new counter
    """
    |> String.trim_trailing()
  end
end
