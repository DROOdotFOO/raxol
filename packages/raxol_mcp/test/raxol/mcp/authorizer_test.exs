defmodule Raxol.MCP.AuthorizerTest do
  # async: false -- the Deployment tests mutate the global :raxol_mcp app env.
  use ExUnit.Case, async: false

  alias Raxol.MCP.{Authorizer, Deployment, Registry, Server}

  defp add_tool do
    %{
      name: "add",
      description: "Add numbers",
      inputSchema: %{type: "object"},
      callback: fn args ->
        {:ok, [%{type: "text", text: "#{Map.get(args, "a", 0) + Map.get(args, "b", 0)}"}]}
      end
    }
  end

  defp start_server(authorizer, tools \\ nil) do
    tools = tools || [add_tool()]
    reg = :"reg_#{System.unique_integer([:positive])}"
    srv = :"srv_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.start_link(name: reg)
    Registry.register_tools(reg, tools)
    {:ok, _} = Server.start_link(name: srv, registry: reg, authorizer: authorizer)
    srv
  end

  defp call(srv, name \\ "add") do
    msg = %{
      id: 1,
      method: "tools/call",
      params: %{"name" => name, "arguments" => %{"a" => 2, "b" => 3}}
    }

    {:reply, resp} = Server.handle_message(srv, msg)
    resp
  end

  defp payload(resp) do
    resp.result.content |> hd() |> Map.fetch!(:text) |> Jason.decode!()
  end

  describe "Authorizer builders" do
    test "allow_all, deny_all, allowlist, and nil->allow" do
      assert :allow = Authorizer.decide(Authorizer.allow_all(), "x", %{}, %{})
      assert {:deny, :nope} = Authorizer.decide(Authorizer.deny_all(:nope), "x", %{}, %{})

      allow = Authorizer.allowlist(["ok"])
      assert :allow = Authorizer.decide(allow, "ok", %{}, %{})
      assert {:deny, :not_allowlisted} = Authorizer.decide(allow, "no", %{}, %{})

      # nil authorizer allows -- stdio inherits the OS process boundary.
      assert :allow = Authorizer.decide(nil, "anything", %{}, %{})
    end
  end

  describe "tools/call authorization" do
    test "no authorizer allows the tool to run (default)" do
      resp = call(start_server(nil))
      assert resp.result.content == [%{type: "text", text: "5"}]
      refute resp.result[:isError]
    end

    test "allow_all runs the tool" do
      resp = call(start_server(Authorizer.allow_all()))
      assert resp.result.content == [%{type: "text", text: "5"}]
    end

    test "deny returns a machine-readable authorization_required result, not the tool output" do
      resp = call(start_server(Authorizer.deny_all(:blocked)))
      assert resp.result.isError == true
      p = payload(resp)
      assert p["error"] == "authorization_required"
      assert p["tool"] == "add"
      assert p["decision"] == "deny"
      assert p["detail"] == ":blocked"
    end

    test "ASK is denied here (deny-on-ASK), surfacing decision=ask and the prompt as detail" do
      ask = fn _tool, _args, _ctx -> {:ask, "Approve add?"} end
      resp = call(start_server(ask))
      assert resp.result.isError == true
      p = payload(resp)
      assert p["error"] == "authorization_required"
      assert p["decision"] == "ask"
      assert p["detail"] == "Approve add?"
    end

    test "allowlist blocks tools not on the list" do
      resp = call(start_server(Authorizer.allowlist(["something_else"])))
      assert resp.result.isError == true
      assert payload(resp)["decision"] == "deny"
    end

    test "a denied call never reaches the tool callback" do
      test = self()

      spy = %{
        name: "spy",
        description: "records if it ran",
        inputSchema: %{type: "object"},
        callback: fn _args ->
          send(test, :callback_ran)
          {:ok, "x"}
        end
      }

      srv = start_server(Authorizer.deny_all(), [spy])
      call(srv, "spy")
      refute_received :callback_ran
    end
  end

  describe "authorization_configured?/1" do
    test "reflects whether an authorizer is set" do
      assert Server.authorization_configured?(start_server(Authorizer.allow_all()))
      refute Server.authorization_configured?(start_server(nil))
    end

    test "returns false for an unreachable server" do
      refute Server.authorization_configured?(:no_such_server)
    end
  end

  describe "Deployment gate" do
    setup do
      on_exit(fn -> Application.delete_env(:raxol_mcp, :require_authorization) end)
    end

    test "require_authorization? defaults to false in test and honors the override" do
      refute Deployment.require_authorization?()
      Application.put_env(:raxol_mcp, :require_authorization, true)
      assert Deployment.require_authorization?()
    end

    test "enforce_authorization! is a no-op when configured or not required" do
      assert :ok = Deployment.enforce_authorization!(true, "x")
      assert :ok = Deployment.enforce_authorization!(false, "x")
    end

    test "enforce_authorization! fails closed when required and no authorizer is configured" do
      Application.put_env(:raxol_mcp, :require_authorization, true)

      assert_raise ArgumentError, ~r/refuses to boot/, fn ->
        Deployment.enforce_authorization!(false, "MCP SSE transport")
      end

      # ...but a configured authorizer boots even when required.
      assert :ok = Deployment.enforce_authorization!(true, "MCP SSE transport")
    end
  end
end
