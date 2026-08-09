defmodule Raxol.Agent.Auth.Flow do
  @moduledoc """
  The browser OAuth sign-in, end to end: bind a loopback port, send the user to
  the provider, catch the redirect, exchange the code, store the credential.

  This is what ACP calls Agent Auth. `Raxol.Agent.ClientProtocol.StdioAgent`
  advertises it and calls `run/2`; the flow itself knows nothing about ACP, so
  the TUI's `/login` and `mix raxol.setup` can drive the same thing.

  Only providers in `providers/0` have a real flow. Asking for any other is
  `{:error, {:no_oauth_flow, provider}}` rather than a wait that never ends --
  a sign-in that hangs is worse than one that was never offered.

  The credential lands through `Raxol.Agent.Setup`, so a provider connected
  here resolves identically on every surface, and nothing secret is written:
  the minted key becomes a 1Password item and only its `op://` reference is
  stored. Without the `op` CLI there is nowhere to put a key, and the flow
  fails rather than falling back to plaintext.

  Every step is a seam (`:browser_fn`, `:http_fn`, `:store_fn`) so the whole
  path is testable without a browser or a network call.
  """

  alias Raxol.Agent.Auth.Loopback
  alias Raxol.Agent.Auth.OpenRouter
  alias Raxol.Agent.Auth.Pkce
  alias Raxol.Agent.Setup

  # Long enough for a real sign-in (password manager, MFA, an account switch),
  # short enough that an abandoned tab returns the port.
  @default_timeout 180_000

  # The 1Password write, not the sign-in: see `default_store/2`.
  @store_timeout 120_000

  @providers [:openrouter]

  @type result :: %{provider: atom(), validation: term()}

  @doc "Providers with a browser sign-in raxol actually implements."
  @spec providers() :: [atom()]
  def providers, do: @providers

  @doc "Whether `provider` has a browser sign-in."
  @spec supported?(atom()) :: boolean()
  def supported?(provider), do: provider in @providers

  @doc """
  Run the sign-in for `provider`.

  Options: `:timeout` (ms to wait for the redirect), `:browser_fn`,
  `:http_fn`, `:store_fn`, and `:path` for the callback path.

  Returns `{:ok, %{provider: provider, validation: validation}}` or
  `{:error, reason}`; `describe/1` renders a reason for a user.
  """
  @spec run(atom(), keyword()) :: {:ok, result()} | {:error, term()}
  def run(provider, opts \\ [])

  def run(:openrouter, opts) do
    pkce = Pkce.new()
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Loopback.open(Keyword.take(opts, [:path])) do
      {:ok, listener} ->
        try do
          collect(:openrouter, listener, pkce, timeout, opts)
        after
          Loopback.close(listener)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(provider, _opts), do: {:error, {:no_oauth_flow, provider}}

  defp collect(provider, listener, pkce, timeout, opts) do
    url = OpenRouter.authorize_url(pkce, Loopback.redirect_uri(listener))
    browser_fn = Keyword.get(opts, :browser_fn, &open_browser/1)

    with :ok <- launch(browser_fn, url),
         {:ok, code} <- Loopback.await(listener, timeout),
         {:ok, key} <- OpenRouter.exchange(code, pkce, opts),
         {:ok, validation} <- store(provider, key, opts) do
      {:ok, %{provider: provider, validation: validation}}
    end
  end

  # A browser we cannot launch is reported WITH the URL: the challenge in it is
  # public by PKCE's design, the loopback port is still bound, and pasting it
  # by hand completes the same flow. The verifier stays here.
  defp launch(browser_fn, url) do
    case browser_fn.(url) do
      :ok ->
        :ok

      {:error, {:no_browser_opener, tool}} ->
        {:error, {:no_browser_opener, tool, url}}

      {:error, reason} ->
        {:error, {:browser_failed, reason, url}}

      _other ->
        {:error, {:browser_failed, :unexpected_return, url}}
    end
  end

  # A key the provider will not authorize is not a completed sign-in, so a
  # rejection fails the flow even though the reference was stored. Every other
  # validation outcome (including "could not check right now") is a success:
  # the credential resolves, and the first turn is where a bad one surfaces.
  defp store(provider, key, opts) do
    store_fn = Keyword.get(opts, :store_fn, &default_store/2)

    case store_fn.(provider, key) do
      {:ok, _provider, _ref, {:rejected, status}} ->
        {:error, {:key_rejected, status}}

      {:ok, _provider, _ref, validation} ->
        {:ok, validation}

      {:error, reason} ->
        {:error, {:store_failed, reason}}
    end
  end

  # 1Password raises its approval prompt at the worst moment in this flow: the
  # instant the user gets back from a browser tab, attention still there. The
  # default `op` budget is 15s, and losing that race discards a key the
  # provider has already minted -- so the user pays for the round trip twice
  # and leaves a dangling key behind. This path buys a lot more room.
  defp default_store(provider, key) do
    Setup.connect_key(provider, key, timeout_ms: @store_timeout)
  end

  # -- browser ----------------------------------------------------------------

  @doc """
  Open `url` in the user's default browser.

  Both output streams are captured, never inherited: on the ACP surface stdout
  is the JSON-RPC wire, and one line from `xdg-open` would be a parse error at
  the client.
  """
  @spec open_browser(String.t()) :: :ok | {:error, term()}
  def open_browser(url) when is_binary(url) do
    {tool, args} = browser_command(url)

    case System.find_executable(tool) do
      nil ->
        {:error, {:no_browser_opener, tool}}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:exit, status, String.trim(output)}}
        end
    end
  rescue
    error -> {:error, error}
  end

  defp browser_command(url) do
    case :os.type() do
      {:unix, :darwin} -> {"open", [url]}
      {:win32, _} -> {"cmd", ["/c", "start", "", url]}
      {:unix, _} -> {"xdg-open", [url]}
    end
  end

  # -- reporting --------------------------------------------------------------

  @doc "Render a `run/2` failure for a person, without leaking the URL's twin secret."
  @spec describe(term()) :: String.t()
  def describe({:no_oauth_flow, provider}) do
    "#{provider} has no browser sign-in; connect it with `raxol login #{provider}`"
  end

  def describe({:no_browser_opener, tool, url}) do
    "could not find #{tool} to open a browser; open this URL to continue: #{url}"
  end

  def describe({:browser_failed, reason, url}) do
    "could not open a browser (#{inspect(reason)}); open this URL to continue: #{url}"
  end

  def describe(:timeout), do: "timed out waiting for the browser redirect"

  def describe({:oauth_error, error, nil}),
    do: "the provider refused the sign-in: #{error}"

  def describe({:oauth_error, _error, description}),
    do: "the provider refused the sign-in: #{description}"

  def describe({:exchange_rejected, status}),
    do: "the provider rejected the authorization code (HTTP #{status})"

  def describe({:exchange_unreachable, _reason}),
    do: "could not reach the provider to exchange the code"

  def describe(:no_http_client),
    do: "no HTTP client available to exchange the code"

  def describe({:no_key_in_response, _keys}), do: "the provider returned no key"

  def describe(:no_key_in_response), do: "the provider returned no key"

  def describe({:key_rejected, status}),
    do: "the provider would not authorize the new key (HTTP #{status})"

  def describe({:store_failed, :op_unavailable}) do
    "signed in, but the 1Password CLI (`op`) is not available to store the key; " <>
      "raxol never writes a key to disk"
  end

  def describe({:store_failed, :op_timeout}) do
    "signed in, but 1Password did not answer in time to store the key -- " <>
      "unlock the desktop app and run it again"
  end

  def describe({:store_failed, reason}),
    do: "could not store the key: #{inspect(reason)}"

  def describe({:listen_failed, reason}),
    do: "could not bind a local port for the redirect: #{inspect(reason)}"

  def describe(reason), do: inspect(reason)
end
