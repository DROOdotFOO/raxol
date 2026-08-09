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

  A provider with a browser sign-in (`Raxol.Agent.Auth.Flow.providers/0`) gets
  it by default, since approving in a browser beats minting a key by hand.
  `--paste` forces the typed-key path, which is what a remote box wants: the
  flow's redirect lands on a loopback port, so the browser has to be on this
  machine.

  Nothing secret is written here either way. A raw key -- typed or minted by
  the provider -- is turned into a 1Password reference by `Setup.connect_key/3`
  and only the reference reaches `~/.raxol/providers.json`.
  """

  alias Raxol.Agent.Auth.Flow
  alias Raxol.Agent.Backend.Resolver
  alias Raxol.Agent.Setup

  @usage """
  Usage: raxol login [provider] [options]

  Connect an LLM provider for the coding agent and every ACP session.

  With no provider, prints what is currently connected.

  Providers with a browser sign-in use it by default; the rest prompt for a
  key. Pass --paste to type a key either way (use it over SSH: the sign-in
  redirect lands on a loopback port and needs a browser on this machine).

  Options:
    --paste      prompt for an API key instead of opening a browser
    --status     print provider status and exit
    -h, --help   print this help
  """

  @switches [paste: :boolean, status: :boolean, help: :boolean]
  @aliases [h: :help]

  @doc """
  Run the interactive login. Returns an exit code.

  0 connected or status printed, 64 a usage error, 1 a provider that could not
  be stored or validated.

  `io` is the injection bag: `:print_fn`, `:read_fn`, `:flow_fn` (the browser
  sign-in) and `:open_fn` (launching the browser), so a test drives this
  without a terminal and without opening a window.
  """
  @spec run([String.t()], keyword()) :: non_neg_integer()
  def run(argv, io \\ []) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    cond do
      Keyword.get(opts, :help, false) -> print_usage(io)
      invalid != [] -> usage_error(io, invalid)
      Keyword.get(opts, :status, false) -> print_status(io)
      args == [] -> print_status(io)
      true -> connect(io, hd(args), opts)
    end
  end

  defp print_usage(io) do
    print(io, @usage)
    0
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
      Enum.each(connected, fn p ->
        print(io, "  #{p[:harness]} (#{p[:source]})")
      end)
    end

    0
  end

  # Resolve the name before asking for anything: there is no reason to prompt
  # for a secret we already know we cannot store.
  defp connect(io, provider_str, opts) do
    case Resolver.harness_from_string(provider_str) do
      {:ok, provider} -> connect_provider(io, provider, opts)
      :error -> unknown_provider(io, provider_str)
    end
  end

  defp connect_provider(io, provider, opts) do
    if Keyword.get(opts, :paste, false) or not Flow.supported?(provider) do
      connect_key(io, provider)
    else
      connect_browser(io, provider)
    end
  end

  defp unknown_provider(io, provider_str) do
    print(io, "raxol login: unknown provider: #{provider_str}")
    known = Enum.map_join(Resolver.providers(), ", ", &to_string(&1.harness))
    print(io, "Known providers: #{known}")
    64
  end

  # A key typed at a prompt, never echoed back and never written to disk as
  # itself -- Setup.connect_key/3 exchanges it for an `op://` reference.
  defp connect_key(io, provider) do
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

  # The browser sign-in. The flow's own failure to launch a browser is NOT
  # fatal here the way it is over ACP: a terminal can print the URL, the
  # loopback port is still bound, and opening it by hand finishes the same
  # flow. So the browser seam reports and returns :ok, and only the deadline
  # ends the wait.
  defp connect_browser(io, provider) do
    flow_fn = Keyword.get(io, :flow_fn, &Flow.run/2)

    case flow_fn.(provider, browser_fn: browser_fn(io)) do
      {:ok, %{validation: validation}} ->
        print(io, "Connected #{provider}. #{validation_note(validation)}")
        0

      {:error, reason} ->
        print(io, "raxol login: #{Flow.describe(reason)}")

        print(
          io,
          "Run `raxol login #{provider} --paste` to enter a key instead."
        )

        1
    end
  end

  defp browser_fn(io) do
    open_fn = Keyword.get(io, :open_fn, &Flow.open_browser/1)

    fn url ->
      case open_fn.(url) do
        :ok ->
          print(io, "Opened your browser. Approve the sign-in there to finish.")

        {:error, _reason} ->
          print(
            io,
            "Could not open a browser. Open this URL to continue:\n\n  #{url}\n"
          )
      end

      :ok
    end
  end

  defp validation_note(:valid), do: "Credential validated."
  defp validation_note(:unsupported), do: "Stored (no validation endpoint)."

  defp validation_note(:unreachable),
    do: "Stored, but the provider was unreachable to validate."

  defp validation_note(_other), do: "Stored."

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
