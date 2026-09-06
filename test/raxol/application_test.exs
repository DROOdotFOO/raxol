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

      for method <- ["tools/list", "resources/list", "prompts/list"] do
        assert read.(method, %{}, %{}) == :allow
      end

      # Not merely "not a listing method": each of these returns something the
      # advertisement did not already give away. `prompts/get` returns prompt
      # CONTENT; `completion/complete` enumerates valid argument VALUES.
      for method <- [
            "resources/read",
            "resources/subscribe",
            "resources/unsubscribe",
            "prompts/get",
            "completion/complete"
          ] do
        assert read.(method, %{}, %{}) == {:deny, :not_allowlisted},
               "#{method} discloses more than a name and must not be a default"
      end
    end

    # The default read allowlist is a denylist by omission of a vocabulary
    # raxol_mcp owns. Omission is the safe direction, but it should stay
    # DELIBERATE: a read method added there must be classified here rather than
    # silently denied by nobody noticing.
    test "every read method the server gates is classified by the default" do
      source = "packages/raxol_mcp/lib/raxol/mcp/server.ex"

      # Read relative to the repo root rather than the runner's cwd, and say so
      # when it is missing: a raw File.Error here reads as a broken test rather
      # than as "the file this guard watches has moved".
      assert File.exists?(source),
             "#{source} is missing, so the read-method drift guard cannot run " <>
               "(cwd: #{File.cwd!()})"

      gated =
        source
        |> File.read!()
        |> then(&Regex.scan(~r/authorize_read\(\s*"([^"]+)"/, &1))
        |> Enum.map(fn [_, method] -> method end)
        |> Enum.uniq()
        |> MapSet.new()

      # Guard the guard. A regex that quietly stops matching would make the
      # subset check below vacuously true, and this test would pass while
      # asserting nothing at all.
      assert MapSet.size(gated) == 8,
             "found #{MapSet.size(gated)} gated read methods, not 8: server.ex " <>
               "changed shape and this test no longer reads it"

      read =
        Raxol.Application.resolve_mcp_authorizer(:mcp_read_authorizer, true)

      classified =
        MapSet.new(["tools/list", "resources/list", "prompts/list"])
        |> MapSet.union(
          MapSet.new([
            "resources/read",
            "resources/subscribe",
            "resources/unsubscribe",
            "prompts/get",
            "completion/complete"
          ])
        )

      assert MapSet.subset?(gated, classified),
             "raxol_mcp gates read methods this application has never classified " <>
               "as allowed or denied: " <>
               inspect(MapSet.to_list(MapSet.difference(gated, classified))) <>
               ". They are denied by omission; decide and say so."

      # And the classification is the one actually in force.
      for method <- MapSet.to_list(gated) do
        assert read.(method, %{}, %{}) in [:allow, {:deny, :not_allowlisted}]
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

    # The production fallback is a deny-everything allowlist, which is a non-nil
    # authorizer. Had `authorization_configured?/1` stayed `authorizer != nil`,
    # that fallback would have satisfied the SSE boot gate and let a network
    # transport start in production because raxol picked a default -- where
    # before this change SSE refused outright. Tool execution got tighter and
    # transport exposure got looser, in one step, silently.
    test "an unconfigured production fallback does not satisfy the SSE gate" do
      registry =
        start_supervised!(
          {Raxol.MCP.Registry,
           name: :"reg_#{System.unique_integer([:positive])}"},
          id: {:reg, System.unique_integer([:positive])}
        )

      {:ok, server} =
        Raxol.MCP.Server.start_link(
          name: :"srv_#{System.unique_integer([:positive])}",
          registry: registry,
          authorizer:
            Raxol.Application.resolve_mcp_authorizer(:mcp_authorizer, true),
          authorizer_source: :default
        )

      refute Raxol.MCP.Server.authorization_configured?(server),
             "a framework fallback reported itself as configured authorization, " <>
               "so SSE would boot in production without anyone deciding it should"

      # The gate only bites where it is required, which in a real deployment is
      # `Deployment.production?/0`. This run is :test, so require it explicitly
      # rather than assert against a no-op and prove nothing.
      Application.put_env(:raxol_mcp, :require_authorization, true)

      on_exit(fn ->
        Application.delete_env(:raxol_mcp, :require_authorization)
      end)

      assert_raise ArgumentError, ~r/refuses to boot/, fn ->
        Raxol.MCP.Deployment.enforce_authorization!(
          Raxol.MCP.Server.authorization_configured?(server),
          "MCP SSE transport"
        )
      end
    end

    test "an operator's own authorizer does satisfy it" do
      registry =
        start_supervised!(
          {Raxol.MCP.Registry,
           name: :"reg_#{System.unique_integer([:positive])}"},
          id: {:reg, System.unique_integer([:positive])}
        )

      {:ok, server} =
        Raxol.MCP.Server.start_link(
          name: :"srv_#{System.unique_integer([:positive])}",
          registry: registry,
          authorizer: Raxol.MCP.Authorizer.allowlist(["raxol_list"]),
          authorizer_source: :configured
        )

      assert Raxol.MCP.Server.authorization_configured?(server)
    end

    test "naming either config key counts as configuring, including an empty list" do
      Application.put_env(:raxol, :mcp_allowed_tools, [])
      on_exit(fn -> Application.delete_env(:raxol, :mcp_allowed_tools) end)

      # Exposing a transport that serves nothing is a coherent thing to want,
      # and it is the operator's to choose rather than ours to second-guess.
      assert Raxol.Application.mcp_authorizer_source() == :configured
    end

    test "configuring nothing is not a decision" do
      assert Raxol.Application.mcp_authorizer_source() == :default
    end

    # `:minimal` omits the MCP supervisor, but the injection is not mode-gated.
    # Injecting there advertised six tools to a Tidewave client that then refused
    # all six, since every injected callback re-enters through that server.
    test "no injection when the MCP server this startup mode did not build" do
      assert Raxol.Application.tidewave_injection_decision(true, nil) ==
               {:skip, :no_mcp_server}
    end

    test "injection proceeds when the server is there" do
      assert Raxol.Application.tidewave_injection_decision(true, self()) ==
               :inject
    end

    test "opting out wins even with a server running" do
      assert Raxol.Application.tidewave_injection_decision(false, self()) ==
               {:skip, :disabled}
    end

    # This assertion only means anything from HERE. raxol_mcp is a path
    # dependency of this application, and a path dependency compiles under :prod
    # whatever the umbrella's env is, so a compile-time capture of `Mix.env()`
    # read `:prod` and this returned true under `MIX_ENV=test`. The package's own
    # suite cannot reproduce that: there raxol_mcp is the root project, compiles
    # as :test, and the same predicate was already correct. The disagreement is
    # only visible across the dependency edge.
    test "Deployment.production?/0 answers for this app, not raxol_mcp's build" do
      refute Raxol.MCP.Deployment.production?(),
             "raxol_mcp read its own compile env instead of this session's, so " <>
               "a dev or test run is treated as production"
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
