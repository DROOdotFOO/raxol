defmodule Raxol.Headless.McpToolsTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Headless.McpTools

  # The test apps `raxol_start` starts over MCP. A set `:headless_startable`
  # replaces the default demo list, so they are listed alongside the demos,
  # for this module's tests only. BufferServer is not an app: it is listed so
  # the tool's contract refusal stays reachable. Every entry must be loadable,
  # so the out-of-VM probe is listed only by its own test.
  @test_startable [
    Raxol.Headless.McpToolsTest.SizedApp,
    Raxol.Headless.McpToolsTest.InjectedTextApp,
    Raxol.Terminal.Buffer.BufferServer
  ]

  setup do
    put_startable(McpTools.default_startable() ++ @test_startable)
  end

  # Sets `:headless_startable` for the current test and restores it after.
  defp put_startable(value) do
    previous = Application.fetch_env(:raxol, :headless_startable)
    Application.put_env(:raxol, :headless_startable, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:raxol, :headless_startable, old)
        :error -> Application.delete_env(:raxol, :headless_startable)
      end
    end)
  end

  # Its update/2 on "x" starts a linked process that raises with a credential
  # in the message, then waits: the link takes the dispatcher down with the
  # exception, stacktrace and all, as its exit reason.
  defmodule LeakyApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{}

    @impl true
    def update(%Raxol.Core.Events.Event{type: :key, data: %{char: "x"}}, model) do
      {:ok, _pid} =
        Task.start_link(fn ->
          raise "GET https://api.example.com/v1/x failed: 500 (payload LEAK-MARKER-7Q)"
        end)

      receive do
        :never -> {model, []}
      end
    end

    def update(_message, model), do: {model, []}

    @impl true
    def view(_model), do: Raxol.Core.Renderer.View.text("leaky")

    @impl true
    def subscriptions(_model), do: []
  end

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
    # the exit keeps the subject the refusal, not the session manager. Every
    # call carries a valid id, so the refusal is never the id's.
    defp call_start(args) do
      start_tool().(Map.put_new(args, "id", "path"))
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
      assert message =~ "is not startable over MCP"

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

    # `raxol_start` runs as a callback of the registry it is registered in,
    # so it always starts sessions under a running one.
    defp start_tool_result(args), do: start_tool_result(args, registry!())

    defp start_tool_result(args, registry),
      do:
        Enum.find(McpTools.tools(registry), &(&1.name == "raxol_start")).callback.(args)

    # A `BaseManager` GenServer, so it exports `init/1` and nothing else the
    # runtime wants. It is one of the 527 modules on this tree that would have
    # satisfied a bare `Code.ensure_loaded?/1`, and starting it ran its
    # GenServer `init/1` outside any supervisor.
    test "a real module that is not a Raxol application is refused" do
      assert {:error, message} =
               start_tool_result(%{
                 "module" => "Raxol.Terminal.Buffer.BufferServer",
                 "id" => "notapp"
               })

      assert message =~ "is not a Raxol application"
      assert message =~ "init/1, update/2 and view/1"
    end

    # The two refusals send an operator in opposite directions -- go list it
    # versus go pick a different module -- so the wording has to separate them.
    test "an unlisted module and a non-application module read differently" do
      assert {:error, unlisted} =
               start_tool_result(%{"module" => "NoSuchHeadlessAppAtAll", "id" => "nosuch"})

      assert {:error, not_an_app} =
               start_tool_result(%{
                 "module" => "Raxol.Terminal.Buffer.BufferServer",
                 "id" => "notapp2"
               })

      assert unlisted =~ "is not startable over MCP"
      refute unlisted =~ "is not a Raxol application"
      refute not_an_app =~ "is not startable over MCP"
    end

    # A listed module may be compiled and on the code path but not loaded yet:
    # interactive code loading -- `mix mcp.server`, the documented workflow --
    # is the normal case, and refusing such a module refuses what
    # `raxol_start` asks for. `startable/0` loads it (`Code.ensure_loaded?/1`)
    # when it checks the list. An OTP release boots `:embedded` with
    # everything pre-loaded, so this hides on fly.io and shows up locally.
    #
    # It lives in THIS describe, behind a real `Raxol.Headless`, because the
    # contract gate runs server-side. Asserted from a block with no server, the
    # call exits `:noproc` before ever reaching the gate, and the test passes on
    # an artefact of the downed server rather than on the answer an operator
    # gets.
    #
    # Compiled by a SEPARATE OS PROCESS on purpose: compiling it here would load
    # it into this VM and the test would pass against either version.
    test "a listed module that is compiled but not loaded starts" do
      dir = compile_out_of_vm("Raxol.Headless.McpToolsTest.UnloadedProbe")

      refute :code.is_loaded(Raxol.Headless.McpToolsTest.UnloadedProbe)

      # Unloaded again afterwards, so a repeat in this VM finds it unloaded
      # too. Registered before the session's stop below, so it runs after it.
      on_exit(fn ->
        :code.purge(Raxol.Headless.McpToolsTest.UnloadedProbe)
        :code.delete(Raxol.Headless.McpToolsTest.UnloadedProbe)
        :code.purge(Raxol.Headless.McpToolsTest.UnloadedProbe)
      end)

      Code.append_path(dir)
      on_exit(fn -> Code.delete_path(dir) end)

      put_startable([
        Raxol.Headless.McpToolsTest.UnloadedProbe
        | McpTools.default_startable() ++ @test_startable
      ])

      assert {:ok, message} =
               start_tool_result(%{
                 "module" => "Raxol.Headless.McpToolsTest.UnloadedProbe",
                 "id" => "probe"
               })

      assert message =~ "probe"

      # The session dies with the `Raxol.Headless` the setup started, so in the
      # normal case there is nothing to clean up -- and an unguarded stop races
      # that teardown and exits `:noproc`. Guarded rather than dropped because
      # the setup REUSES an already-running server when it finds one, and then
      # the session really would outlive this test.
      on_exit(fn ->
        if Process.whereis(Raxol.Headless),
          do: Raxol.Headless.stop("probe")
      end)
    end

    # The full TEA triple, not `view/1` alone: this fixture stands in for a real
    # application, and a gate that names `init/1, update/2 and view/1` has to be
    # given something that satisfies it or the test is measuring the gate's
    # refusal instead of the loading it is about.
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

  defmodule SizedApp do
    @moduledoc false
    def init(_), do: %{}
    def update(_msg, model), do: model
    def view(_), do: nil
  end

  # `width`/`height` come from the MCP client and size every frame the session
  # draws, so they are held to the remote ceiling (512 columns, 256 rows,
  # 131072 cells), as SSH windows are. The tool refuses out-of-range sizes
  # (the caller named them) rather than clamping.
  describe "raxol_start size" do
    setup do
      case Process.whereis(Raxol.Headless) do
        nil -> start_supervised!({Raxol.Headless, [name: Raxol.Headless]})
        pid -> pid
      end

      on_exit(fn ->
        if Process.whereis(Raxol.Headless),
          do: Raxol.Headless.stop("sizedok")
      end)

      :ok
    end

    test "a size past the remote ceiling is refused and starts nothing" do
      for {w, h} <- [
            {100_000, 40},
            {120, 100_000},
            {4096, 256},
            {513, 40},
            {120, 257},
            {0, 40},
            {"80", 24}
          ] do
        assert {:error, message} =
                 start_tool_result(%{
                   "module" => inspect(SizedApp),
                   "id" => "sizedno",
                   "width" => w,
                   "height" => h
                 })

        assert message =~ "width at most 512"
        assert message =~ "height at most 256"
        assert message =~ "131072 cells"
        refute "sizedno" in Raxol.Headless.list()
      end
    end

    test "a size at the ceiling starts at that size" do
      assert {:ok, message} =
               start_tool_result(%{
                 "module" => inspect(SizedApp),
                 "id" => "sizedok",
                 "width" => 512,
                 "height" => 256
               })

      assert message =~ "sizedok"
      assert {:ok, buffer} = Raxol.Headless.get_buffer("sizedok")
      assert {buffer.width, buffer.height} == {512, 256}
    end

    test "the input schema states the bounds" do
      %{inputSchema: %{properties: props}} =
        Enum.find(McpTools.tools(), &(&1.name == "raxol_start"))

      assert {props.width.minimum, props.width.maximum} == {1, 512}
      assert {props.height.minimum, props.height.maximum} == {1, 256}
    end
  end

  # A Raxol application that is on no startable list. A test fixture rather
  # than a module of the tree, so the refusal keeps testing something whatever
  # later changes delete.
  defmodule UnlistedApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{}

    @impl true
    def update(_message, model), do: {model, []}

    @impl true
    def view(_model), do: Raxol.Core.Renderer.View.text("unlisted")
  end

  # `raxol_start` runs a module of the caller's choosing in this VM, so the
  # caller picks from a list rather than from the code path.
  describe "raxol_start startable list" do
    setup do
      case Process.whereis(Raxol.Headless) do
        nil -> start_supervised!({Raxol.Headless, [name: Raxol.Headless]})
        pid -> pid
      end

      on_exit(fn ->
        if Process.whereis(Raxol.Headless),
          do: Raxol.Headless.stop("sttable")
      end)

      :ok
    end

    test "an unlisted Raxol application is refused and starts nothing" do
      before = Raxol.Headless.list()

      assert {:error, message} =
               start_tool_result(%{"module" => inspect(UnlistedApp), "id" => "unlist"})

      assert message =~ "is not startable over MCP"
      assert message =~ ":headless_startable"
      assert Raxol.Headless.list() == before
    end

    # The REPL demo evaluates Elixir; the BEAM dashboard sets the VM-wide
    # `:scheduler_wall_time` flag and shows VM internals. Both are playground
    # demos and Raxol applications, and still never startable by an MCP client.
    test "the REPL and BEAM dashboard demos are refused although every other demo is listed" do
      before = Raxol.Headless.list()

      for {demo, id} <- [{"ReplDemo", "repl"}, {"BeamDashboardDemo", "beam"}] do
        assert {:error, message} =
                 start_tool_result(%{"module" => "Raxol.Playground.Demos." <> demo, "id" => id})

        assert message =~ "is not startable over MCP"
      end

      assert Raxol.Headless.list() == before
    end

    # Pinned so that a new demo is a reviewed change to what any MCP client may
    # start, not a silent one. Adding a demo to the Catalog fails this test:
    # list it here if clients may start it, or exclude it in `McpTools`.
    test "the default list is exactly these demos" do
      put_startable([])
      Application.delete_env(:raxol, :headless_startable)

      expected =
        ~w(BarChartDemo ButtonDemo CheckboxDemo CodeBlockDemo ContainerDemo
           CursorTrailDemo EasingDemo FlexLayoutDemo FocusRingDemo
           HarnessApprovalDemo HarnessDiffDemo HarnessPanelsDemo HarnessStatusDemo
           HarnessToolBlocksDemo HarnessTranscriptDemo HeatmapDemo LineChartDemo
           MarkdownDemo MenuDemo ModalDemo OscAmbientDemo PanelHighlightsDemo
           PasswordFieldDemo ProgressDemo RadioGroupDemo SalienceDemo
           ScatterChartDemo ScrollAnchorDemo ScrubberDemo SelectListDemo
           SparklineDemo SplitPaneDemo StatusBarDemo TableDemo TabsDemo
           TextAreaDemo TextDemo TextInputDemo TreeDemo VfsDemo)
        |> Enum.map(&Module.concat(Raxol.Playground.Demos, &1))

      assert {:ok, startable} = McpTools.startable()
      assert Enum.sort(startable) == Enum.sort(expected)
      assert McpTools.default_startable() == startable
    end

    test "a playground demo starts" do
      assert {:ok, message} =
               start_tool_result(%{
                 "module" => "Raxol.Playground.Demos.TableDemo",
                 "id" => "sttable"
               })

      assert message =~ "sttable"
      assert "sttable" in Raxol.Headless.list()
    end

    # Owner decision (2026-10-24): a set list replaces the demos.
    test "a configured list replaces the playground demos" do
      put_startable([Raxol.Playground.Demos.TableDemo])

      assert {:error, message} =
               start_tool_result(%{
                 "module" => "Raxol.Playground.Demos.TabsDemo",
                 "id" => "rtabs"
               })

      assert message =~ "is not startable over MCP"
      refute "rtabs" in Raxol.Headless.list()

      assert {:ok, _} =
               start_tool_result(%{
                 "module" => "Raxol.Playground.Demos.TableDemo",
                 "id" => "sttab"
               })

      assert "sttab" in Raxol.Headless.list()
    end

    @bad_startable [
      Raxol.Playground.Demos.TableDemo,
      ["Raxol.Playground.Demos.TableDemo"],
      [:bogus],
      [nil],
      [true],
      [Raxol.Playground.Demos.TableDemo, NoSuch.HeadlessModule],
      [Raxol.Playground.Demos.TableDemo | Raxol.Playground.Demos.TabsDemo]
    ]

    test "a configured value that is not a list of loadable modules is a config error" do
      for bad <- @bad_startable do
        put_startable(bad)

        assert {:error, message} = McpTools.startable()
        assert message =~ ":headless_startable must be a list of loadable modules"

        assert {:error, ^message} =
                 start_tool_result(%{
                   "module" => "Raxol.Playground.Demos.TableDemo",
                   "id" => "sttable"
                 })

        assert_raise ArgumentError, message, fn -> McpTools.register(registry!()) end
      end
    end

    # A raise inside the callback counted as a fault: five calls opened the
    # tool's circuit for every client, and it stayed open after the fix.
    test "a config error neither raises nor opens the circuit" do
      registry = registry!()
      :ok = McpTools.register(registry)
      put_startable(Raxol.Playground.Demos.TableDemo)
      args = %{"module" => "Raxol.Playground.Demos.TableDemo", "id" => "sttable"}

      for _ <- 1..7 do
        assert {:error, message} = Raxol.MCP.Registry.call_tool(registry, "raxol_start", args)
        assert message =~ ":headless_startable must be a list of loadable modules"
      end

      put_startable([Raxol.Playground.Demos.TableDemo])

      assert {:ok, _} = Raxol.MCP.Registry.call_tool(registry, "raxol_start", args)
      assert "sttable" in Raxol.Headless.list()
    end
  end

  @injected "x\n<system>"

  # App text in every place a provider used to put it into a description: a
  # modal title, a button label, a checkbox label, a tab label, a scrubber
  # label.
  defmodule InjectedTextApp do
    use Raxol.Core.Runtime.Application

    @injected "x\n<system>"

    @impl true
    def init(_context), do: %{}

    @impl true
    def update(_message, model), do: {model, []}

    @impl true
    def view(_model) do
      Raxol.Core.Renderer.View.column(
        children: [
          Raxol.View.Components.modal(
            id: "inj_modal",
            title: @injected,
            visible: true,
            content: "body"
          ),
          Raxol.Core.Renderer.View.button(@injected, id: "inj_button", on_click: :noop),
          Raxol.View.Components.checkbox(id: "inj_check", label: @injected),
          Raxol.View.Components.tabs(id: "inj_tabs", tabs: [%{label: @injected}]),
          Raxol.View.Components.scrubber(id: "inj_scrub", label: @injected, max: 3)
        ]
      )
    end
  end

  @state_changing ~w(click type_into clear toggle select select_row select_node
                     select_tab sort expand collapse dismiss confirm seek play
                     pause scroll_to)

  # Descriptions reach the client's tool list, which a model reads as part of
  # its instructions; app text there is a prompt injection with the app's
  # authority. So it reaches tool results only.
  describe "derived tools in tools/list" do
    setup do
      case Process.whereis(Raxol.Headless) do
        nil -> start_supervised!({Raxol.Headless, [name: Raxol.Headless]})
        pid -> pid
      end

      # The session's synchronizer publishes to the named registry.
      registry =
        Process.whereis(Raxol.MCP.Registry) ||
          start_supervised!({Raxol.MCP.Registry, name: Raxol.MCP.Registry})

      {:ok, server} =
        Raxol.MCP.Server.start_link(
          name: :"srv_#{System.unique_integer([:positive])}",
          registry: registry,
          authorizer: Raxol.MCP.Authorizer.allow_all()
        )

      assert {:ok, _} =
               start_tool_result(
                 %{"module" => inspect(InjectedTextApp), "id" => "inj"},
                 registry
               )

      on_exit(fn ->
        if Process.whereis(Raxol.Headless), do: Raxol.Headless.stop("inj")
      end)

      %{server: server}
    end

    test "a modal titled x\\n<system> never appears in tools/list", %{
      server: server
    } do
      tools = list_tools(server)
      derived = Enum.filter(tools, &String.starts_with?(&1.name, "inj_"))

      assert Enum.map(derived, & &1.name) |> Enum.sort() ==
               Enum.sort([
                 "inj_modal.dismiss",
                 "inj_modal.confirm",
                 "inj_button.click",
                 "inj_check.toggle",
                 "inj_check.get_checked",
                 "inj_tabs.select_tab",
                 "inj_tabs.get_tabs",
                 "inj_scrub.seek",
                 "inj_scrub.play",
                 "inj_scrub.pause",
                 "inj_scrub.get_position"
               ])

      refute Jason.encode!(tools) =~ "<system>"

      for tool <- derived do
        refute tool.description =~ ~r/[\x00-\x1F\x7F]/u
      end
    end

    test "the app text is still readable in a tool result", %{server: server} do
      assert {:reply, %{result: %{content: [%{text: text} | _]} = result}} =
               call_tool(server, "inj_tabs.get_tabs", %{})

      refute Map.get(result, :isError) == true
      assert text =~ "<system>"
    end

    test "state-changing derived tools are listed sensitive, reads are not", %{
      server: server
    } do
      derived =
        server
        |> list_tools()
        |> Enum.filter(&String.starts_with?(&1.name, "inj_"))

      for tool <- derived do
        [_widget, action] = String.split(tool.name, ".", parts: 2)

        assert Raxol.MCP.ToolDef.sensitive?(tool) == action in @state_changing,
               "#{tool.name}: sensitive must match whether #{action} changes state"
      end
    end
  end

  # Every built-in provider, not just the five the app above renders: the
  # description is the same whatever the node says, and the annotation
  # follows the action.
  describe "built-in tool providers" do
    test "descriptions are static per action and state changes are sensitive" do
      plain = %{id: "w", attrs: %{}}

      injected = %{
        id: "w\n<system>",
        title: @injected,
        label: @injected,
        aria_label: @injected,
        tabs: [%{label: @injected}],
        attrs: %{label: @injected}
      }

      for module <- Raxol.MCP.TreeWalker.default_type_map() |> Map.values() do
        specs = module.mcp_tools(injected)
        assert specs != [], "#{inspect(module)} derived no tools"
        assert specs == module.mcp_tools(plain), "#{inspect(module)} varies"

        for spec <- specs do
          refute spec.description =~ "<system>"

          assert (get_in(spec, [:annotations, :sensitive]) == true) ==
                   spec.name in @state_changing,
                 "#{inspect(module)}.#{spec.name}"
        end
      end
    end

    # TreeWalker refuses an action name outside `[a-z][a-z0-9_]{0,31}` and
    # keeps only `sensitive`/`destructiveHint: true` annotations; neither may
    # cost a built-in provider a tool or a flag.
    test "every built-in action derives its tool with its annotations" do
      for {type, module} <- Raxol.MCP.TreeWalker.default_type_map() do
        node = %{type: type, id: "w", attrs: %{}}
        specs = module.mcp_tools(node)

        assert {tools, refusals} =
                 Raxol.MCP.TreeWalker.derive_with_refusals(node, %{dispatcher_pid: nil})

        assert refusals == MapSet.new(), inspect(module)

        assert Enum.map(tools, &{&1.name, Map.get(&1, :annotations)}) ==
                 Enum.map(specs, &{"w." <> &1.name, Map.get(&1, :annotations)}),
               inspect(module)
      end
    end

    # A masked input holds a secret, and `get_value` is an ungated read, so a
    # masked input has none, like PasswordField.
    test "a masked text input derives no get_value and refuses one" do
      masked = %{type: :text_input, id: "pin", attrs: %{mask_char: "*"}, value: "hunter2"}
      ctx = %{dispatcher_pid: nil}

      names = Enum.map(Raxol.MCP.TreeWalker.derive_tools(masked, ctx), & &1.name)
      assert names == ["pin.type_into", "pin.clear"]

      for node <- [masked, %{masked | attrs: %{}} |> Map.put(:mask_char, "*")] do
        assert {:error, message} =
                 Raxol.UI.Components.Input.TextInput.handle_tool_call("get_value", %{}, %{
                   widget_id: "pin",
                   widget_state: node
                 })

        refute message =~ "hunter2"
      end

      plain = %{masked | attrs: %{}}
      assert "pin.get_value" in Enum.map(Raxol.MCP.TreeWalker.derive_tools(plain, ctx), & &1.name)
    end

    # The same secret through the session's resources: `widgets` is built
    # from each Component's accessibility node, `context` from the raw view
    # tree. Both stay readable without a read authorizer.
    test "a masked or password value is in neither the widgets nor the context resource" do
      registry = registry!()
      session = "masked_#{System.unique_integer([:positive])}"

      {:ok, sync} =
        Raxol.MCP.ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: session
        )

      tree = %{
        type: :column,
        children: [
          %{type: :text_input, id: "pin", value: "SECRET-node", mask_char: "*"},
          %{type: :text_input, id: "pin2", attrs: %{mask_char: "*", value: "SECRET-attrs"}},
          %{type: :password_field, id: "pw", value: "SECRET-pw", attrs: %{value: "SECRET-pwa"}},
          %{type: :text_input, id: "name", value: "visible-name"}
        ]
      }

      :ok = Raxol.MCP.ToolSynchronizer.sync(sync, tree)
      # A call after the cast: the render has been handled.
      _state = :sys.get_state(sync)

      for resource <- ["widgets", "context"] do
        uri = "raxol://session/#{session}/#{resource}"
        assert {:ok, value} = Raxol.MCP.Registry.read_resource(registry, uri)
        json = Jason.encode!(value)
        refute json =~ "SECRET", "#{resource}: #{json}"
        assert json =~ "visible-name", resource
      end

      GenServer.stop(sync)
    end

    # The other half of the breaking change: an embedder with no authorizer
    # can still read a widget, but no longer drive one.
    test "an unguarded server refuses a derived state change and runs a read" do
      registry = registry!()

      {:ok, server} =
        Raxol.MCP.Server.start_link(
          name: :"srv_#{System.unique_integer([:positive])}",
          registry: registry,
          authorizer: nil
        )

      tools =
        Raxol.MCP.TreeWalker.derive_tools(
          Raxol.View.Components.checkbox(id: "chk", label: "Agree"),
          %{dispatcher_pid: nil}
        )

      :ok = Raxol.MCP.Registry.register_tools(registry, tools)

      assert {:reply, %{result: %{content: [%{text: text} | _], isError: true}}} =
               call_tool(server, "chk.toggle", %{})

      assert Jason.decode!(text)["detail"] =~ "sensitive_tool_unguarded"

      assert {:reply, %{result: result}} = call_tool(server, "chk.get_checked", %{})
      refute Map.get(result, :isError) == true
    end
  end

  defp list_tools(server) do
    assert {:reply, %{result: %{tools: tools}}} =
             Raxol.MCP.Server.handle_message(server, %{
               jsonrpc: "2.0",
               id: System.unique_integer([:positive]),
               method: "tools/list"
             })

    tools
  end

  # A dispatcher that dies on a key takes its exit reason with it, and an
  # exception in that reason carries whatever its message held: a URL, a token.
  # The tool result reaches a model, so it gets the class of the exit and never
  # the payload, as `Raxol.MCP.Registry` does for a callback that exits.
  describe "raxol_send_key when the dispatcher dies on the key" do
    setup do
      case Process.whereis(Raxol.Headless) do
        nil -> start_supervised!({Raxol.Headless, [name: Raxol.Headless]})
        pid -> pid
      end

      {:ok, id} = Raxol.Headless.start(LeakyApp, id: "leaky")

      on_exit(fn ->
        if Process.whereis(Raxol.Headless), do: Raxol.Headless.stop(id)
      end)

      %{id: id}
    end

    @tag capture_log: true
    test "answers the exit's class, not the exception's message", %{id: id} do
      send_key = Enum.find(McpTools.tools(), &(&1.name == "raxol_send_key"))

      assert {:error, message} =
               send_key.callback.(%{"id" => id, "key" => "x"})

      refute message =~ "LEAK-MARKER-7Q"
      assert message == inspect({:dispatch_failed, :unknown})
    end
  end

  defmodule MaskedApp do
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{pin: "hunter2-SECRET", name: "visible-name"}

    @impl true
    def update(_message, model), do: {model, []}

    @impl true
    def view(model) do
      %{
        type: :column,
        children: [
          %{type: :text_input, id: "name", value: model.name},
          %{type: :text_input, id: "pin", value: model.pin, mask_char: "*"}
        ]
      }
    end

    @impl true
    def subscriptions(_model), do: []
  end

  # A masked input's value is on screen as its mask and in the model as
  # plaintext. Neither MCP channel hands the plaintext to a client the
  # deployment did not authorize for it.
  describe "a masked input over MCP" do
    setup do
      case Process.whereis(Raxol.Headless) do
        nil -> start_supervised!({Raxol.Headless, [name: Raxol.Headless]})
        pid -> pid
      end

      {:ok, id} = Raxol.Headless.start(MaskedApp, id: :masked_mcp)

      on_exit(fn ->
        if Process.whereis(Raxol.Headless), do: Raxol.Headless.stop(id)
      end)

      %{id: Atom.to_string(id), registry: registry!()}
    end

    test "raxol_screenshot shows the mask, never the value", %{id: id, registry: registry} do
      server = serving_server!(registry, Raxol.MCP.Authorizer.allow_all())

      assert {:reply, %{result: %{content: [%{text: text} | _]} = result}} =
               call_tool(server, "raxol_screenshot", %{"id" => id})

      refute Map.get(result, :isError) == true
      assert text =~ "visible-name"
      assert text =~ "**************"
      refute text =~ "hunter2"
    end

    test "raxol_get_model is refused when no authorizer is configured", %{
      id: id,
      registry: registry
    } do
      assert {:reply, %{result: %{content: [%{text: text} | _], isError: true}}} =
               call_tool(serving_server!(registry, nil), "raxol_get_model", %{"id" => id})

      refute text =~ "hunter2"
      payload = Jason.decode!(text)
      assert payload["error"] == "authorization_required"
      assert payload["detail"] =~ "sensitive_tool_unguarded"
    end

    test "raxol_get_model answers once an authorizer allows it", %{
      id: id,
      registry: registry
    } do
      server = serving_server!(registry, Raxol.MCP.Authorizer.allow_all())

      assert {:reply, %{result: %{content: [%{text: text} | _]} = result}} =
               call_tool(server, "raxol_get_model", %{"id" => id})

      refute Map.get(result, :isError) == true
      assert text =~ "hunter2-SECRET"
    end
  end

  # Booted before the tools are registered, as `Raxol.Application` does: an
  # unguarded server would refuse to boot on them otherwise.
  defp serving_server!(registry, authorizer) do
    {:ok, server} =
      Raxol.MCP.Server.start_link(
        name: :"srv_#{System.unique_integer([:positive])}",
        registry: registry,
        authorizer: authorizer
      )

    :ok = McpTools.register(registry)
    server
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

    # It returns the whole model, and a masked input's value lives there.
    test "raxol_get_model is sensitive", %{by_name: by_name} do
      assert Raxol.MCP.ToolDef.sensitive?(by_name["raxol_get_model"])
    end

    test "the screenshot and the session list are not gated", %{by_name: by_name} do
      for name <- ["raxol_screenshot", "raxol_list"] do
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

      assert sensitive == ["raxol_get_model", "raxol_send_key", "raxol_start", "raxol_stop"]
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

      for name <- ["raxol_start", "raxol_send_key", "raxol_get_model", "raxol_stop"] do
        assert message =~ name
      end
    end

    test "the same tree boots when an authorizer is supplied" do
      registry = registry!()
      :ok = McpTools.register(registry)

      assert {:ok, _server} =
               Raxol.MCP.Server.start_link(
                 name: :"srv_#{System.unique_integer([:positive])}",
                 registry: registry,
                 authorizer: Raxol.MCP.Authorizer.allow_all()
               )
    end

    # Owner decision (2026-10-24): the boot refusal scans static tools only.
    # An embedder with no authorizer and live sessions has derived sensitive
    # tools registered when its Server restarts; refusing to boot on them used
    # to exhaust the restart intensity and take the whole MCP tree down.
    test "an unguarded Server restarts with derived sensitive tools and still refuses them" do
      unique = System.unique_integer([:positive])
      registry = :"reg_#{unique}"
      server_name = :"srv_#{unique}"

      sup =
        start_supervised!(
          {Raxol.MCP.Supervisor, registry_name: registry, server_name: server_name}
        )

      # Registered the way a session's are: by its synchronizer, the only
      # caller that marks tools derived.
      {:ok, sync} =
        Raxol.MCP.ToolSynchronizer.start_link(
          registry: registry,
          dispatcher_pid: self(),
          session_id: "restart_#{unique}"
        )

      button = Raxol.Core.Renderer.View.button("Go", id: "restart_btn", on_click: :go)
      :ok = Raxol.MCP.ToolSynchronizer.sync(sync, button)
      # A call after the cast: the render has been handled.
      _state = :sys.get_state(sync)

      assert [%{annotations: %{sensitive: true}}] =
               registry
               |> Raxol.MCP.Registry.list_tools()
               |> Enum.filter(&(&1.name == "restart_btn.click"))

      server = Process.whereis(server_name)
      ref = Process.monitor(server)
      Process.exit(server, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server, :killed}

      # The supervisor handles the exit before this call, restarting the Server.
      assert {Raxol.MCP.Server, restarted, :worker, _} =
               sup
               |> Supervisor.which_children()
               |> List.keyfind(Raxol.MCP.Server, 0)

      assert is_pid(restarted) and restarted != server

      assert {:reply, %{result: %{content: [%{text: text} | _], isError: true}}} =
               call_tool(server_name, "restart_btn.click", %{})

      payload = Jason.decode!(text)
      assert payload["error"] == "authorization_required"
      assert payload["detail"] =~ "sensitive_tool_unguarded"
    end

    # Booting and satisfying the SSE gate are different questions, and an
    # authorizer alone answers only the first. `:authorizer_source` defaults to
    # `:default` so an embedder who forgets it fails closed rather than being
    # taken at its word -- which is the point of the gate.
    test "an authorizer alone does not satisfy the SSE gate" do
      registry = registry!()
      :ok = McpTools.register(registry)

      assert {:ok, defaulted} =
               Raxol.MCP.Server.start_link(
                 name: :"srv_#{System.unique_integer([:positive])}",
                 registry: registry,
                 authorizer: Raxol.MCP.Authorizer.allow_all()
               )

      refute Raxol.MCP.Server.authorization_configured?(defaulted)

      assert {:ok, configured} =
               Raxol.MCP.Server.start_link(
                 name: :"srv_#{System.unique_integer([:positive])}",
                 registry: registry,
                 authorizer: Raxol.MCP.Authorizer.allow_all(),
                 authorizer_source: :configured
               )

      assert Raxol.MCP.Server.authorization_configured?(configured)
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
