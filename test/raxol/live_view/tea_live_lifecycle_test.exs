defmodule Raxol.LiveView.TEALiveLifecycleTest do
  use ExUnit.Case, async: false

  alias Raxol.LiveView.TEALive

  defmodule MountApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{}

    @impl true
    def update(_event, model), do: {model, []}

    @impl true
    def view(_model), do: nil

    @impl true
    def subscribe(_model), do: []
  end

  setup do
    if Process.whereis(Raxol.PubSub) do
      :ok
    else
      start_supervised!({Phoenix.PubSub, name: Raxol.PubSub})
      :ok
    end
  end

  test "a connected mount leaves its per-client lifecycle unregistered" do
    parent = self()

    mount_pid =
      spawn(fn ->
        send(parent, {:mount_started, self()})

        socket = %Phoenix.LiveView.Socket{
          transport_pid: self(),
          assigns: %{__changed__: %{}}
        }

        TEALive.mount(%{}, %{}, socket, app_module: MountApp)
      end)

    on_exit(fn ->
      if Process.alive?(mount_pid), do: Process.exit(mount_pid, :kill)
    end)

    assert_receive {:mount_started, ^mount_pid}
    lifecycle_pid = await_link(mount_pid)

    assert {:registered_name, []} =
             Process.info(lifecycle_pid, :registered_name)
  end

  defp await_link(pid, attempts \\ 200)

  defp await_link(_pid, 0),
    do: flunk("connected mount did not start a lifecycle")

  defp await_link(pid, attempts) do
    lifecycle =
      case Process.info(pid, :links) do
        {:links, links} -> Enum.find(links, &lifecycle?/1)
        _ -> nil
      end

    if lifecycle do
      lifecycle
    else
      Process.sleep(5)
      await_link(pid, attempts - 1)
    end
  end

  defp lifecycle?(pid) do
    match?(
      {Raxol.Core.Runtime.Lifecycle, :init, 1},
      :proc_lib.translate_initial_call(pid)
    )
  catch
    :exit, _reason -> false
  end
end
