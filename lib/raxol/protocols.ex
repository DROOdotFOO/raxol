defmodule Raxol.Protocols do
  @moduledoc """
  Defines protocols for the Raxol framework.
  """

  alias Raxol.Protocols.Protocol
  alias UUID

  @agent_name __MODULE__.Agent

  defp ensure_started do
    Raxol.Core.Utils.GenServerHelpers.ensure_started(
      @agent_name,
      fn -> Agent.start(fn -> %{} end, name: @agent_name) end
    )
  end

  def list_protocols do
    _ = ensure_started()
    Agent.get(@agent_name, &Map.values(&1))
  end

  def get_protocol(id) do
    _ = ensure_started()
    Agent.get(@agent_name, &Map.get(&1, id))
  end

  def create_protocol(attrs) do
    _ = ensure_started()

    protocol =
      attrs
      |> Map.put_new(:id, UUID.uuid4())
      |> Map.put_new(:created_at, DateTime.utc_now())
      |> Map.put_new(:updated_at, DateTime.utc_now())
      |> Protocol.new()

    _ = Agent.update(@agent_name, &Map.put(&1, protocol.id, protocol))
    protocol
  end

  def update_protocol(id, attrs) do
    _ = ensure_started()

    Agent.get_and_update(@agent_name, fn protocols ->
      case Map.get(protocols, id) do
        nil ->
          {nil, protocols}

        protocol ->
          updated =
            protocol
            |> Map.merge(attrs)
            |> Map.put(:updated_at, DateTime.utc_now())

          {updated, Map.put(protocols, id, updated)}
      end
    end)
  end

  def delete_protocol(id) do
    _ = ensure_started()

    _ =
      Agent.get_and_update(@agent_name, fn protocols ->
        {Map.get(protocols, id), Map.delete(protocols, id)}
      end)

    :ok
  end
end
