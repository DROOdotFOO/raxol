defmodule Raxol.MCP.ReadSurfaceAuthzTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.{Authorizer, Registry, Server}

  @authz_denied_code -32090

  defp start_pair(server_opts) do
    registry_name = :"registry_#{System.unique_integer([:positive])}"
    server_name = :"server_#{System.unique_integer([:positive])}"

    {:ok, _} = Registry.start_link(name: registry_name)

    {:ok, server} =
      Server.start_link([name: server_name, registry: registry_name] ++ server_opts)

    {server, registry_name}
  end

  defp register_resource(registry) do
    :ok =
      Registry.register_resources(registry, [
        %{
          uri: "raxol://model/counter",
          name: "counter model",
          callback: fn -> {:ok, "42"} end
        }
      ])
  end

  defp register_prompt(registry) do
    :ok =
      Registry.register_prompts(registry, [
        %{
          name: "greeting",
          description: "say hi",
          callback: fn _args -> {:ok, [%{role: "user", content: "hi"}]} end
        }
      ])
  end

  describe "with a deny-all read authorizer" do
    setup do
      {server, registry} =
        start_pair(read_authorizer: Authorizer.deny_all(:policy))

      register_resource(registry)
      register_prompt(registry)
      %{server: server}
    end

    test "resources/read is refused with the authz code", %{server: s} do
      msg = %{
        id: 1,
        method: "resources/read",
        params: %{"uri" => "raxol://model/counter"}
      }

      {:reply, resp} = Server.handle_message(s, msg)

      assert resp.error.code == @authz_denied_code
      assert resp.error.message =~ "authorization_required"
      assert resp.error.data["method"] == "resources/read"
      refute Map.has_key?(resp, :result)
    end

    test "resources/subscribe is refused", %{server: s} do
      msg = %{
        id: 2,
        method: "resources/subscribe",
        params: %{"uri" => "raxol://x"}
      }

      {:reply, resp} = Server.handle_message(s, msg)
      assert resp.error.data["method"] == "resources/subscribe"
    end

    test "resources/list is refused", %{server: s} do
      {:reply, resp} =
        Server.handle_message(s, %{id: 3, method: "resources/list", params: %{}})

      assert resp.error.data["method"] == "resources/list"
    end

    test "resources/unsubscribe is refused (subscriptions are URI-global)", %{
      server: s
    } do
      {:reply, resp} =
        Server.handle_message(s, %{
          id: 14,
          method: "resources/unsubscribe",
          params: %{"uri" => "raxol://x"}
        })

      assert resp.error.data["method"] == "resources/unsubscribe"
    end

    test "tools/list is refused (same enumeration class)", %{server: s} do
      {:reply, resp} =
        Server.handle_message(s, %{id: 15, method: "tools/list", params: %{}})

      assert resp.error.data["method"] == "tools/list"
    end

    test "prompts/get and prompts/list are refused", %{server: s} do
      {:reply, get} =
        Server.handle_message(s, %{
          id: 4,
          method: "prompts/get",
          params: %{"name" => "greeting"}
        })

      {:reply, list} =
        Server.handle_message(s, %{id: 5, method: "prompts/list", params: %{}})

      assert get.error.data["method"] == "prompts/get"
      assert list.error.data["method"] == "prompts/list"
    end

    test "completion/complete is refused (it enumerates live session ids)", %{
      server: s
    } do
      msg = %{
        id: 6,
        method: "completion/complete",
        params: %{
          "ref" => %{"type" => "ref/tool"},
          "argument" => %{"name" => "id"}
        }
      }

      {:reply, resp} = Server.handle_message(s, msg)
      assert resp.error.data["method"] == "completion/complete"
    end
  end

  describe "seam separation" do
    test "a tools/call allowlist does NOT deny reads (regression guard)" do
      # The whole point of the separate :read_authorizer: existing tool
      # allowlists must keep working without knowing read method names.
      {server, registry} =
        start_pair(authorizer: Authorizer.allowlist(["some_tool"]))

      register_resource(registry)

      msg = %{
        id: 7,
        method: "resources/read",
        params: %{"uri" => "raxol://model/counter"}
      }

      {:reply, resp} = Server.handle_message(server, msg)

      assert %{result: %{contents: [_]}} = resp
    end

    test "ASK on a read surface denies without echoing the prompt" do
      ask = fn _op, _args, _ctx -> {:ask, "secret operator prompt"} end
      {server, registry} = start_pair(read_authorizer: ask)
      register_resource(registry)

      msg = %{
        id: 8,
        method: "resources/read",
        params: %{"uri" => "raxol://model/counter"}
      }

      {:reply, resp} = Server.handle_message(server, msg)

      assert resp.error.data["error"] == "authorization_required"
      refute inspect(resp) =~ "secret operator prompt"
    end

    test "nil read_authorizer keeps reads open" do
      {server, registry} = start_pair([])
      register_resource(registry)

      msg = %{
        id: 9,
        method: "resources/read",
        params: %{"uri" => "raxol://model/counter"}
      }

      {:reply, resp} = Server.handle_message(server, msg)

      assert [%{text: "42"}] =
               resp.result.contents |> Enum.map(&Map.take(&1, [:text]))
    end

    test "an allowing read authorizer passes reads and prompts through" do
      {server, registry} = start_pair(read_authorizer: Authorizer.allow_all())
      register_resource(registry)
      register_prompt(registry)

      {:reply, read} =
        Server.handle_message(server, %{
          id: 10,
          method: "resources/read",
          params: %{"uri" => "raxol://model/counter"}
        })

      {:reply, prompt} =
        Server.handle_message(server, %{
          id: 11,
          method: "prompts/get",
          params: %{"name" => "greeting"}
        })

      assert %{result: %{contents: [_]}} = read
      assert %{result: %{messages: [_]}} = prompt
    end
  end

  describe "resources/subscribe effectiveness" do
    test "resource-updated notifications reach only subscribed URIs" do
      {server, _registry} = start_pair([])

      # Subscribe this test process as a transport.
      :ok = Server.subscribe(server, self())

      # No subscription for the URI yet: the notification must be dropped.
      Server.notify(server, "notifications/resources/updated", %{
        "uri" => "raxol://a"
      })

      refute_receive {:mcp_notification, _}, 200

      # Subscribe, then the same notification must arrive.
      {:reply, _} =
        Server.handle_message(server, %{
          id: 12,
          method: "resources/subscribe",
          params: %{"uri" => "raxol://a"}
        })

      Server.notify(server, "notifications/resources/updated", %{
        "uri" => "raxol://a"
      })

      assert_receive {:mcp_notification, %{method: "notifications/resources/updated"}},
                     1_000

      # Other notification methods are unaffected by subscription state.
      Server.notify(server, "notifications/tools/list_changed", %{})

      assert_receive {:mcp_notification, %{method: "notifications/tools/list_changed"}},
                     1_000
    end
  end

  describe "supervisor threading" do
    test "a :read_authorizer option reaches the supervised server" do
      registry_name = :"registry_#{System.unique_integer([:positive])}"
      server_name = :"server_#{System.unique_integer([:positive])}"

      {:ok, _sup} =
        Raxol.MCP.Supervisor.start_link(
          registry_name: registry_name,
          server_name: server_name,
          read_authorizer: Authorizer.deny_all(:threaded)
        )

      msg = %{id: 13, method: "resources/read", params: %{"uri" => "raxol://x"}}
      {:reply, resp} = Server.handle_message(server_name, msg)

      assert resp.error.data["method"] == "resources/read"
    end
  end
end
