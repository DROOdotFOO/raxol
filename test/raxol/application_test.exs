defmodule Raxol.ApplicationTest do
  use ExUnit.Case, async: false

  describe "Raxol.Application startup modes" do
    test "determines startup mode correctly" do
      # Test mode should be detected in test environment
      assert Application.get_env(:raxol, :startup_mode) == nil ||
               Mix.env() == :test
    end

    test "health_status returns valid information" do
      status = Raxol.Application.health_status()

      assert is_map(status)
      assert status.mode in [:test, :minimal, :full]
      assert is_boolean(status.supervisor_alive)
      assert is_integer(status.children)
      assert is_integer(status.memory_mb)
      assert is_integer(status.process_count)
      assert is_map(status.features)
      assert is_integer(status.uptime_seconds)
    end

    test "toggle_feature works for runtime features" do
      # Features that don't require restart
      assert Raxol.Application.toggle_feature(:telemetry, false) == :ok
      assert Raxol.Application.toggle_feature(:plugins, true) == :ok
      assert Raxol.Application.toggle_feature(:audit, true) == :ok

      # Features that require restart
      assert Raxol.Application.toggle_feature(:web_interface, false) ==
               {:error, :restart_required}

      assert Raxol.Application.toggle_feature(:database, false) ==
               {:error, :restart_required}

      assert Raxol.Application.toggle_feature(:pubsub, false) ==
               {:error, :restart_required}
    end

    test "add_child and remove_child handle missing dynamic supervisor" do
      # In test mode, DynamicSupervisor might not be started
      result = Raxol.Application.add_child({Task, fn -> :ok end})

      assert result == {:error, :dynamic_supervisor_not_started} ||
               match?({:ok, _}, result)

      result = Raxol.Application.remove_child(:nonexistent)

      assert result == {:error, :not_found} ||
               result == {:error, :dynamic_supervisor_not_started}
    end
  end

  describe "Feature flags" do
    test "default features are set correctly" do
      # Get current features
      status = Raxol.Application.health_status()
      features = status.features

      # These should be default in most environments
      assert is_map(features)

      # Check that features is not empty
      assert map_size(features) > 0
    end

    test "get_feature_flag reads maps and keyword lists (regression: keyword config crashed boot)" do
      # Documented shape: a map.
      assert Raxol.Application.get_feature_flag(%{database: true}, :database)
      refute Raxol.Application.get_feature_flag(%{database: false}, :database)
      refute Raxol.Application.get_feature_flag(%{}, :missing)

      # A keyword list (what `config :raxol, :features, key: value` produces).
      # This used to hit Map.get on a list and raise BadMapError during boot.
      assert Raxol.Application.get_feature_flag([database: true], :database)
      refute Raxol.Application.get_feature_flag([database: false], :database)
      refute Raxol.Application.get_feature_flag([], :missing)

      # Anything else degrades to false rather than crashing.
      refute Raxol.Application.get_feature_flag("garbage", :database)
      refute Raxol.Application.get_feature_flag(nil, :database)
    end
  end

  describe "Memory optimization" do
    test "configure_process_flags sets appropriate flags" do
      assert Raxol.Application.configure_process_flags() == :ok

      # Verify process flags are set
      info = Process.info(self())
      assert info[:trap_exit] == true
      # message_queue_data might not be available in all OTP versions
      assert info[:message_queue_data] == :off_heap ||
               info[:message_queue_data] == nil
    end
  end

  # The MCP supervisor used to be started with `[]`, which means
  # `authorizer: nil`, which means ALLOW. The seam was fully built and simply
  # never engaged. These pin the decision to the call site so a future edit that
  # drops the opts fails here rather than silently shipping allow-all again.
  describe "MCP authorizer resolution" do
    setup do
      previous = Application.get_env(:raxol, :mcp_authorizer)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:raxol, :mcp_authorizer)
          value -> Application.put_env(:raxol, :mcp_authorizer, value)
        end
      end)

      Application.delete_env(:raxol, :mcp_authorizer)
      :ok
    end

    test "unconfigured outside production resolves to an explicit allow_all" do
      authorizer =
        Raxol.Application.resolve_mcp_authorizer(:mcp_authorizer, false)

      assert is_function(authorizer, 3)
      assert authorizer.("raxol_start", %{}, %{}) == :allow
    end

    # The load-bearing half. `Server.authorization_configured?/1` is literally
    # `authorizer != nil`, and the SSE transport's boot gate reads exactly that,
    # so defaulting production to `allow_all/0` would SATISFY the gate and let a
    # network transport serve every tool unguarded.
    test "production denies by default, including tools nobody annotated" do
      authorizer =
        Raxol.Application.resolve_mcp_authorizer(:mcp_authorizer, true)

      assert is_function(authorizer, 3)

      # `raxol_screenshot` is not sensitive. Under the nil this replaced,
      # `Authorizer.decide/4` treated nil as allow and a production server ran it
      # for anyone who reached the server. An empty allowlist is tighter, not
      # merely more explicit.
      for tool <- ["raxol_screenshot", "raxol_start", "anything_at_all"] do
        assert authorizer.(tool, %{}, %{}) == {:deny, :not_allowlisted}
      end
    end

    test "production serves exactly what :mcp_allowed_tools names" do
      Application.put_env(:raxol, :mcp_allowed_tools, ["raxol_screenshot"])
      on_exit(fn -> Application.delete_env(:raxol, :mcp_allowed_tools) end)

      authorizer =
        Raxol.Application.resolve_mcp_authorizer(:mcp_authorizer, true)

      assert authorizer.("raxol_screenshot", %{}, %{}) == :allow
      assert authorizer.("raxol_stop", %{}, %{}) == {:deny, :not_allowlisted}
    end

    # Reads cannot take the same empty default: `tools/list` is a read, so
    # denying every read would leave an allowlisted tool undiscoverable and the
    # server unusable rather than closed.
    test "production allows listing reads but not the ones serving model state" do
      read =
        Raxol.Application.resolve_mcp_authorizer(:mcp_read_authorizer, true)

      assert read.("tools/list", %{}, %{}) == :allow
      assert read.("resources/list", %{}, %{}) == :allow

      for method <- ["resources/read", "resources/subscribe"] do
        assert read.(method, %{}, %{}) == {:deny, :not_allowlisted}
      end
    end

    test "a configured authorizer wins in both environments" do
      configured = fn _tool, _args, _ctx -> {:deny, :nope} end
      Application.put_env(:raxol, :mcp_authorizer, configured)

      for production? <- [true, false] do
        assert Raxol.Application.resolve_mcp_authorizer(
                 :mcp_authorizer,
                 production?
               ) == configured
      end
    end

    # Silently ignoring a malformed value would reinstate the original bug in a
    # worse form: a deployment that believes it configured a policy, running
    # without one.
    test "a malformed configured value raises rather than falling back" do
      Application.put_env(:raxol, :mcp_authorizer, :allow_all)

      assert_raise ArgumentError, ~r/must be a 3-arity fun/, fn ->
        Raxol.Application.resolve_mcp_authorizer(:mcp_authorizer, false)
      end
    end

    # The end-to-end assertion the unit cases above cannot make: the booted
    # application actually handed the server an authorizer.
    test "the running MCP server has an authorizer configured" do
      case Process.whereis(Raxol.MCP.Server) do
        nil ->
          # The MCP supervisor is not part of every startup mode.
          :ok

        _pid ->
          assert Raxol.MCP.Server.authorization_configured?(Raxol.MCP.Server),
                 "Raxol.Application started the MCP supervisor without an " <>
                   "authorizer; every tool would run unguarded"
      end
    end

    # Configured-and-usable are different claims, and only this one catches the
    # environment being misread. Selecting the default from
    # `Raxol.MCP.Deployment.production?/0` looked right and passed every unit
    # case above, but that value is captured at raxol_mcp's COMPILE time and a
    # path dep compiles under :prod -- so a dev session silently got the
    # production allowlist and `mix mcp.server` denied every tool. Asserting a
    # non-nil authorizer could not see it; asserting a call SUCCEEDS can.
    test "a tool actually runs outside production" do
      case Process.whereis(Raxol.MCP.Server) do
        nil ->
          :ok

        server ->
          assert {:reply, %{result: result}} =
                   Raxol.MCP.Server.handle_message(server, %{
                     jsonrpc: "2.0",
                     id: System.unique_integer([:positive]),
                     method: "tools/call",
                     params: %{"name" => "raxol_list", "arguments" => %{}}
                   })

          refute Map.get(result, :isError) == true,
                 "the dev/test default denied a read tool, so this environment " <>
                   "resolved the production allowlist: #{inspect(result)}"
      end
    end
  end
end
