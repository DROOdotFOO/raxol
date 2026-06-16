defmodule Raxol.Agent.Tunnel.Frame do
  @moduledoc """
  Wire frame for the reverse co-driving tunnel.

  A single outbound link carries many logical channels, demultiplexed by
  `channel_id`. Four frame kinds ride the link (ported from omnigent's
  `ws.open` / `ws.frame` / `ws.close` plus a hello handshake):

    * `:hello` -- sent once by the host after it dials out; carries its identity
      and capabilities. `channel_id` is `nil`.
    * `:open` -- open a new channel; payload `%{"path", "meta"}`. The opener
      allocates the `channel_id`; the peer spawns the channel's local handler.
    * `:data` -- channel I/O; payload `%{"data", "binary"}` (base64 when binary).
    * `:close` -- close a channel; payload `%{"code", "reason"}`.

  Frames serialize to JSON so any byte transport (a real WebSocket, an in-memory
  link) can carry them. Decoding maps the kind through an explicit whitelist --
  never `String.to_atom/1` on link input.
  """

  @type kind :: :hello | :open | :data | :close

  @type t :: %__MODULE__{
          channel_id: binary() | nil,
          kind: kind(),
          payload: map()
        }

  @enforce_keys [:kind]
  defstruct [:channel_id, :kind, payload: %{}]

  @doc "Generate a fresh channel id (4 random bytes, lowercase hex)."
  @spec new_channel_id() :: binary()
  def new_channel_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  @doc "A host hello frame announcing identity + capabilities."
  @spec hello(binary(), [binary()]) :: t()
  def hello(host_id, capabilities) do
    %__MODULE__{kind: :hello, payload: %{"host_id" => host_id, "capabilities" => capabilities}}
  end

  @doc "An open frame for `channel_id` targeting `path` with optional `meta`."
  @spec open(binary(), binary(), map()) :: t()
  def open(channel_id, path, meta \\ %{}) do
    %__MODULE__{channel_id: channel_id, kind: :open, payload: %{"path" => path, "meta" => meta}}
  end

  @doc """
  A data frame carrying `data` for `channel_id`.

  Text data rides verbatim; pass `binary: true` to base64-encode arbitrary bytes.
  """
  @spec data(binary(), binary(), keyword()) :: t()
  def data(channel_id, data, opts \\ []) do
    if Keyword.get(opts, :binary, false) do
      %__MODULE__{
        channel_id: channel_id,
        kind: :data,
        payload: %{"data" => Base.encode64(data), "binary" => true}
      }
    else
      %__MODULE__{
        channel_id: channel_id,
        kind: :data,
        payload: %{"data" => data, "binary" => false}
      }
    end
  end

  @doc "A close frame for `channel_id`."
  @spec close(binary(), non_neg_integer(), binary()) :: t()
  def close(channel_id, code \\ 1000, reason \\ "") do
    %__MODULE__{
      channel_id: channel_id,
      kind: :close,
      payload: %{"code" => code, "reason" => reason}
    }
  end

  @doc "Decode a data frame's payload back to its raw bytes/text."
  @spec read_data(t()) :: binary()
  def read_data(%__MODULE__{kind: :data, payload: %{"data" => data, "binary" => true}}),
    do: Base.decode64!(data)

  def read_data(%__MODULE__{kind: :data, payload: %{"data" => data}}), do: data

  @doc "Serialize a frame to a JSON binary for the link."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{channel_id: channel_id, kind: kind, payload: payload}) do
    Jason.encode!(%{"c" => channel_id, "k" => Atom.to_string(kind), "p" => payload})
  end

  @doc "Decode a JSON binary from the link into a frame."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    with {:ok, %{"k" => kind_str} = map} <- Jason.decode(binary),
         {:ok, kind} <- decode_kind(kind_str) do
      {:ok,
       %__MODULE__{
         channel_id: Map.get(map, "c"),
         kind: kind,
         payload: Map.get(map, "p", %{})
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :malformed_frame}
    end
  end

  # Explicit whitelist -- never String.to_atom/1 on link input.
  defp decode_kind("hello"), do: {:ok, :hello}
  defp decode_kind("open"), do: {:ok, :open}
  defp decode_kind("data"), do: {:ok, :data}
  defp decode_kind("close"), do: {:ok, :close}
  defp decode_kind(other), do: {:error, {:unknown_kind, other}}
end
