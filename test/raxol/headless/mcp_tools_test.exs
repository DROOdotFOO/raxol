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

    test "a path inside the configured root is accepted", %{root: root} do
      System.put_env("RAXOL_HEADLESS_PATH_ROOT", root)

      # Not `{:error, _}` from RESOLUTION: it either reached Headless or came
      # back with Headless's own answer. Either way the path was let through.
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

    test "an absolute path is jailed under the root, never honoured verbatim",
         %{root: root} do
      System.put_env("RAXOL_HEADLESS_PATH_ROOT", root)

      # `confine/3` JOINS the request under the root, so an absolute path is
      # remapped rather than refused -- it lands at <root>/etc/evil.exs, which
      # is the safe outcome and the one worth pinning. Refusing would be fine
      # too; silently honouring `/etc/evil.exs` would not.
      assert {:resolved, target} = resolved_target(%{"path" => "/etc/evil.exs"})

      refute target == "/etc/evil.exs"
      assert String.ends_with?(target, "/etc/evil.exs")
      assert target =~ Path.basename(root)
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
      assert message =~ "not loaded"

      assert_raise ArgumentError, fn ->
        String.to_existing_atom("Elixir." <> name)
      end
    end

    test "the module refusal does not steer the caller onto the path branch" do
      assert {:error, message} =
               call_start(%{"module" => "NoSuchHeadlessModuleEver"})

      refute message =~ "path"
    end

    # The atom table is not the same question as "does this module exist".
    # Interactive code loading -- `mix mcp.server`, the documented workflow -- is
    # the normal case, and there a module's atom does not exist until something
    # loads it. Refusing on the atom table alone therefore refuses modules that
    # are compiled and sitting on the code path, which is what `raxol_start`
    # asks for. An OTP release boots `:embedded` with everything pre-loaded, so
    # this hides on fly.io and shows up locally.
    #
    # Compiled by a SEPARATE OS PROCESS on purpose: compiling it here would mint
    # the atom in this VM and the test would pass against either version.
    test "a compiled-but-unloaded module on the code path resolves" do
      name = "HeadlessUnloadedProbe#{System.unique_integer([:positive])}"
      dir = compile_out_of_vm(name)

      # No one in this VM has ever named it.
      assert_raise ArgumentError, fn ->
        String.to_existing_atom("Elixir." <> name)
      end

      Code.append_path(dir)
      on_exit(fn -> Code.delete_path(dir) end)

      assert {:resolved, target} = resolved_target(%{"module" => name})
      assert Atom.to_string(target) == "Elixir." <> name
    end

    defp compile_out_of_vm(name) do
      dir =
        Path.join(
          System.tmp_dir!(),
          "raxol-unloaded-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      source = Path.join(dir, "probe.ex")
      File.write!(source, "defmodule #{name} do\n  def view(_), do: :ok\nend\n")
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
