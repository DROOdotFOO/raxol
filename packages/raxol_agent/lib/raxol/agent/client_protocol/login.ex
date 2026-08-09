defmodule Raxol.Agent.ClientProtocol.Login do
  @moduledoc """
  The interactive setup an ACP client launches for Terminal Auth.

  ACP clients cannot hand raxol a credential over the wire: the surface reads
  its provider from `Raxol.Agent.Backend.Resolver`, which wants a stored
  `op://` reference or a provider env var. Terminal Auth is the protocol's
  answer -- the client re-launches the SAME binary with the args the agent
  advertised, the user completes an interactive flow in a real terminal, and
  the client then starts a normal ACP session. That is what `raxol login` is.

  The logic lives in `Raxol.Agent.Setup`, which `mix raxol.setup` also drives,
  so a provider connected here resolves identically on every surface. This
  module is prompts and exit codes over that, nothing more.

  Nothing secret is written here. A raw key is turned into a 1Password
  reference by `Setup.connect_key/3` and only the reference reaches
  `~/.raxol/providers.json`.
  """

  alias Raxol.Agent.Setup

  @usage """
  Usage: raxol login [provider]

  Connect an LLM provider for the coding agent and every ACP session.

  With no provider, prints what is currently connected.

  Options:
    --status     print provider status and exit
    -h, --help   print this help
  """

  @switches [status: :boolean, help: :boolean]
  @aliases [h: :help]

  @doc """
  Run the interactive login. Returns an exit code.

  0 connected or status printed, 64 a usage error, 1 a provider that could not
  be stored or validated.
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, io \\ []) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help, false) -> print(io, @usage) && 0
      invalid != [] -> usage_error(io, invalid)
      Keyword.get(opts, :status, false) -> print_status(io)
      args == [] -> print_status(io)
      true -> connect(io, hd(args))
    end
  end

  defp usage_error(io, invalid) do
    print(io, "raxol login: unknown options: #{inspect(invalid)}\n\n#{@usage}")
    64
  end

  defp print_status(io) do
    %{op: op, providers: providers} = Setup.status()

    print(io, "1Password CLI: #{op}")

    connected = Enum.filter(providers, & &1[:available?])

    if connected == [] do
      print(io, "No provider connected. Run `raxol login <provider>`.")
    else
      Enum.each(connected, fn p -> print(io, "  #{p[:harness]} (#{p[:source]})") end)
    end

    0
  end

  # A key typed at a prompt, never echoed back and never written to disk as
  # itself -- Setup.connect_key/3 exchanges it for an `op://` reference.
  defp connect(io, provider) do
    case read_key(io, provider) do
      "" ->
        print(io, "raxol login: no key entered")
        1

      key ->
        provider
        |> Setup.connect_key(key)
        |> report(io, provider)
    end
  end

  defp report({:ok, _}, io, provider) do
    print(io, "Connected #{provider}.")
    0
  end

  defp report({:error, reason}, io, provider) do
    print(io, "raxol login: could not connect #{provider}: #{inspect(reason)}")
    1
  end

  defp read_key(io, provider) do
    case Keyword.get(io, :read_fn) do
      nil ->
        "Paste the API key for #{provider} (it is exchanged for a 1Password reference): "
        |> IO.gets()
        |> to_string()
        |> String.trim()

      fun ->
        fun.(provider)
    end
  end

  defp print(io, message) do
    case Keyword.get(io, :print_fn) do
      nil -> IO.puts(message)
      fun -> fun.(message)
    end

    true
  end
end
