defmodule Raxol.Gateway.Delivery do
  @moduledoc """
  Sends a rendered outbound message to one of four destinations.

  `adapters` is a map of `platform => {adapter_module, conn}`, so a single gateway
  delivers across every connected platform. A destination is one of:

    * `{:direct, route}` -- reply to the originating chat.
    * `{:home, route}` -- a configured home channel (cron and background results).
    * `{:cross_platform, route}` -- a different platform's chat.
    * `{:target, "platform:chat_id"}` -- an explicit target string, e.g.
      `"telegram:-1001234567890"`.

  All four resolve to a `Raxol.Gateway.Route`; delivery then sends through that
  route's platform adapter. A target string's platform must match a connected
  adapter (no `String.to_atom/1` on the string).
  """

  alias Raxol.Gateway.Route

  @type adapters :: %{atom() => {module(), term()}}
  @type destination ::
          {:direct, Route.t()}
          | {:home, Route.t()}
          | {:cross_platform, Route.t()}
          | {:target, String.t()}

  @doc "Resolve a destination to a route and send `rendered` through its adapter."
  @spec deliver(adapters(), destination(), term()) :: :ok | {:error, term()}
  def deliver(adapters, destination, rendered) do
    with {:ok, route} <- resolve(destination, adapters),
         {:ok, {mod, conn}} <- adapter_for(adapters, route.platform) do
      mod.send_message(conn, route, rendered)
    end
  end

  @doc "Resolve a destination to the `Route` it delivers to."
  @spec resolve(destination(), adapters()) :: {:ok, Route.t()} | {:error, term()}
  def resolve({:direct, %Route{} = route}, _adapters), do: {:ok, route}
  def resolve({:home, %Route{} = route}, _adapters), do: {:ok, route}
  def resolve({:cross_platform, %Route{} = route}, _adapters), do: {:ok, route}

  def resolve({:target, target}, adapters) when is_binary(target),
    do: parse_target(target, adapters)

  def resolve(_destination, _adapters), do: {:error, :invalid_destination}

  defp parse_target(target, adapters) do
    case String.split(target, ":", parts: 2) do
      [platform_str, chat_id] when chat_id != "" ->
        case platform_atom(platform_str, adapters) do
          {:ok, platform} ->
            {:ok, Route.new(%{platform: platform, chat_type: :unknown, chat_id: chat_id})}

          :error ->
            {:error, {:unknown_platform, platform_str}}
        end

      _ ->
        {:error, {:bad_target, target}}
    end
  end

  defp platform_atom(platform_str, adapters) do
    Enum.find_value(Map.keys(adapters), :error, fn platform ->
      if Atom.to_string(platform) == platform_str, do: {:ok, platform}
    end)
  end

  defp adapter_for(adapters, platform) do
    case Map.get(adapters, platform) do
      {mod, conn} when is_atom(mod) -> {:ok, {mod, conn}}
      _ -> {:error, {:no_adapter, platform}}
    end
  end
end
