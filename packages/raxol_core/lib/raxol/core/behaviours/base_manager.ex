defmodule Raxol.Core.Behaviours.BaseManager do
  @moduledoc """
  Base behavior for manager GenServers to reduce code duplication.
  Provides common patterns for state management, lifecycle, and error handling.
  """

  @doc """
  Called to initialize the manager state.
  Must return {:ok, state}. For initialization failures, raise an exception
  to let the supervisor handle restart logic.
  """
  @callback init_manager(term()) :: {:ok, any()}

  @doc """
  Called to handle manager-specific requests.
  """
  @callback handle_manager_call(any(), GenServer.from(), any()) ::
              {:reply, any(), any()}
              | {:noreply, any()}
              | {:stop, any(), any(), any()}

  @doc """
  Called to handle manager-specific casts.
  """
  @callback handle_manager_cast(any(), any()) ::
              {:noreply, any()} | {:stop, any(), any()}

  @doc """
  Called to handle manager-specific info messages.
  """
  @callback handle_manager_info(any(), any()) ::
              {:noreply, any()} | {:stop, any(), any()}

  @optional_callbacks [
    handle_manager_call: 3,
    handle_manager_cast: 2,
    handle_manager_info: 2
  ]

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use GenServer
      alias Raxol.Core.Runtime.Log
      @behaviour Raxol.Core.Behaviours.BaseManager

      def start_link(init_opts \\ []) do
        {server_opts, manager_opts} = normalize_and_split_opts(init_opts)
        GenServer.start_link(__MODULE__, manager_opts, server_opts)
      end

      @impl GenServer
      def init(opts) do
        init_manager(opts)
        |> normalize_init_result()
      end

      @impl GenServer
      def handle_call(request, from, state) do
        handle_manager_call(request, from, state)
      end

      @impl GenServer
      def handle_cast(msg, state) do
        handle_manager_cast(msg, state)
      end

      @impl GenServer
      def handle_info(msg, state) do
        handle_manager_info(msg, state)
      end

      # Default implementations for optional callbacks
      def handle_manager_call(request, _from, state) do
        Log.warning("Unhandled call: #{inspect(request)}")
        {:reply, {:error, :not_implemented}, state}
      end

      def handle_manager_cast(msg, state) do
        Log.warning("Unhandled cast: #{inspect(msg)}")
        {:noreply, state}
      end

      def handle_manager_info(msg, state) do
        Log.debug("Unhandled info: #{inspect(msg)}")
        {:noreply, state}
      end

      # Default implementation for required callback
      def init_manager(_opts), do: {:ok, %{}}

      # Splits GenServer opts from init args
      defp normalize_and_split_opts(opts),
        do: Raxol.Core.Utils.GenServerHelpers.split_server_opts(opts)

      defp normalize_init_result({:ok, _state} = ok), do: ok
      defp normalize_init_result({:ok, _state, _extra} = ok), do: ok
      defp normalize_init_result({:stop, _reason} = stop), do: stop
      defp normalize_init_result(:ignore), do: :ignore

      # All callbacks are overridable
      defoverridable start_link: 1,
                     init_manager: 1,
                     handle_manager_call: 3,
                     handle_manager_cast: 2,
                     handle_manager_info: 2,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2
    end
  end
end
