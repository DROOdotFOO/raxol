defmodule Raxol.Agent.Web3 do
  @moduledoc """
  Configuration for the web3 and FX tools, and the one place every runtime
  asks for them (ADR-0040 decision 5).

  Mirrors `Raxol.Agent.Skills`: a runtime calls `put_context/1` on its tool
  context and appends `enabled_actions/0` to its actions, unconditionally, and
  both are no-ops when nothing is configured.

      config :raxol_agent, :web3,
        # A `Raxol.Web3.Router`, built in runtime.exs. Enables the `web3` tool.
        router: Raxol.Web3.Router.new([...]),
        # Enables the `fx` tool. The Sleuth key is `RAXOL_SLEUTH_API_KEY`
        # (or `sleuth_api_key:` here); Chainlink needs RPC URLs for 1 and 8453.
        fx: [rpc_urls: %{1 => "https://...", 8453 => "https://..."}]

  The configuration is resolved once, by `load!/0`, which the `raxol_agent`
  application calls at boot. A mistake -- `:fx` without the Sleuth key, a key
  `Raxol.Web3.FX.Sleuth.new/1` refuses, a setting that is not a keyword list,
  or `:web3` in a build without `raxol_web3` -- refuses the boot and names what
  is wrong, rather than raising in every turn, inbox prompt or ACP session
  that builds a context. The key is read from the environment then, trimmed,
  and kept in the handle, which never renders it; changing it takes a restart.
  The variable stays in the node's environment, and the `bash` tool's
  `Raxol.Agent.Actions.Code.run_shell` unsets it in every shell child, so a
  command cannot print it.

  Outside a booted application (a library embedding, or `mix test`, where the
  application does not start), the first call resolves and caches it.
  """

  @key_env "RAXOL_SLEUTH_API_KEY"
  @cache {__MODULE__, :resolved}

  @type resolved :: %{router: struct() | nil, fx: struct() | nil}

  @doc "Add `:web3_router` and `:fx_source` to a tool context, where configured."
  @spec put_context(map()) :: map()
  def put_context(context) when is_map(context) do
    %{router: router, fx: fx} = resolved()

    context
    |> maybe_put(:web3_router, router)
    |> maybe_put(:fx_source, fx)
  end

  @doc "The `web3` and `fx` Actions for whatever is configured, else `[]`."
  @spec enabled_actions() :: [module()]
  def enabled_actions do
    %{router: router, fx: fx} = resolved()

    for {module, value} <- [
          {Raxol.Agent.Actions.Web3, router},
          {Raxol.Agent.Actions.FX, fx}
        ],
        value != nil,
        do: module
  end

  @doc """
  Resolve `config :raxol_agent, :web3` and cache the result for
  `put_context/1` and `enabled_actions/0`.

  Raises `ArgumentError` naming the problem when `:fx` is configured without
  the Sleuth key (an `fx` tool that answers every call with an auth refusal is
  worse than a boot that names the missing variable), when the key is one
  `Raxol.Web3.FX.Sleuth.new/1` refuses (a space or line break inside it; the
  message names where the key came from, never the key), when `:web3` or its
  `fx:` is not a keyword list (the message names the setting and its shape,
  never its value), or when `:web3` is configured in a build without
  `raxol_web3`. On a raise the previous cache is kept.
  """
  @spec load!() :: resolved()
  def load! do
    config = keyword!(Application.get_env(:raxol_agent, :web3, []), "config :raxol_agent, :web3")

    resolved = %{
      router: config |> Keyword.get(:router) |> resolve_router(),
      fx: config |> Keyword.get(:fx) |> resolve_fx()
    }

    :persistent_term.put(@cache, resolved)
    resolved
  end

  # Names the setting and the shape it has, never the value: an `fx:` value
  # can hold the Sleuth key.
  defp keyword!(value, setting) do
    if Keyword.keyword?(value) do
      value
    else
      raise ArgumentError,
            "#{setting} must be a keyword list, got #{shape(value)}"
    end
  end

  defp shape(value) when is_map(value), do: "a map"
  defp shape(value) when is_list(value), do: "a list that is not a keyword list"
  defp shape(value) when is_binary(value), do: "a string"
  defp shape(value) when is_boolean(value), do: "a boolean"
  defp shape(value) when is_atom(value), do: "an atom"
  defp shape(value) when is_number(value), do: "a number"
  defp shape(_value), do: "another term"

  defp resolved do
    case :persistent_term.get(@cache, nil) do
      nil -> load!()
      resolved -> resolved
    end
  end

  defp resolve_router(nil), do: nil
  defp resolve_router(router), do: require_web3!(router)

  defp resolve_fx(nil), do: nil

  defp resolve_fx(opts),
    do: opts |> keyword!("config :raxol_agent, :web3, fx:") |> require_web3!() |> build_fx()

  if Code.ensure_loaded?(Raxol.Web3.FX) do
    defp build_fx(opts) do
      {key, source} =
        case present(Keyword.get(opts, :sleuth_api_key)) do
          nil -> {present(System.get_env(@key_env)), @key_env}
          configured -> {configured, "config :raxol_agent, :web3, fx: [sleuth_api_key: ...]"}
        end

      if is_nil(key) do
        raise ArgumentError,
              "config :raxol_agent, :web3, fx: is set but #{@key_env} is not; " <>
                "set it or remove :fx"
      end

      # The reason names the refused argument, never the key.
      sleuth =
        case Raxol.Web3.FX.Sleuth.new(api_key: key) do
          {:ok, sleuth} ->
            sleuth

          {:error, reason} ->
            raise ArgumentError,
                  "the Sleuth key from #{source} was refused (#{inspect(reason)}): " <>
                    "it must be visible ASCII with no spaces or line breaks inside it"
        end

      chainlink = Raxol.Web3.FX.Chainlink.new(rpc_urls: Keyword.get(opts, :rpc_urls, %{}))
      Raxol.Web3.FX.new(sleuth, chainlink)
    end

    defp require_web3!(value), do: value

    # A key pasted with its trailing newline would otherwise reach the header,
    # where Mint refuses it as a transport error that names nothing.
    defp present(value) when is_binary(value) do
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
    end

    defp present(_value), do: nil
  else
    defp build_fx(_opts), do: nil

    defp require_web3!(_value) do
      raise ArgumentError,
            "config :raxol_agent, :web3 is set but raxol_web3 is not in this build"
    end
  end

  defp maybe_put(context, _key, nil), do: context
  defp maybe_put(context, key, value), do: Map.put(context, key, value)
end
