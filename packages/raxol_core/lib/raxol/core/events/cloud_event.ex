defmodule Raxol.Core.Events.CloudEvent do
  @moduledoc """
  CloudEvents v1.0 envelope ([cloudevents.io](https://cloudevents.io/)).

  Standardized event metadata so raxol events can interoperate with
  webhook receivers, pub/sub fabrics, and message brokers without
  bespoke serialization. Conversion to and from `Raxol.Core.Events.Event`
  is provided by that module.

  ## Required fields

    * `:specversion` - "1.0"
    * `:id` - unique within the source
    * `:source` - URI-reference identifying the producer (e.g. `"raxol://node-1"`)
    * `:type` - reverse-DNS style event type (e.g. `"raxol.key"`)

  ## Optional fields

    * `:time` - `DateTime.t()` when the event occurred
    * `:data` - event payload (any term)
    * `:datacontenttype` - MIME type of `:data` (e.g. `"application/json"`)
    * `:subject` - subject of the event in the context of the source

  ## Examples

      ce = CloudEvent.new("raxol.key", "raxol://node-1",
        data: %{key: :enter, state: :pressed}
      )

      map = CloudEvent.to_map(ce)
      # => %{specversion: "1.0", id: "...", source: "raxol://node-1",
      #      type: "raxol.key", time: ~U[...], data: %{...}}

      {:ok, ce2} = CloudEvent.from_map(map)
  """

  @specversion "1.0"

  @type t :: %__MODULE__{
          specversion: String.t(),
          id: String.t(),
          source: String.t(),
          type: String.t(),
          time: DateTime.t() | nil,
          data: term() | nil,
          datacontenttype: String.t() | nil,
          subject: String.t() | nil
        }

  @enforce_keys [:id, :source, :type]
  defstruct specversion: @specversion,
            id: nil,
            source: nil,
            type: nil,
            time: nil,
            data: nil,
            datacontenttype: nil,
            subject: nil

  @doc """
  Construct a CloudEvent. `type` and `source` are required.

  ## Options

    * `:id` - explicit id (default: random 16 hex chars)
    * `:time` - `DateTime.t()` (default: `DateTime.utc_now/0`)
    * `:data` - event payload
    * `:datacontenttype` - MIME type of `:data`
    * `:subject` - subject of the event
  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(type, source, opts \\ [])
      when is_binary(type) and is_binary(source) do
    %__MODULE__{
      specversion: @specversion,
      id: Keyword.get(opts, :id) || generate_id(),
      source: source,
      type: type,
      time: Keyword.get(opts, :time, DateTime.utc_now()),
      data: Keyword.get(opts, :data),
      datacontenttype: Keyword.get(opts, :datacontenttype),
      subject: Keyword.get(opts, :subject)
    }
  end

  @doc """
  Returns the CloudEvent as a map suitable for JSON encoding.
  Nil-valued optional fields are dropped. Atom keys; convert to
  string keys at the serialization boundary if needed.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ce) do
    %{
      specversion: ce.specversion,
      id: ce.id,
      source: ce.source,
      type: ce.type
    }
    |> maybe_put(:time, ce.time)
    |> maybe_put(:data, ce.data)
    |> maybe_put(:datacontenttype, ce.datacontenttype)
    |> maybe_put(:subject, ce.subject)
  end

  @doc """
  Build a CloudEvent from a map (atom or string keys).

  Returns `{:error, :missing_required_field}` if `:id`, `:source`, or
  `:type` is absent. Unknown fields are dropped silently.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :missing_required_field}
  def from_map(map) when is_map(map) do
    with {:ok, id} <- fetch(map, :id),
         {:ok, source} <- fetch(map, :source),
         {:ok, type} <- fetch(map, :type) do
      {:ok,
       %__MODULE__{
         specversion: get(map, :specversion, @specversion),
         id: id,
         source: source,
         type: type,
         time: get(map, :time),
         data: get(map, :data),
         datacontenttype: get(map, :datacontenttype),
         subject: get(map, :subject)
       }}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch(map, key) do
    case get(map, key) do
      nil -> {:error, :missing_required_field}
      "" -> {:error, :missing_required_field}
      value -> {:ok, value}
    end
  end

  defp get(map, key, default \\ nil) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), default)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
