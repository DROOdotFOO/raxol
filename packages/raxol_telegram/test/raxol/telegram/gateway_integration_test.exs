defmodule Raxol.Telegram.GatewayIntegrationTest do
  @moduledoc """
  The acceptance proof for issue #493: Telegram behind the frozen
  `Raxol.Gateway.Adapter` contract with an in-memory fake connection.

  A raw Telegram update flows normalize_event -> SessionRouter -> handler ->
  adapter send_message, with the outbound Bot API call captured via post_fn.
  """
  use ExUnit.Case, async: false

  alias Raxol.Gateway.SessionRouter
  alias Raxol.Telegram.GatewayAdapter

  defmodule EchoHandler do
    @behaviour Raxol.Gateway.Handler

    @impl true
    def init(_route, _opts), do: {:ok, %{}}

    @impl true
    def handle_event(%{text: text}, state), do: {:reply, "echo: #{text}", state}
    def handle_event(_event, state), do: {:noreply, state}
  end

  setup do
    test_pid = self()

    post_fn = fn url, req_opts ->
      send(test_pid, {:posted, url, Keyword.fetch!(req_opts, :json)})
      {:ok, %{status: 200, body: %{"ok" => true, "result" => %{}}}}
    end

    {:ok, conn} = GatewayAdapter.connect(bot_token: "test-token", post_fn: post_fn)

    sup = :"tg_gw_sup_#{System.unique_integer([:positive])}"
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})

    router = :"tg_gw_router_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: router,
      start:
        {SessionRouter, :start_link,
         [
           [
             name: router,
             handler: {EchoHandler, []},
             sessions_sup: sup,
             adapter: {GatewayAdapter, conn}
           ]
         ]}
    })

    %{router: router}
  end

  test "a raw Telegram update round-trips to a sendMessage reply", %{router: r} do
    raw = %{
      message: %{
        text: "hi",
        chat: %{id: 42, type: "private"},
        from: %{id: 7}
      }
    }

    assert {:ok, route, event} = GatewayAdapter.normalize_event(raw)
    assert :ok = SessionRouter.route(r, route, event)

    assert_receive {:posted, url, body}
    assert String.ends_with?(url, "/sendMessage")
    assert body == %{chat_id: 42, text: "echo: hi"}
  end

  test "an ignored update never reaches the router" do
    assert GatewayAdapter.normalize_event(%{callback_query: %{data: "key:enter"}}) == :ignore
  end
end
