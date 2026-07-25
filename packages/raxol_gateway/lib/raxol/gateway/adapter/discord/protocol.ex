defmodule Raxol.Gateway.Adapter.Discord.Protocol do
  @moduledoc """
  Pure codec for Discord Gateway v10 JSON frames.

  Stateless: encodes the three client payloads the socket sends
  (heartbeat, identify, resume) and classifies inbound frames into tagged
  tuples. All connection state (sequence numbers, session ids, timers)
  lives in `Raxol.Gateway.Adapter.Discord.GatewaySocket`.

  Dispatch frames (op 0) are returned whole and string-keyed, exactly as
  decoded, so the socket can hand them to its `:on_event` sink unmodified.
  """

  import Bitwise

  @intent_guilds 1 <<< 0
  @intent_guild_messages 1 <<< 9
  @intent_direct_messages 1 <<< 12
  @intent_message_content 1 <<< 15

  @type decoded ::
          {:dispatch, map()}
          | {:hello, pos_integer()}
          | :heartbeat_request
          | :heartbeat_ack
          | :reconnect
          | {:invalid_session, resumable? :: boolean()}
          | {:unknown, term()}
          | {:error, term()}

  @doc """
  The default intent bitfield: GUILDS, GUILD_MESSAGES, DIRECT_MESSAGES,
  and MESSAGE_CONTENT.

  MESSAGE_CONTENT is privileged: it must also be enabled for the bot in
  the Discord developer portal, or guild message content arrives empty.
  """
  @spec default_intents() :: pos_integer()
  def default_intents do
    @intent_guilds + @intent_guild_messages + @intent_direct_messages +
      @intent_message_content
  end

  @doc "Encode a heartbeat (op 1) carrying the last seen sequence (or nil)."
  @spec encode_heartbeat(integer() | nil) :: String.t()
  def encode_heartbeat(seq) when is_integer(seq) or is_nil(seq) do
    Jason.encode!(%{op: 1, d: seq})
  end

  @doc "Encode an identify (op 2) with token and intents."
  @spec encode_identify(String.t(), pos_integer()) :: String.t()
  def encode_identify(token, intents)
      when is_binary(token) and is_integer(intents) do
    Jason.encode!(%{
      op: 2,
      d: %{
        token: token,
        intents: intents,
        properties: %{os: os_name(), browser: "raxol", device: "raxol"}
      }
    })
  end

  @doc "Encode a resume (op 6) for an interrupted session."
  @spec encode_resume(String.t(), String.t(), integer()) :: String.t()
  def encode_resume(token, session_id, seq)
      when is_binary(token) and is_binary(session_id) and is_integer(seq) do
    Jason.encode!(%{
      op: 6,
      d: %{token: token, session_id: session_id, seq: seq}
    })
  end

  @doc "Classify one inbound text frame."
  @spec decode(String.t()) :: decoded()
  def decode(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{"op" => op} = frame} -> classify(op, frame)
      {:ok, other} -> {:unknown, other}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp classify(0, %{"t" => type} = frame) when is_binary(type),
    do: {:dispatch, frame}

  defp classify(1, _frame), do: :heartbeat_request
  defp classify(7, _frame), do: :reconnect
  defp classify(9, frame), do: {:invalid_session, frame["d"] == true}

  defp classify(10, %{"d" => %{"heartbeat_interval" => interval}})
       when is_integer(interval) and interval > 0,
       do: {:hello, interval}

  defp classify(11, _frame), do: :heartbeat_ack
  defp classify(_op, frame), do: {:unknown, frame}

  defp os_name do
    {_family, name} = :os.type()
    Atom.to_string(name)
  end
end
