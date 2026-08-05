defmodule Raxol.MCP.ReadSurfaceAuthzTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.{Authorizer, Protocol, Registry, Server}

  defp start_pair(server_opts) do
    registry_name = :"registry_#{System.unique_integer([:positive])}"
    server_name = :"server_#{System.unique_integer([:positive])}"

    {:ok, _} = Registry.start_link(name: registry_name)

    {:ok, server} =
      Server.start_link(
        [name: server_name, registry: registry_name] ++ server_opts
      )

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

  describe "with a deny-all authorizer" do
    test "resources/read is refused machine-readably" do
      {server, registry} = start_pair(authorizer: Authorizer.deny_all(:policy))
      register_resource(registry)

      msg = %{
        id: 1,
        method: "resources/read",
        params: %{"uri" => "raxol://model/counter"}
      }

      {:reply, resp} = Server.handle_message(server, msg)

      assert resp.error.message =~ "authorization_required"
      assert resp.error.data["method"] == "resources/read"
    end

    test "resources/subscribe is refused" do
      {server, _registry} = start_pair(authorizer: Authorizer.deny_all(:policy))

      msg = %{
        id: 2,
        method: "resources/subscribe",
        params: %{"uri" => "raxol://model/counter"}
      }

      {:reply, resp} = Server.handle_message(server, msg)

      assert resp.error.data["method"] == "resources/subscribe"
    end

    test "prompts/get is refused" do
      {server, registry} = start_pair(authorizer: Authorizer.deny_all(:policy))
      register_prompt(registry)

      msg = %{id: 3, method: "prompts/get", params: %{"name" => "greeting"}}
      {:reply, resp} = Server.handle_message(server, msg)

      assert resp.error.data["method"] == "prompts/get"
    end
  end

  describe "ASK on a read surface" do
    test "resolves to deny (no elicitation for reads)" do
      ask = fn _op, _args, _ctx -> {:ask, "really?"} end
      {server, registry} = start_pair(authorizer: ask)
      register_resource(registry)

      msg = %{
        id: 4,
        method: "resources/read",
        params: %{"uri" => "raxol://model/counter"}
      }

      {:reply, resp} = Server.handle_message(server, msg)

      assert resp.error.data["error"] == "authorization_required"
    end
  end

  describe "allow paths" do
    test "nil authorizer still allows reads" do
      {server, registry} = start_pair([])
      register_resource(registry)

      msg = %{
        id: 5,
        method: "resources/read",
        params: %{"uri" => "raxol://model/counter"}
      }

      {:reply, resp} = Server.handle_message(server, msg)

      assert [%{text: "42"}] =
               resp.result.contents |> Enum.map(&Map.take(&1, [:text]))
    end

    test "an allowing authorizer passes reads and prompts through" do
      {server, registry} = start_pair(authorizer: Authorizer.allow_all())
      register_resource(registry)
      register_prompt(registry)

      {:reply, read} =
        Server.handle_message(server, %{
          id: 6,
          method: "resources/read",
          params: %{"uri" => "raxol://model/counter"}
        })

      assert %{result: %{contents: [_]}} = read

      {:reply, prompt} =
        Server.handle_message(server, %{
          id: 7,
          method: "prompts/get",
          params: %{"name" => "greeting"}
        })

      assert %{result: %{messages: [_]}} = prompt
    end
  end

  describe "supervisor threading" do
    test "an :authorizer option reaches the supervised server" do
      registry_name = :"registry_#{System.unique_integer([:positive])}"
      server_name = :"server_#{System.unique_integer([:positive])}"

      {:ok, _sup} =
        Raxol.MCP.Supervisor.start_link(
          registry_name: registry_name,
          server_name: server_name,
          authorizer: Authorizer.deny_all(:threaded)
        )

      msg = %{id: 8, method: "resources/read", params: %{"uri" => "raxol://x"}}
      {:reply, resp} = Server.handle_message(server_name, msg)

      assert resp.error.data["method"] == "resources/read"
    end
  end

  test "authz error uses the JSON-RPC error envelope, not a tool result" do
    {server, _} = start_pair(authorizer: Authorizer.deny_all(:policy))

    msg = %{id: 9, method: "resources/read", params: %{"uri" => "raxol://x"}}
    {:reply, resp} = Server.handle_message(server, msg)

    refute Map.has_key?(resp, :result)
    assert resp.error.code == Protocol.internal_error()
  end
end
