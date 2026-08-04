defmodule Raxol.MCP.SensitiveToolGuardTest do
  @moduledoc """
  A tool that declares itself destructive/sensitive must not be served without
  an authorizer. That is a refusal, not a warning: the annotation exists to say
  "this must not run unattended", and booting anyway would serve it wide open.

  Enforced twice, because one point is bypassable on its own:

    * at boot, loudly, for tools already registered;
    * at `tools/call`, for a tool registered AFTER boot, which the boot check
      cannot have seen.
  """
  use ExUnit.Case, async: true

  alias Raxol.MCP.Authorizer
  alias Raxol.MCP.Registry
  alias Raxol.MCP.Server
  alias Raxol.MCP.ToolDef

  defp registry! do
    start_supervised!(
      {Registry, name: :"reg_#{System.unique_integer([:positive])}"},
      id: {:reg, System.unique_integer([:positive])}
    )
  end

  defp tool(name, annotations) do
    base = %{
      name: name,
      description: "moves money",
      inputSchema: %{type: "object"},
      callback: fn _ -> {:ok, "moved"} end
    }

    if annotations, do: Map.put(base, :annotations, annotations), else: base
  end

  defp start_server(registry, opts) do
    Server.start_link(
      Keyword.merge(
        [name: :"srv_#{System.unique_integer([:positive])}", registry: registry],
        opts
      )
    )
  end

  describe "ToolDef.sensitive?/1" do
    test "the MCP destructiveHint and the raxol sensitive flag both count" do
      assert ToolDef.sensitive?(tool("t", %{destructiveHint: true}))
      assert ToolDef.sensitive?(tool("t", %{sensitive: true}))
      assert ToolDef.sensitive?(tool("t", %{"destructiveHint" => true}))
    end

    test "an unannotated tool is not sensitive" do
      refute ToolDef.sensitive?(tool("t", nil))
      refute ToolDef.sensitive?(tool("t", %{}))
    end

    test "an annotation can only ADD an obligation, never remove one" do
      # Self-reported safety buys nothing. Declaring yourself dangerous is
      # credible; declaring yourself safe is not (the same ruling U21-R3 makes
      # about a self-reported `mutating: false`).
      refute ToolDef.sensitive?(tool("t", %{destructiveHint: false}))
      refute ToolDef.sensitive?(tool("t", %{readOnlyHint: true}))

      # ...and a "safe" hint cannot cancel a dangerous one.
      assert ToolDef.sensitive?(tool("t", %{destructiveHint: true, readOnlyHint: true}))
      assert ToolDef.sensitive?(tool("t", %{sensitive: true, destructiveHint: false}))
    end

    test "new/2 carries annotations onto the built definition" do
      assert {:ok, built} =
               ToolDef.new("spend",
                 description: "moves money",
                 input_schema: %{type: "object"},
                 callback: fn _ -> :ok end,
                 annotations: %{destructiveHint: true}
               )

      assert ToolDef.sensitive?(built)
    end
  end

  describe "boot refusal" do
    test "a sensitive tool with no authorizer refuses to boot, naming the tool" do
      registry = registry!()
      :ok = Registry.register_tools(registry, [tool("spend", %{destructiveHint: true})])

      # The raise happens in init/1 of a LINKED process, so it comes back as a
      # start_link error rather than propagating into this process.
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} = start_server(registry, [])
      assert message =~ "refuses to boot"
      assert message =~ "spend"
    end

    test "the same tool boots fine once an authorizer is configured" do
      registry = registry!()
      :ok = Registry.register_tools(registry, [tool("spend", %{destructiveHint: true})])

      assert {:ok, server} = start_server(registry, authorizer: Authorizer.allow_all())
      assert Process.alive?(server)
    end

    test "unannotated tools boot without an authorizer" do
      # The guard must not turn into a blanket authorizer requirement -- stdio
      # inherits the OS process boundary, and that stays true.
      registry = registry!()
      :ok = Registry.register_tools(registry, [tool("read_file", nil)])

      assert {:ok, server} = start_server(registry, [])
      assert Process.alive?(server)
    end
  end

  describe "runtime backstop" do
    test "a sensitive tool registered AFTER boot is denied, not run" do
      # The boot check cannot have seen this tool. Without the second
      # enforcement point, registering late would be a clean bypass.
      registry = registry!()
      {:ok, server} = start_server(registry, [])

      ran = :counters.new(1, [])

      :ok =
        Registry.register_tools(registry, [
          %{
            name: "late_spend",
            description: "moves money",
            inputSchema: %{type: "object"},
            annotations: %{destructiveHint: true},
            callback: fn _ ->
              :counters.add(ran, 1, 1)
              {:ok, "moved"}
            end
          }
        ])

      assert {:reply, response} =
               Server.handle_message(server, %{
                 jsonrpc: "2.0",
                 id: 7,
                 method: "tools/call",
                 params: %{"name" => "late_spend", "arguments" => %{}}
               })

      assert %{result: %{content: [%{text: text} | _], isError: true}} = response
      payload = Jason.decode!(text)
      assert payload["error"] == "authorization_required"
      assert payload["detail"] =~ "sensitive_tool_unguarded"

      assert :counters.get(ran, 1) == 0, "the sensitive tool must never have run"
    end

    test "an unannotated tool registered after boot still runs" do
      registry = registry!()
      {:ok, server} = start_server(registry, [])
      :ok = Registry.register_tools(registry, [tool("safe", nil)])

      assert {:reply, %{result: %{content: [%{text: "moved"} | _]}}} =
               Server.handle_message(server, %{
                 jsonrpc: "2.0",
                 id: 8,
                 method: "tools/call",
                 params: %{"name" => "safe", "arguments" => %{}}
               })
    end

    test "with an authorizer, a sensitive tool runs when allowed" do
      registry = registry!()
      :ok = Registry.register_tools(registry, [tool("spend", %{sensitive: true})])
      {:ok, server} = start_server(registry, authorizer: Authorizer.allow_all())

      assert {:reply, %{result: %{content: [%{text: "moved"} | _]}}} =
               Server.handle_message(server, %{
                 jsonrpc: "2.0",
                 id: 9,
                 method: "tools/call",
                 params: %{"name" => "spend", "arguments" => %{}}
               })
    end
  end
end
