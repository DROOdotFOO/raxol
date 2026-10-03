defmodule Raxol.LiveView.TEALiveTest do
  use ExUnit.Case, async: true

  alias Raxol.LiveView.TEALive
  alias Raxol.LiveView.TerminalBridge
  alias Raxol.LiveView.Test.BufferHelper

  defmodule ForwardingDispatcher do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_cast({:dispatch, event}, owner) do
      send(owner, {:dispatched, event})
      {:noreply, owner}
    end
  end

  describe "announcement live region" do
    test "handle_info stores the latest announcement in the assign" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, announcement: nil}
      }

      msg =
        {:announcement_added, make_ref(),
         %{message: "Saved", priority: :normal, interrupt: false, timestamp: 0}}

      assert {:noreply, socket} = TEALive.handle_info(msg, socket)
      assert socket.assigns.announcement == %{message: "Saved", priority: :normal}
    end

    test "renders a polite sr-only region for normal announcements" do
      html = render_html(%{message: "Saved", priority: :normal})

      assert html =~ ~s(class="raxol-sr-only")
      assert html =~ ~s(role="status")
      assert html =~ ~s(aria-live="polite")
      assert html =~ "Saved"
    end

    test "renders an assertive sr-only region for high-priority announcements" do
      html = render_html(%{message: "Danger", priority: :high})

      assert html =~ ~s(class="raxol-sr-only")
      assert html =~ ~s(aria-live="assertive")
      assert html =~ "Danger"
    end

    test "renders an always-present polite region when there is no announcement" do
      html = render_html(nil)

      assert html =~ ~s(class="raxol-sr-only")
      assert html =~ ~s(aria-live="polite")
    end

    defp render_html(announcement, rows \\ []) do
      assigns = %{
        __changed__: nil,
        rows: rows,
        container_attrs: TerminalBridge.container_attrs(:log),
        announcement: announcement,
        animation_css: nil
      }

      TEALive.render(assigns) |> Phoenix.LiveViewTest.rendered_to_string()
    end
  end

  describe "screen rows" do
    test "renders one element per row, carrying the bridge's row ids" do
      rows = TerminalBridge.buffer_to_rows(numbered_buffer())
      html = render_html(nil, rows)

      for row <- rows do
        assert html =~ ~s(<div id="#{row.id}" class="raxol-row">)
      end

      assert html =~ "row 0"
      assert html =~ "row 2"
    end

    test "keeps the whole-screen log region on the screen container" do
      html = render_html(nil)

      assert html =~ ~s(role="log")
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(aria-atomic="false")
    end
  end

  describe "render_update" do
    test "splits the broadcast screen into addressable rows" do
      buffer = numbered_buffer()
      screen = TerminalBridge.buffer_to_html(buffer)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, rows: []}
      }

      assert {:noreply, socket} =
               TEALive.handle_info({:render_update, screen}, socket)

      assert socket.assigns.rows == TerminalBridge.buffer_to_rows(buffer)
    end
  end

  describe "keydown dispatch" do
    test "a dead lifecycle process cannot crash the callback" do
      lifecycle_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(lifecycle_pid)
      send(lifecycle_pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^lifecycle_pid, :normal}

      socket = keydown_socket(lifecycle_pid: lifecycle_pid, dispatcher_pid: nil)

      assert {:noreply, ^socket} = TEALive.handle_event("keydown", %{"key" => "a"}, socket)
    end

    test "an unresponsive lifecycle process is not called for each key" do
      lifecycle_pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(lifecycle_pid, :kill) end)
      socket = keydown_socket(lifecycle_pid: lifecycle_pid, dispatcher_pid: nil)

      task =
        Task.async(fn ->
          TEALive.handle_event("keydown", %{"key" => "a"}, socket)
        end)

      assert {:ok, {:noreply, ^socket}} = Task.yield(task, 100)
    end

    test "dispatches translated keys through the dispatcher cached at mount" do
      dispatcher = start_supervised!({ForwardingDispatcher, self()}, id: make_ref())
      socket = keydown_socket(lifecycle_pid: nil, dispatcher_pid: dispatcher)

      assert {:noreply, ^socket} =
               TEALive.handle_event("keydown", %{"key" => "ArrowLeft"}, socket)

      assert_receive {:dispatched, %Raxol.Core.Events.Event{type: :key, data: data}}
      assert data.key == :left
    end
  end

  defp keydown_socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        assigns
        |> Map.new()
        |> Map.put(:__changed__, %{})
    }
  end

  defp numbered_buffer do
    Enum.reduce(0..2, BufferHelper.create_blank_buffer(8, 3), fn y, buffer ->
      BufferHelper.write_string(buffer, 0, y, "row #{y}")
    end)
  end
end
