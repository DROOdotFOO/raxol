defmodule Raxol.Watch.DeviceRegistry do
  @moduledoc """
  ETS-backed registry of watch devices for push notification targeting.

  Stores device tokens with their platform (`:apns` or `:fcm`) and
  per-device preferences (muted, high-priority-only, badge count).

  Writes go through the GenServer for serialization. Reads hit ETS
  directly for performance (`:protected` table with `read_concurrency`).
  """

  use Raxol.Core.Behaviours.BaseManager

  @table __MODULE__

  defstruct []

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a device for push notifications.

  ## Options

    * `:muted` - suppress all pushes (default: false)
    * `:high_priority_only` - only push high-priority alerts (default: false)
  """
  @spec register(String.t(), :apns | :fcm, keyword()) :: :ok
  def register(device_token, platform, opts \\ []) when platform in [:apns, :fcm] do
    GenServer.call(__MODULE__, {:register, device_token, platform, opts})
  end

  @doc "Unregisters a device."
  @spec unregister(String.t()) :: :ok
  def unregister(device_token) do
    GenServer.call(__MODULE__, {:unregister, device_token})
  end

  @doc "Lists all registered devices."
  @spec list_devices() :: [{String.t(), :apns | :fcm, map()}]
  def list_devices do
    :ets.tab2list(@table)
  end

  @doc "Lists devices filtered by platform."
  @spec list_devices(:apns | :fcm) :: [{String.t(), :apns | :fcm, map()}]
  def list_devices(platform) when platform in [:apns, :fcm] do
    :ets.match_object(@table, {:_, platform, :_})
  end

  @doc "Returns the number of registered devices."
  @spec device_count() :: non_neg_integer()
  def device_count do
    :ets.info(@table, :size)
  end

  # -- BaseManager --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

      _ref ->
        :ok
    end

    {:ok, %__MODULE__{}}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:register, device_token, platform, opts}, _from, state) do
    prefs = %{
      muted: Keyword.get(opts, :muted, false),
      high_priority_only: Keyword.get(opts, :high_priority_only, false)
    }

    :ets.insert(@table, {device_token, platform, prefs})
    {:reply, :ok, state}
  end

  def handle_manager_call({:unregister, device_token}, _from, state) do
    :ets.delete(@table, device_token)
    {:reply, :ok, state}
  end
end
