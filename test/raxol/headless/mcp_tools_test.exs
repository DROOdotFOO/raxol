defmodule Raxol.Headless.McpToolsTest do
  use ExUnit.Case, async: false

  alias Raxol.Headless.McpTools

  # Owns `:tidewave_tools` the way Tidewave does: a `:sys`-reachable process, so
  # `inject_into_tidewave/0`'s `:sys.replace_state` round trip is exercised for
  # real rather than stubbed out.
  defmodule TidewaveTableOwner do
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call(:create_table, _from, state) do
      :ets.new(:tidewave_tools, [:set, :named_table, read_concurrency: true])

      :ets.insert(
        :tidewave_tools,
        {:tools,
         {[%{name: "existing_tidewave_tool"}],
          %{"existing_tidewave_tool" => fn _ -> :ok end},
          [%{name: "browser_eval"}], %{"browser_eval" => fn _ -> :ok end}}}
      )

      {:reply, :ok, state}
    end
  end

  # `raxol_start`'s `"path"` compiles the file it is given, and compiling a
  # `defmodule` executes its body -- so this branch is arbitrary code execution
  # with the BEAM's privileges, reachable from any connected MCP client. These
  # tests drive the real tool callback; nothing here is stubbed.
  describe "raxol_start path containment" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "raxol-headless-root-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(root, "inside"))
      File.chmod!(root, 0o700)

      File.write!(
        Path.join(root, "inside/ok.exs"),
        "defmodule NoView do\nend\n"
      )

      prev = System.get_env("RAXOL_HEADLESS_PATH_ROOT")

      on_exit(fn ->
        if prev,
          do: System.put_env("RAXOL_HEADLESS_PATH_ROOT", prev),
          else: System.delete_env("RAXOL_HEADLESS_PATH_ROOT")

        File.rm_rf!(root)
      end)

      System.delete_env("RAXOL_HEADLESS_PATH_ROOT")
      %{root: root}
    end

    defp start_tool,
      do: Enum.find(McpTools.tools(), &(&1.name == "raxol_start")).callback

    # The tool reaches `Raxol.Headless` only once resolution ACCEPTS the path,
    # and whether that server is running is not what these assert on. Catching
    # the exit keeps the subject the refusal, not the session manager.
    defp call_start(args) do
      start_tool().(args)
    catch
      :exit, reason -> {:reached_headless, reason}
    end

    test "a path is refused outright when no root is configured" do
      assert {:error, message} = call_start(%{"path" => "examples/demo.exs"})
      assert message =~ "RAXOL_HEADLESS_PATH_ROOT"
      assert message =~ "disabled"
    end

    test "a path inside the configured root resolves to the file named", %{
      root: root
    } do
      System.put_env("RAXOL_HEADLESS_PATH_ROOT", root)

      # Asserts WHICH file, not merely that resolution did not refuse. A test
      # that only ruled out the refusal branches would still pass if the path
      # were silently rewritten -- which is exactly the behaviour the absolute
      # case below now refuses, so the accepting case has to prove the opposite
      # rather than assume it.
      assert {:resolved, target} = resolved_target(%{"path" => "inside/ok.exs"})

      # Compared against the root's REAL path, because that is what `confine/3`
      # documents itself as returning -- and it is load-bearing on macOS, where
      # `System.tmp_dir!()` hands back `/tmp`, a symlink to `/private/tmp`.
      # Asserting the lexical path here would fail for the right behaviour.
      real_root = File.cd!(root, &File.cwd!/0)

      assert target == Path.join(real_root, "inside/ok.exs")

      result = call_start(%{"path" => "inside/ok.exs"})
      refute match?({:error, "starting from a path is disabled" <> _}, result)
      refute match?({:error, "path is outside" <> _}, result)
    end

    test "a .. traversal out of the root is refused", %{root: root} do
      System.put_env("RAXOL_HEADLESS_PATH_ROOT", Path.join(root, "inside"))

      assert {:error, message} =
               call_start(%{"path" => "../../../etc/passwd.exs"})

      assert message =~ "outside the configured headless path root"
    end

    # `Raxol.Headless` is not running here, so an ACCEPTED path surfaces as a
    # `:noproc` exit whose payload carries the path that would have been handed
    # downstream. That is exactly what needs pinning: not whether the call
    # succeeded, but WHICH file it resolved to.
    defp resolved_target(args) do
      case call_start(args) do
        {:reached_headless,
         {:noproc,
          {GenServer, :call,
           [_server, {:start_session, target, _opts}, _timeout]}}} ->
          {:resolved, target}

        other ->
          other
      end
    end

    # `confine/3` alone would JOIN this under the root, landing it at
    # <root>/etc/evil.exs. That is safe -- `/etc/evil.exs` is never honoured --
    # but it means the tool compiles a different file than the one it was asked
    # for and says nothing, while the schema documents the argument as relative.
    # For the argument that decides which code executes, a silent substitution
    # is the worse of the two safe behaviours, so the mismatch is named.
    test "an absolute path is refused, not silently jailed under the root",
         %{root: root} do
      System.put_env("RAXOL_HEADLESS_PATH_ROOT", root)

      assert {:error, message} = call_start(%{"path" => "/etc/evil.exs"})

      assert message =~ "must be RELATIVE"
      assert message =~ "would not be the file you named"
    end

    # The refusal must not be a leading-slash check. A Windows drive path is
    # absolute too, and `/foo` on Windows is volume-relative -- neither is the
    # relative path the caller was asked for, and both would otherwise be
    # rewritten under the root.
    test "a drive-absolute path is refused as well", %{root: root} do
      System.put_env("RAXOL_HEADLESS_PATH_ROOT", root)

      assert {:error, message} = call_start(%{"path" => "c:/windows/evil.exs"})

      assert message =~ "must be RELATIVE"
    end

    test "an empty path is refused rather than resolving to the root", %{
      root: root
    } do
      System.put_env("RAXOL_HEADLESS_PATH_ROOT", root)

      assert {:error, message} = call_start(%{"path" => ""})

      assert message =~ "must not be empty"
    end

    # Runs on every platform, Windows included. It did not always: `walk_real/3`
    # recognized an absolute symlink target by the POSIX `["/" | rest]` shape
    # alone, so a Windows `c:/...` target was spliced onto the base as if
    # relative and landed back inside the root. Fixed in
    # `Raxol.Core.Boundary.Path` under a shared conformance vector
    # (`drive_absolute_symlink_escape`), so this asserting on Windows is the
    # end-to-end half of that proof.
    test "a symlink inside the root pointing outside it is refused", %{
      root: root
    } do
      # The case that passes if containment is decided on the LEXICAL path:
      # `<root>/escape.exs` is textually inside, and resolves outside.
      outside =
        Path.join(
          System.tmp_dir!(),
          "raxol-outside-#{System.unique_integer([:positive])}.exs"
        )

      File.write!(outside, "defmodule Escaped do\nend\n")
      on_exit(fn -> File.rm(outside) end)

      link = Path.join(root, "escape.exs")

      case File.ln_s(outside, link) do
        :ok ->
          System.put_env("RAXOL_HEADLESS_PATH_ROOT", root)

          assert {:error, message} = call_start(%{"path" => "escape.exs"})
          assert message =~ "outside the configured headless path root"

        {:error, _} ->
          # No symlink support on this filesystem; the lexical cases still ran.
          :ok
      end
    end

    test "a non-Elixir file is refused before it reaches the compiler", %{
      root: root
    } do
      File.write!(Path.join(root, "notes.txt"), "hello")
      System.put_env("RAXOL_HEADLESS_PATH_ROOT", root)

      assert {:error, message} = call_start(%{"path" => "notes.txt"})
      assert message =~ ".ex or .exs"
    end

    test "an unknown module is refused rather than minted as an atom" do
      # Atoms are never collected, so minting one per distinct MCP-supplied
      # string grows the atom table without bound.
      name = "NoSuchHeadlessModule#{System.unique_integer([:positive])}"

      assert {:error, message} = call_start(%{"module" => name})

      # The refusal says the BEAM is missing, not that the module is unloaded:
      # unloaded is the ordinary state under `mix mcp.server`, and saying so
      # sends an operator looking for a loading problem that is not there.
      assert message =~ "no compiled module by that name is loadable"

      assert_raise ArgumentError, fn ->
        String.to_existing_atom("Elixir." <> name)
      end
    end

    test "the module refusal does not steer the caller onto the path branch" do
      assert {:error, message} =
               call_start(%{"module" => "NoSuchHeadlessModuleEver"})

      refute message =~ "path"
    end
  end

  # Resolving a name is not the same as accepting it. These run the tool with a
  # real `Raxol.Headless` behind it, because the contract gate lives there and
  # the point of the tool's wording is what an operator reads at the end of the
  # whole call.
  describe "raxol_start module contract" do
    setup do
      case Process.whereis(Raxol.Headless) do
        nil -> start_supervised!({Raxol.Headless, [name: Raxol.Headless]})
        pid -> pid
      end

      :ok
    end

    defp start_tool_result(args),
      do:
        Enum.find(McpTools.tools(), &(&1.name == "raxol_start")).callback.(args)

    # A `BaseManager` GenServer, so it exports `init/1` and nothing else the
    # runtime wants. It is one of the 527 modules on this tree that would have
    # satisfied a bare `Code.ensure_loaded?/1`, and starting it ran its
    # GenServer `init/1` outside any supervisor.
    test "a real module that is not a Raxol application is refused" do
      assert {:error, message} =
               start_tool_result(%{
                 "module" => "Raxol.Terminal.Buffer.BufferServer",
                 "id" => "not_an_app"
               })

      assert message =~ "is not a Raxol application"
      assert message =~ "init/1, update/2 and view/1"
    end

    # The two refusals send an operator in opposite directions -- go compile it
    # versus go pick a different module -- so the wording has to separate them.
    test "a missing module and a non-application module read differently" do
      assert {:error, missing} =
               start_tool_result(%{"module" => "NoSuchHeadlessAppAtAll"})

      assert {:error, not_an_app} =
               start_tool_result(%{
                 "module" => "Raxol.Terminal.Buffer.BufferServer",
                 "id" => "not_an_app_again"
               })

      assert missing =~ "unknown module"
      refute missing =~ "is not a Raxol application"
      refute not_an_app =~ "unknown module"
    end

    # The atom table is not the same question as "does this module exist".
    # Interactive code loading -- `mix mcp.server`, the documented workflow --
    # is the normal case, and there a module's atom does not exist until
    # something loads it. Refusing on the atom table alone therefore refuses
    # modules that are compiled and sitting on the code path, which is what
    # `raxol_start` asks for. An OTP release boots `:embedded` with everything
    # pre-loaded, so this hides on fly.io and shows up locally.
    #
    # It lives in THIS describe, behind a real `Raxol.Headless`, because the
    # contract gate runs server-side. Asserted from a block with no server, the
    # call exits `:noproc` before ever reaching the gate, and the test passes on
    # an artefact of the downed server rather than on the answer an operator
    # gets.
    #
    # Compiled by a SEPARATE OS PROCESS on purpose: compiling it here would mint
    # the atom in this VM and the test would pass against either version.
    test "a compiled-but-unloaded module on the code path starts" do
      name = "HeadlessUnloadedProbe#{System.unique_integer([:positive])}"
      dir = compile_out_of_vm(name)

      # No one in this VM has ever named it.
      assert_raise ArgumentError, fn ->
        String.to_existing_atom("Elixir." <> name)
      end

      Code.append_path(dir)
      on_exit(fn -> Code.delete_path(dir) end)

      assert {:ok, message} =
               start_tool_result(%{"module" => name, "id" => "unloaded_probe"})

      assert message =~ "unloaded_probe"

      # The session dies with the `Raxol.Headless` the setup started, so in the
      # normal case there is nothing to clean up -- and an unguarded stop races
      # that teardown and exits `:noproc`. Guarded rather than dropped because
      # the setup REUSES an already-running server when it finds one, and then
      # the session really would outlive this test.
      on_exit(fn ->
        if Process.whereis(Raxol.Headless),
          do: Raxol.Headless.stop("unloaded_probe")
      end)
    end

    # The full TEA triple, not `view/1` alone: this fixture stands in for a real
    # application, and a gate that names `init/1, update/2 and view/1` has to be
    # given something that satisfies it or the test is measuring the gate's
    # refusal instead of the code-path lookup it is about.
    defp compile_out_of_vm(name) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "raxol-unloaded-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      source = Path.join(dir, "probe.ex")

      File.write!(source, """
      defmodule #{name} do
        def init(_), do: %{}
        def update(_msg, model), do: model
        def view(_), do: nil
      end
      """)

      on_exit(fn -> File.rm_rf!(dir) end)

      elixirc =
        System.find_executable("elixirc") ||
          flunk("elixirc is required to compile a module outside this VM")

      case System.cmd(elixirc, ["-o", dir, source], stderr_to_stdout: true) do
        {_output, 0} -> dir
        {output, status} -> flunk("elixirc exited #{status}: #{output}")
      end
    end
  end

  describe "tools/0" do
    test "returns 6 tool definitions" do
      tools = McpTools.tools()
      assert length(tools) == 6
    end

    test "each tool has required fields" do
      for tool <- McpTools.tools() do
        assert is_binary(tool.name)
        assert is_binary(tool.description)
        assert is_map(tool.inputSchema)
        assert is_function(tool.callback, 1)
      end
    end

    test "tool names follow raxol_ prefix convention" do
      names = Enum.map(McpTools.tools(), & &1.name)

      assert "raxol_start" in names
      assert "raxol_screenshot" in names
      assert "raxol_send_key" in names
      assert "raxol_get_model" in names
      assert "raxol_stop" in names
      assert "raxol_list" in names
    end

    test "input schemas have type: object" do
      for tool <- McpTools.tools() do
        assert tool.inputSchema.type == "object"
      end
    end
  end

  # The annotation is what `Raxol.MCP.Server` reads to decide a tool must not run
  # unguarded. Without one, all six of these were `sensitive?/1 == false`, so
  # both the boot refusal and the `tools/call` gate were dead code on this
  # surface no matter what authorizer a deployment configured.
  describe "tools/0 sensitivity annotations" do
    setup do
      %{by_name: Map.new(McpTools.tools(), &{&1.name, &1})}
    end

    test "the three tools that change something are sensitive", %{
      by_name: by_name
    } do
      for name <- ["raxol_start", "raxol_send_key", "raxol_stop"] do
        assert Raxol.MCP.ToolDef.sensitive?(by_name[name]),
               "#{name} changes state and must be gated once an authorizer exists"
      end
    end

    test "the three read tools are not gated", %{by_name: by_name} do
      for name <- ["raxol_screenshot", "raxol_get_model", "raxol_list"] do
        refute Raxol.MCP.ToolDef.sensitive?(by_name[name]),
               "#{name} is a read; gating it would deny reads for no gain"
      end
    end

    # `Raxol.MCP.Registry` stores a `Map.take/2` projection of the tool map, so
    # an annotation that survives `tools/0` but is dropped on the way into ETS
    # would leave the server reading `sensitive?/1 == false` back off the
    # registry, which is the only copy it ever consults.
    test "annotations survive registration into the registry" do
      registry = registry!()
      :ok = McpTools.register(registry)

      sensitive =
        registry
        |> Raxol.MCP.Registry.list_tools()
        |> Enum.filter(&Raxol.MCP.ToolDef.sensitive?/1)
        |> Enum.map(& &1.name)
        |> Enum.sort()

      assert sensitive == ["raxol_send_key", "raxol_start", "raxol_stop"]
    end
  end

  # What the annotations buy, over the ordering `Raxol.Application` actually
  # uses: the MCP supervisor starts registry-then-server, and
  # `maybe_register_mcp_tools/0` runs afterwards. So the registry is EMPTY at
  # server init, the boot refusal cannot see these tools, and the `tools/call`
  # gate is the only thing holding the line -- which is precisely the case the
  # runtime gate was written for.
  describe "server enforcement, tools registered after boot" do
    setup do
      registry = registry!()

      {:ok, unguarded} =
        Raxol.MCP.Server.start_link(
          name: :"srv_#{System.unique_integer([:positive])}",
          registry: registry,
          authorizer: nil
        )

      :ok = McpTools.register(registry)

      %{server: unguarded, registry: registry}
    end

    test "a sensitive tool is refused when no authorizer is configured", %{
      server: server
    } do
      assert {:reply, response} =
               call_tool(server, "raxol_start", %{"module" => "Kernel"})

      assert %{result: %{content: [%{text: text} | _], isError: true}} =
               response

      payload = Jason.decode!(text)
      assert payload["error"] == "authorization_required"
      assert payload["detail"] =~ "sensitive_tool_unguarded"
    end

    test "a read tool still runs when no authorizer is configured", %{
      server: server
    } do
      assert {:reply, %{result: result}} = call_tool(server, "raxol_list", %{})
      refute Map.get(result, :isError) == true
    end

    test "an explicit authorizer is what lets the sensitive tools through", %{
      registry: registry
    } do
      {:ok, guarded} =
        Raxol.MCP.Server.start_link(
          name: :"srv_#{System.unique_integer([:positive])}",
          registry: registry,
          authorizer: Raxol.MCP.Authorizer.allow_all()
        )

      assert {:reply, %{result: %{content: [%{text: text} | _]}}} =
               call_tool(guarded, "raxol_stop", %{"id" => "no_such_session"})

      # Past the gate: this is the tool's own refusal, not the authorizer's.
      refute text =~ "authorization_required"
    end
  end

  # The other ordering, which a host that registers before starting the server
  # would hit. Pinned because it is the reason the annotation could not simply be
  # added on its own: without the explicit authorizer `Raxol.Application` now
  # passes, annotating these tools would have made the MCP server unbootable.
  describe "server enforcement, tools registered before boot" do
    test "an unguarded server refuses to boot once the tools are annotated" do
      registry = registry!()
      :ok = McpTools.register(registry)

      # The raise happens in init/1 of a LINKED process, so it comes back as a
      # start_link error rather than propagating into this process.
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Raxol.MCP.Server.start_link(
                 name: :"srv_#{System.unique_integer([:positive])}",
                 registry: registry,
                 authorizer: nil
               )

      assert message =~ "refuses to boot"

      for name <- ["raxol_start", "raxol_send_key", "raxol_stop"] do
        assert message =~ name
      end
    end

    test "the same tree boots when an authorizer is supplied" do
      registry = registry!()
      :ok = McpTools.register(registry)

      assert {:ok, server} =
               Raxol.MCP.Server.start_link(
                 name: :"srv_#{System.unique_integer([:positive])}",
                 registry: registry,
                 authorizer: Raxol.MCP.Authorizer.allow_all()
               )

      assert Raxol.MCP.Server.authorization_configured?(server)
    end
  end

  defp registry! do
    start_supervised!(
      {Raxol.MCP.Registry, name: :"reg_#{System.unique_integer([:positive])}"},
      id: {:reg, System.unique_integer([:positive])}
    )
  end

  defp call_tool(server, name, arguments) do
    Raxol.MCP.Server.handle_message(server, %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: "tools/call",
      params: %{"name" => name, "arguments" => arguments}
    })
  end

  describe "inject_into_tidewave/0" do
    test "returns error when tidewave not started" do
      # In test env, Tidewave ETS table won't exist
      assert {:error, :tidewave_not_started} = McpTools.inject_into_tidewave()
    end

    # Tidewave is `only: :dev`, so nothing in the test env can start it and the
    # case above is the only one CI ever reached. That let the 0.8.2 -> 0.9.0
    # bump silently break injection: the record widened from
    # `{tools, dispatch}` to `{tools, dispatch, browser_tools, browser_dispatch}`
    # and the MatchError disappeared into `{:error, {:sys_replace_failed, _}}`.
    #
    # This stands up the real thing -- a real GenServer owning a real ETS table
    # holding the record Tidewave actually writes (mirrored from
    # `Tidewave.MCP.Handler.init_tools/0`) -- so a future shape change fails here
    # instead of in a dev session nobody is watching.
    test "injects into the tidewave table and leaves the browser halves alone" do
      {:ok, owner} = start_supervised(TidewaveTableOwner)
      GenServer.call(owner, :create_table)

      assert :ok = McpTools.inject_into_tidewave()

      assert [{:tools, {tools, dispatch, browser_tools, browser_dispatch}}] =
               :ets.lookup(:tidewave_tools, :tools)

      names = Enum.map(tools, & &1.name)

      # Tidewave's own tool survived, ours arrived.
      assert "existing_tidewave_tool" in names
      assert "raxol_screenshot" in names
      assert Map.has_key?(dispatch, "raxol_screenshot")

      # The browser halves are Tidewave's; we pass them through untouched.
      assert browser_tools == [%{name: "browser_eval"}]
      assert Map.keys(browser_dispatch) == ["browser_eval"]
    end

    # The route that used to bypass every gate: Tidewave dispatches out of its own
    # map, so a raw callback written there never reaches `Raxol.MCP.Server`. What
    # is injected is a closure that re-enters through `tools/call`, so the
    # authorizer applies here exactly as it does over stdio or SSE.
    test "an injected callback is gated by the server's authorizer" do
      {:ok, owner} = start_supervised(TidewaveTableOwner)
      GenServer.call(owner, :create_table)

      registry = registry!()
      :ok = McpTools.register(registry)

      {:ok, server} =
        Raxol.MCP.Server.start_link(
          name: :"srv_#{System.unique_integer([:positive])}",
          registry: registry,
          authorizer: Raxol.MCP.Authorizer.deny_all(:policy_says_no)
        )

      assert :ok = McpTools.inject_into_tidewave(server: server)

      [{:tools, {_tools, dispatch, _bt, _bd}}] =
        :ets.lookup(:tidewave_tools, :tools)

      # Even a read is refused, because the authorizer -- not the annotation --
      # is what decides once one is configured.
      assert {:error, message} = dispatch["raxol_list"].(%{})
      assert message =~ "authorization_required"
      assert message =~ "policy_says_no"
    end

    # The fallback that would undo the whole thing: if an unreachable server made
    # the wrapper fall back to the raw callback, the ungated path would reappear
    # exactly when the gate is unavailable.
    test "an injected callback refuses when the MCP server is not running" do
      {:ok, owner} = start_supervised(TidewaveTableOwner)
      GenServer.call(owner, :create_table)

      assert :ok = McpTools.inject_into_tidewave(server: :no_such_mcp_server)

      [{:tools, {_tools, dispatch, _bt, _bd}}] =
        :ets.lookup(:tidewave_tools, :tools)

      assert {:error, message} = dispatch["raxol_list"].(%{})
      assert message =~ "cannot be authorized"
    end

    # Tidewave dispatches synchronously and has no channel to be prompted on, so
    # an ASK decision must resolve to a deny for it and involve nobody else.
    #
    # It used to involve somebody else. `handle_message/2` attributes a call to
    # the `:default` connection, which is what `Transport.Stdio` subscribes as,
    # so an ASK on a Tidewave-dispatched call sent the prompt to the STDIO client
    # and let that client's answer resolve this call. This test stands in as that
    # stdio client: it subscribes as `:default`, advertises elicitation, and must
    # be left entirely alone.
    test "an ask decision denies here without prompting the stdio client" do
      {:ok, owner} = start_supervised(TidewaveTableOwner)
      GenServer.call(owner, :create_table)

      registry = registry!()
      :ok = McpTools.register(registry)

      {:ok, server} =
        Raxol.MCP.Server.start_link(
          name: :"srv_#{System.unique_integer([:positive])}",
          registry: registry,
          authorizer: fn _tool, _args, _ctx -> {:ask, "may I?"} end
        )

      # Become the elicitation-capable client on the default connection.
      :ok = Raxol.MCP.Server.subscribe(server, self())

      {:reply, _} =
        Raxol.MCP.Server.handle_message(server, %{
          jsonrpc: "2.0",
          id: 1,
          method: "initialize",
          params: %{"capabilities" => %{"elicitation" => %{}}}
        })

      assert :ok = McpTools.inject_into_tidewave(server: server)

      [{:tools, {_tools, dispatch, _bt, _bd}}] =
        :ets.lookup(:tidewave_tools, :tools)

      assert {:error, message} = dispatch["raxol_list"].(%{})
      assert message =~ "authorization_required"

      # The prompt must never have been addressed to us. Under the shared
      # connection id this arrived as an `elicitation/create` notification.
      refute_receive {:mcp_notification, _}, 200
    end

    test "is idempotent: a second inject does not duplicate our tools" do
      {:ok, owner} = start_supervised(TidewaveTableOwner)
      GenServer.call(owner, :create_table)

      assert :ok = McpTools.inject_into_tidewave()
      assert :ok = McpTools.inject_into_tidewave()

      [{:tools, {tools, _dispatch, _bt, _bd}}] =
        :ets.lookup(:tidewave_tools, :tools)

      names = Enum.map(tools, & &1.name)

      assert Enum.count(names, &(&1 == "raxol_screenshot")) == 1
      assert length(names) == length(Enum.uniq(names))
    end
  end
end
