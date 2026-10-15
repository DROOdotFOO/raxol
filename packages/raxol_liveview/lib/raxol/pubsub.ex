defmodule Raxol.PubSub do
  @moduledoc """
  PubSub system for Raxol.

  This module provides configuration and utilities for Phoenix.PubSub
  integration in Raxol applications. It defines the PubSub server name
  used throughout the application.

  ## Usage

  In your application's supervision tree:

      children = [
        {Phoenix.PubSub, name: Raxol.PubSub}
      ]

  Then subscribe and broadcast:

      Phoenix.PubSub.subscribe(Raxol.PubSub, "terminal:events")
      Phoenix.PubSub.broadcast(Raxol.PubSub, "terminal:events", {:key_press, key})

  ## Example

      # Subscribe to terminal events
      Raxol.PubSub.subscribe("terminal:events")

      # Broadcast an event
      Raxol.PubSub.broadcast("terminal:events", {:resize, 80, 24})

      # Broadcast from a specific node
      Raxol.PubSub.broadcast_from(self(), "terminal:events", {:input, "hello"})
  """

  @doc """
  The PubSub server name used throughout Raxol.

  Returns the atom `Raxol.PubSub` which should be used when starting
  the Phoenix.PubSub supervisor and when subscribing/broadcasting.

  ## Example

      {Phoenix.PubSub, name: Raxol.PubSub.server_name()}
  """
  @spec server_name() :: Raxol.PubSub
  def server_name, do: __MODULE__

  if Code.ensure_loaded?(Phoenix.PubSub) do
    @doc """
    Subscribe to a topic on the Raxol PubSub server.

    This is a convenience wrapper around `Phoenix.PubSub.subscribe/2`.

    ## Example

        Raxol.PubSub.subscribe("terminal:events")
    """
    @spec subscribe(String.t()) :: :ok
    def subscribe(topic) when is_binary(topic) do
      Phoenix.PubSub.subscribe(__MODULE__, topic)
    end

    @doc """
    Subscribe to a topic with options.

    ## Options

      - `:metadata` - Metadata to include with the subscription

    ## Example

        Raxol.PubSub.subscribe("terminal:events", metadata: %{user_id: 123})
    """
    @spec subscribe(String.t(), keyword()) :: :ok
    def subscribe(topic, opts) when is_binary(topic) and is_list(opts) do
      Phoenix.PubSub.subscribe(__MODULE__, topic, opts)
    end

    @doc """
    Unsubscribe from a topic.

    ## Example

        Raxol.PubSub.unsubscribe("terminal:events")
    """
    @spec unsubscribe(String.t()) :: :ok
    def unsubscribe(topic) when is_binary(topic) do
      Phoenix.PubSub.unsubscribe(__MODULE__, topic)
    end

    @doc """
    Broadcast a message to all subscribers of a topic.

    ## Example

        Raxol.PubSub.broadcast("terminal:events", {:key_press, :enter})
    """
    @spec broadcast(String.t(), term()) :: :ok
    def broadcast(topic, message) when is_binary(topic) do
      Phoenix.PubSub.broadcast(__MODULE__, topic, message)
    end

    @doc """
    Broadcast a message to all subscribers except the sender.

    ## Example

        Raxol.PubSub.broadcast_from(self(), "terminal:events", {:output, "Hello"})
    """
    @spec broadcast_from(pid(), String.t(), term()) :: :ok
    def broadcast_from(from_pid, topic, message)
        when is_pid(from_pid) and is_binary(topic) do
      Phoenix.PubSub.broadcast_from(__MODULE__, from_pid, topic, message)
    end

    @doc """
    Broadcast a message locally (only to subscribers on this node).

    ## Example

        Raxol.PubSub.local_broadcast("terminal:events", {:local_event, data})
    """
    @spec local_broadcast(String.t(), term()) :: :ok
    def local_broadcast(topic, message) when is_binary(topic) do
      Phoenix.PubSub.local_broadcast(__MODULE__, topic, message)
    end

    @doc """
    Broadcast a message locally except to the sender.

    ## Example

        Raxol.PubSub.local_broadcast_from(self(), "terminal:events", {:output, "data"})
    """
    @spec local_broadcast_from(pid(), String.t(), term()) :: :ok
    def local_broadcast_from(from_pid, topic, message)
        when is_pid(from_pid) and is_binary(topic) do
      Phoenix.PubSub.local_broadcast_from(__MODULE__, from_pid, topic, message)
    end

    @doc """
    Get the child spec for starting the PubSub server.

    This can be used in your application's supervision tree.

    ## Example

        children = [
          Raxol.PubSub.child_spec([])
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
    """
    @spec child_spec(keyword()) :: Supervisor.child_spec()
    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {Phoenix.PubSub, :start_link, [[name: __MODULE__] ++ opts]},
        type: :supervisor
      }
    end
  else
    def subscribe(_topic),
      do: raise("Raxol.PubSub requires the :phoenix_pubsub dependency")

    def subscribe(_topic, _opts),
      do: raise("Raxol.PubSub requires the :phoenix_pubsub dependency")

    def unsubscribe(_topic),
      do: raise("Raxol.PubSub requires the :phoenix_pubsub dependency")

    def broadcast(_topic, _message),
      do: raise("Raxol.PubSub requires the :phoenix_pubsub dependency")

    def broadcast_from(_from, _topic, _message),
      do: raise("Raxol.PubSub requires the :phoenix_pubsub dependency")

    def local_broadcast(_topic, _message),
      do: raise("Raxol.PubSub requires the :phoenix_pubsub dependency")

    def local_broadcast_from(_from, _topic, _message),
      do: raise("Raxol.PubSub requires the :phoenix_pubsub dependency")

    def child_spec(_opts) do
      raise "Raxol.PubSub requires the :phoenix_pubsub dependency"
    end
  end
end
