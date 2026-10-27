defmodule Raxol.CLI.MCPTest do
  # The refusals read process-wide env (RAXOL_CLI_INSTALL_DIR, :raxol_cli env).
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Raxol.CLI.MCP

  @ctx %{conn_id: :default, transport: :stdio}

  describe "authorize/3" do
    test "refuses raxol_start given a path, whatever its value" do
      for path <- ["examples/demo.exs", "/etc/x.exs", nil] do
        assert {:deny, reason} =
                 MCP.authorize("raxol_start", %{"path" => path, "id" => "p"}, @ctx)

        assert reason =~ ~s("path" is refused)
      end
    end

    test "allows raxol_start by module, and other tools" do
      module = %{"module" => "Raxol.Playground.Demos.TableDemo", "id" => "t"}
      assert MCP.authorize("raxol_start", module, @ctx) == :allow
      assert MCP.authorize("raxol_screenshot", %{"id" => "t"}, @ctx) == :allow
      assert MCP.authorize("t.table.sort", %{}, @ctx) == :allow
    end
  end

  describe "authorize_read/3" do
    test "allows the listing methods" do
      for method <- ~w(tools/list resources/list prompts/list) do
        assert MCP.authorize_read(method, %{}, @ctx) == :allow
      end
    end

    test "denies reads of anything but a session this VM runs" do
      assert {:deny, _} =
               MCP.authorize_read("resources/read", %{"uri" => "raxol://docs/README.md"}, @ctx)

      assert {:deny, reason} =
               MCP.authorize_read(
                 "resources/read",
                 %{"uri" => "raxol://session/nope/widgets"},
                 @ctx
               )

      assert reason =~ ~s("nope")
      assert {:deny, _} = MCP.authorize_read("resources/read", %{"uri" => 42}, @ctx)
      assert {:deny, _} = MCP.authorize_read("completion/complete", %{}, @ctx)
      assert {:deny, _} = MCP.authorize_read("logging/setLevel", %{"level" => "debug"}, @ctx)
    end

    test "subscribes only to sessions this VM runs" do
      uri = %{"uri" => "raxol://session/nope/widgets"}

      for method <- ~w(resources/subscribe resources/unsubscribe) do
        assert {:deny, reason} = MCP.authorize_read(method, uri, @ctx)
        assert reason =~ ~s(no session "nope")
      end
    end
  end

  describe "run/1 refusals" do
    setup do
      mode = System.get_env("RAXOL_MODE")

      on_exit(fn ->
        System.delete_env("RAXOL_CLI_INSTALL_DIR")
        if mode, do: System.put_env("RAXOL_MODE", mode), else: System.delete_env("RAXOL_MODE")
        Application.delete_env(:raxol_cli, :mcp_boot)
      end)
    end

    test "refuses while RAXOL_CLI_INSTALL_DIR is set" do
      System.put_env("RAXOL_CLI_INSTALL_DIR", "")
      err = capture_io(:stderr, fn -> assert MCP.run([]) == 1 end)
      assert err =~ "RAXOL_CLI_INSTALL_DIR is set"
    end

    test "refuses unknown arguments with a usage line" do
      err = capture_io(:stderr, fn -> assert MCP.run(["--derived", "x"]) == 64 end)
      assert err =~ "unknown arguments --derived x"
      assert err =~ "usage: raxol mcp"
    end

    test "refuses when the VM did not boot for MCP" do
      err = capture_io(:stderr, fn -> assert MCP.run([]) == 1 end)
      assert err =~ "did not boot for MCP"
    end

    test "refuses a version it is not" do
      Application.put_env(:raxol_cli, :mcp_boot, true)
      err = capture_io(:stderr, fn -> assert MCP.run(["--expect-version", "0.0.0"]) == 1 end)
      assert err =~ "this is raxol #{Raxol.CLI.version()}, not the expected 0.0.0"
    end

    test "refuses when RAXOL_MODE names another mode" do
      Application.put_env(:raxol_cli, :mcp_boot, true)
      System.put_env("RAXOL_MODE", "minimal")
      err = capture_io(:stderr, fn -> assert MCP.run([]) == 1 end)
      assert err =~ "RAXOL_MODE=minimal overrides the MCP boot mode"
    end

    test "a VM booted for MCP runs no other command" do
      Application.put_env(:raxol_cli, :mcp_boot, true)

      err =
        capture_io(:stderr, fn ->
          assert capture_io(fn -> assert Raxol.CLI.main(["--version"]) == 1 end) == ""
        end)

      assert err =~ "booted for `raxol mcp`"
    end
  end
end
