defmodule Raxol.LiveView.TEALiveIdentityTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.LiveView.TEALive

  defmodule OperatorApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(context), do: %{user: context.options[:authenticated_user]}

    @impl true
    def update(%Raxol.Core.Events.Event{type: :key}, model) do
      send(Process.whereis(:liveview_identity_test), {:answer, model.user})
      {model, []}
    end

    @impl true
    def view(model), do: text(model.user || "read-only")

    @impl true
    def subscribe(_model), do: []
  end

  setup do
    Process.register(self(), :liveview_identity_test)

    unless Process.whereis(Raxol.PubSub),
      do: start_supervised!({Phoenix.PubSub, name: Raxol.PubSub})

    :ok
  end

  test "only the opted-in server session names the operator, never URL params" do
    socket =
      mount(
        %{"user_id" => "mallory"},
        %{"user_id" => "alice", "token" => "private"},
        authenticated_user_key: "user_id"
      )

    TEALive.handle_event(
      "keydown",
      %{"key" => "a", "user_id" => "mallory"},
      socket
    )

    assert_receive {:answer, "alice"}
  end

  test "a session without explicit opt-in cannot grant an operator" do
    socket = mount(%{}, %{"user_id" => "alice"}, [])
    TEALive.handle_event("keydown", %{"key" => "a"}, socket)
    assert_receive {:answer, nil}
  end

  test "missing and malformed authenticated identities remain read-only" do
    for user <- [nil, "", 123, %{"id" => "alice"}, "alice\nadmin"] do
      socket =
        mount(%{"user_id" => "alice"}, %{"user_id" => user},
          authenticated_user_key: "user_id"
        )

      TEALive.handle_event("keydown", %{"key" => "a"}, socket)
      assert_receive {:answer, nil}
      TEALive.terminate(:normal, socket)
    end
  end

  defp mount(params, session, opts) do
    socket = %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{__changed__: %{}}
    }

    {:ok, socket} =
      TEALive.mount(
        params,
        session,
        socket,
        Keyword.put(opts, :app_module, OperatorApp)
      )

    lifecycle = socket.assigns.lifecycle_pid

    on_exit(fn ->
      if Process.alive?(lifecycle),
        do: Raxol.Core.Runtime.Lifecycle.stop(lifecycle)
    end)

    socket
  end
end
