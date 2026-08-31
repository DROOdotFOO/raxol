defmodule Raxol.Agent.Actions.LspTest do
  # Each test spawns a real language server subprocess and a pool; they must
  # not share the process-global cwd.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Actions.Lsp
  alias Raxol.Agent.Lsp.Config
  alias Raxol.Agent.Lsp.Pool

  @server Path.expand("../../../support/fake_lsp_server.py", __DIR__)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-lsp-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    previous = System.get_env("RAXOL_CLI_CWD")
    System.put_env("RAXOL_CLI_CWD", dir)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("RAXOL_CLI_CWD")
        value -> System.put_env("RAXOL_CLI_CWD", value)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  # A config table pointing every `.toy` file at the fake server, optionally
  # with behaviour flags.
  defp servers(args \\ []) do
    [
      %{
        name: "toy",
        command: @server,
        args: args,
        extensions: [".toy"],
        language_id: "toy"
      }
    ]
  end

  defp pool(dir, args \\ []) do
    {:ok, pool} = Pool.start_link(root: dir, servers: servers(args))
    on_exit(fn -> Pool.stop(pool) end)
    pool
  end

  defp write(dir, name, content) do
    File.write!(Path.join(dir, name), content)
    name
  end

  defp context(pool, extra \\ %{}), do: Map.merge(%{lsp_pool: pool}, extra)

  describe "diagnostics" do
    test "reports what the server publishes for a file", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n  BROKEN thing\n  SUSPECT other\n")

      assert {:ok, result} =
               Lsp.Query.run(%{op: "diagnostics", path: "a.toy"}, context(pool(dir)))

      assert [error, warning] = result.diagnostics
      assert error.severity == "error"
      assert error.line == 2
      assert error.message == "this line is broken"
      assert error.source == "fake-lsp"
      assert warning.severity == "warning"
      assert warning.line == 3
    end

    test "a clean file reports no diagnostics", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n  fine\n")

      assert {:ok, %{diagnostics: []}} =
               Lsp.Query.run(%{op: "diagnostics", path: "a.toy"}, context(pool(dir)))
    end

    test "re-reads the file after it changes on disk", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n  fine\n")
      p = pool(dir)

      assert {:ok, %{diagnostics: []}} =
               Lsp.Query.run(%{op: "diagnostics", path: "a.toy"}, context(p))

      write(dir, "a.toy", "def alpha\n  BROKEN now\n")

      assert {:ok, %{diagnostics: [%{line: 2}]}} =
               Lsp.Query.run(%{op: "diagnostics", path: "a.toy"}, context(p))
    end

    test "a server that never publishes is a timeout, not a clean bill", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n  BROKEN thing\n")

      assert {:error, :diagnostics_timeout} =
               Lsp.Query.run(
                 %{op: "diagnostics", path: "a.toy"},
                 context(pool(dir, ["--no-diagnostics"]))
               )
    end
  end

  describe "queries" do
    setup %{dir: dir} do
      write(dir, "a.toy", "def alpha\n  alpha and beta\ndef beta\n")
      %{pool: pool(dir)}
    end

    test "symbols lists the file's declarations", %{pool: p} do
      assert {:ok, %{symbols: symbols}} =
               Lsp.Query.run(%{op: "symbols", path: "a.toy"}, context(p))

      assert [%{name: "alpha", kind: "function", line: 1}, %{name: "beta", line: 3}] = symbols
    end

    test "definition resolves a use to its declaration", %{pool: p} do
      # Line 2, column 3 is inside the `alpha` use.
      assert {:ok, %{locations: [location]}} =
               Lsp.Query.run(
                 %{op: "definition", path: "a.toy", line: 2, column: 3},
                 context(p)
               )

      assert location.path == "a.toy"
      assert location.line == 1
    end

    test "references finds every use", %{pool: p} do
      assert {:ok, %{locations: locations}} =
               Lsp.Query.run(
                 %{op: "references", path: "a.toy", line: 1, column: 5},
                 context(p)
               )

      assert Enum.map(locations, & &1.line) == [1, 2]
      assert Enum.all?(locations, &(&1.path == "a.toy"))
    end

    test "hover returns the server's description", %{pool: p} do
      assert {:ok, %{hover: hover}} =
               Lsp.Query.run(%{op: "hover", path: "a.toy", line: 1, column: 5}, context(p))

      assert hover =~ "alpha"
    end

    test "a position query without a line is refused", %{pool: p} do
      assert {:error, :line_required} =
               Lsp.Query.run(%{op: "definition", path: "a.toy"}, context(p))
    end

    test "an unknown op is refused", %{pool: p} do
      assert {:error, {:unknown_op, "wat"}} =
               Lsp.Query.run(%{op: "wat", path: "a.toy"}, context(p))
    end
  end

  describe "containment" do
    test "a path outside the workspace is refused", %{dir: dir} do
      assert {:error, :outside_cwd} =
               Lsp.Query.run(
                 %{op: "diagnostics", path: "../escape.toy"},
                 context(pool(dir))
               )
    end

    test "with no pool wired the tool declines rather than spawning one", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n")

      assert {:error, :lsp_not_available} =
               Lsp.Query.run(%{op: "symbols", path: "a.toy"}, %{})
    end

    test "a file with no configured server says so", %{dir: dir} do
      write(dir, "a.unknown", "hello\n")

      assert {:error, :no_server} =
               Lsp.Query.run(%{op: "symbols", path: "a.unknown"}, context(pool(dir)))
    end
  end

  describe "rename" do
    test "rewrites every occurrence and reports the files touched", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n  alpha and beta\ndef beta\n")

      assert {:ok, result} =
               Lsp.Rename.run(
                 %{path: "a.toy", line: 1, column: 5, new_name: "renamed"},
                 context(pool(dir))
               )

      assert result.new_name == "renamed"
      assert result.edits == 2
      assert [%{path: "a.toy", edits: 2}] = result.changed

      assert File.read!(Path.join(dir, "a.toy")) ==
               "def renamed\n  renamed and beta\ndef beta\n"
    end

    test "a server that refuses the rename does not report success", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n")
      before = File.read!(Path.join(dir, "a.toy"))

      assert {:error, :rename_not_possible} =
               Lsp.Rename.run(
                 %{path: "a.toy", line: 1, column: 5, new_name: "renamed"},
                 context(pool(dir, ["--rename-refuses"]))
               )

      assert File.read!(Path.join(dir, "a.toy")) == before
    end

    test "an edit aimed outside the workspace is refused and nothing is written", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n")
      before = File.read!(Path.join(dir, "a.toy"))

      assert {:error, {:rename_outside_workspace, "/etc/passwd"}} =
               Lsp.Rename.run(
                 %{path: "a.toy", line: 1, column: 5, new_name: "renamed"},
                 context(pool(dir, ["--rename-escapes"]))
               )

      assert File.read!(Path.join(dir, "a.toy")) == before
    end

    test "a name that would corrupt the file is refused before the server sees it", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n")
      p = pool(dir)

      for bad <- ["", "   ", "two\nlines"] do
        assert {:error, :invalid_name} =
                 Lsp.Rename.run(
                   %{path: "a.toy", line: 1, column: 5, new_name: bad},
                   context(p)
                 )
      end
    end

    test "preserves a file that does not end in a newline", %{dir: dir} do
      write(dir, "a.toy", "def alpha")

      assert {:ok, _result} =
               Lsp.Rename.run(
                 %{path: "a.toy", line: 1, column: 5, new_name: "renamed"},
                 context(pool(dir))
               )

      assert File.read!(Path.join(dir, "a.toy")) == "def renamed"
    end

    test "an edit on a line with non-ASCII text lands on the right characters", %{dir: dir} do
      # LSP counts UTF-16 code units. The emoji is two of them and one
      # codepoint, so a codepoint-based slice would cut one column early.
      write(dir, "a.toy", "def alpha\n  # 🚀 alpha here\n")

      assert {:ok, _result} =
               Lsp.Rename.run(
                 %{path: "a.toy", line: 1, column: 5, new_name: "beta"},
                 context(pool(dir))
               )

      assert File.read!(Path.join(dir, "a.toy")) == "def beta\n  # 🚀 beta here\n"
    end

    test "lsp_rename is gated but lsp is not" do
      assert Lsp.Rename.__action_meta__().sensitive
      refute Lsp.Query.__action_meta__().sensitive
      assert Lsp.read_only() == [Lsp.Query]
    end
  end

  describe "pool lifecycle" do
    test "starts one server per language, reused across calls", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n")
      write(dir, "b.toy", "def beta\n")
      p = pool(dir)

      assert {:ok, _} = Lsp.Query.run(%{op: "symbols", path: "a.toy"}, context(p))
      assert Pool.running(p) == ["toy"]

      assert {:ok, _} = Lsp.Query.run(%{op: "symbols", path: "b.toy"}, context(p))
      assert Pool.running(p) == ["toy"]
    end

    test "the pool dies with its owner, taking the server with it", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n")
      test = self()

      owner =
        spawn(fn ->
          {:ok, p} = Pool.start_link(root: dir, servers: servers())
          {:ok, _} = Lsp.Query.run(%{op: "symbols", path: "a.toy"}, %{lsp_pool: p})
          send(test, {:ready, p})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:ready, p}, 30_000
      pool_ref = Process.monitor(p)

      send(owner, :stop)

      assert_receive {:DOWN, ^pool_ref, :process, ^p, _reason}, 5_000
      refute Process.alive?(p)
    end

    test "a missing server binary is reported, not crashed on", %{dir: dir} do
      write(dir, "a.toy", "def alpha\n")

      table = [
        %{
          name: "toy",
          command: "definitely-not-a-real-language-server",
          args: [],
          extensions: [".toy"],
          language_id: "toy"
        }
      ]

      {:ok, p} = Pool.start_link(root: dir, servers: table)
      on_exit(fn -> Pool.stop(p) end)

      assert {:error, {:not_installed, "definitely-not-a-real-language-server"}} =
               Lsp.Query.run(%{op: "symbols", path: "a.toy"}, context(p))
    end
  end

  describe "config" do
    test "defaults cover the common languages" do
      names = Config.defaults() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["elixir", "go", "python", "rust", "typescript"]
    end

    test "maps a file to its server by extension" do
      assert {:ok, %{name: "toy"}} = Config.for_path(servers(), "lib/a.toy")
    end

    test "an unclaimed extension has no server" do
      assert {:error, :no_server} = Config.for_path(servers(), "lib/a.rb")
    end

    test "a repo file adds a server", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".raxol"))

      File.write!(
        Path.join(dir, ".raxol/lsp.json"),
        ~s({"servers": {"zig": {"command": "zls", "extensions": [".zig"]}}})
      )

      table = Config.load(dir)
      assert %{command: "zls", extensions: [".zig"]} = Enum.find(table, &(&1.name == "zig"))
      # The built-ins survive alongside it.
      assert Enum.find(table, &(&1.name == "elixir"))
    end

    test "overriding a built-in by name keeps its extensions", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".raxol"))

      File.write!(
        Path.join(dir, ".raxol/lsp.json"),
        ~s({"servers": {"elixir": {"command": "lexical"}}})
      )

      assert %{command: "lexical", extensions: extensions} =
               dir |> Config.load() |> Enum.find(&(&1.name == "elixir"))

      assert ".ex" in extensions
    end

    test "a malformed file falls back to the defaults", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".raxol"))
      File.write!(Path.join(dir, ".raxol/lsp.json"), "{not json")

      assert Config.load(dir) == Enum.sort_by(Config.defaults(), & &1.name)
    end

    test "an entry with no command is dropped", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, ".raxol"))

      File.write!(
        Path.join(dir, ".raxol/lsp.json"),
        ~s({"servers": {"broken": {"extensions": [".b"]}}})
      )

      refute dir |> Config.load() |> Enum.find(&(&1.name == "broken"))
    end
  end
end
