defmodule RaxolGateway do
  @moduledoc """
  Unified messaging gateway for Raxol.

  See `Raxol.Gateway.Supervisor` for the daemon, `Raxol.Gateway.Adapter` for the
  per-platform contract, and `Raxol.Gateway.SessionRouter` for routing inbound
  events to per-chat sessions.
  """

  @doc "The library version."
  @spec version() :: String.t()
  def version, do: "0.1.0"
end
