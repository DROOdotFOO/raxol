defmodule Raxol.Gateway.Route do
  @moduledoc """
  Where a message comes from and goes back to.

  A route carries the platform, the chat type, the chat id, and the user id. Its
  `key/1` is the unified session key `agent:main:{platform}:{chat_type}:{chat_id}`,
  the stable identity a `Raxol.Gateway.SessionRouter` keys sessions by and that a
  future cross-platform handoff rebinds.
  """

  @enforce_keys [:platform, :chat_type, :chat_id]
  defstruct [:platform, :chat_type, :chat_id, :user_id]

  @type t :: %__MODULE__{
          platform: atom(),
          chat_type: atom(),
          chat_id: String.t() | integer(),
          user_id: String.t() | integer() | nil
        }

  @doc "Build a route from a map or keyword list."
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      platform: Map.fetch!(attrs, :platform),
      chat_type: Map.fetch!(attrs, :chat_type),
      chat_id: Map.fetch!(attrs, :chat_id),
      user_id: Map.get(attrs, :user_id)
    }
  end

  @doc "The unified session key for a route."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{platform: platform, chat_type: chat_type, chat_id: chat_id}) do
    "agent:main:#{platform}:#{chat_type}:#{chat_id}"
  end
end
