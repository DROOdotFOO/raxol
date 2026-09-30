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

  The Sleuth key is read from the environment at the moment a context is
  built and held only in the handle, which never renders it.

  `raxol_web3` is an optional dependency: in a build without it both
  functions are no-ops, and configuring `:web3` there raises at the first
  context build rather than serving a tool that cannot work.
  """

  @key_env "RAXOL_SLEUTH_API_KEY"

  @doc "Add `:web3_router` and `:fx_source` to a tool context, where configured."
  @spec put_context(map()) :: map()
  def put_context(context) when is_map(context) do
    context
    |> maybe_put(:web3_router, router())
    |> maybe_put(:fx_source, fx_source())
  end

  @doc "The `web3` and `fx` Actions for whatever is configured, else `[]`."
  @spec enabled_actions() :: [module()]
  def enabled_actions do
    for {module, value} <- [
          {Raxol.Agent.Actions.Web3, router()},
          {Raxol.Agent.Actions.FX, fx_config()}
        ],
        value != nil,
        do: module
  end

  @doc false
  @spec router() :: struct() | nil
  def router do
    case Keyword.get(config(), :router) do
      nil -> nil
      router -> require_web3!(router)
    end
  end

  @doc """
  The `Raxol.Web3.FX` handle, or `nil` when `:fx` is not configured.

  Raises when `:fx` is configured and the Sleuth key is absent: an `fx` tool
  in the toolset that answers every call with an auth refusal is worse than a
  boot that names the missing variable.
  """
  @spec fx_source() :: struct() | nil
  def fx_source do
    case fx_config() do
      nil -> nil
      opts -> require_web3!(opts) && build_fx(opts)
    end
  end

  defp fx_config, do: Keyword.get(config(), :fx)

  defp config, do: Application.get_env(:raxol_agent, :web3, [])

  if Code.ensure_loaded?(Raxol.Web3.FX) do
    defp build_fx(opts) do
      key = Keyword.get(opts, :sleuth_api_key) || non_empty_env(@key_env)

      if is_nil(key) do
        raise ArgumentError,
              "config :raxol_agent, :web3, fx: is set but #{@key_env} is not; " <>
                "set it or remove :fx"
      end

      {:ok, sleuth} = Raxol.Web3.FX.Sleuth.new(api_key: key)
      chainlink = Raxol.Web3.FX.Chainlink.new(rpc_urls: Keyword.get(opts, :rpc_urls, %{}))
      Raxol.Web3.FX.new(sleuth, chainlink)
    end

    defp require_web3!(value), do: value
  else
    defp build_fx(_opts), do: nil

    defp require_web3!(_value) do
      raise ArgumentError,
            "config :raxol_agent, :web3 is set but raxol_web3 is not in this build"
    end
  end

  defp non_empty_env(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> value
    end
  end

  defp maybe_put(context, _key, nil), do: context
  defp maybe_put(context, key, value), do: Map.put(context, key, value)
end
