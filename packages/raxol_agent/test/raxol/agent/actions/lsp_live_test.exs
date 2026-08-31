defmodule Raxol.Agent.Actions.LspLiveTest do
  @moduledoc """
  The LSP path against a real language server.

  The fixture server in `test/support/fake_lsp_server.py` proves the client
  handles the protocol as written down. This proves it handles the protocol
  as an actual server speaks it: real capability negotiation, real indexing
  latency, real diagnostic timing, and the server-to-client requests a real
  server sends during startup that a fixture never bothers with.

  Excluded by default and skipped when `rust-analyzer` is not installed:

      mix test --only live_lsp
  """

  use ExUnit.Case, async: false

  @moduletag :live_lsp
  @moduletag timeout: 180_000

  alias Raxol.Agent.Actions.Lsp
  alias Raxol.Agent.Lsp.Pool

  # Presence on PATH is not usability: `rust-analyzer` is commonly a rustup
  # or mise shim for a component that was never installed, which answers
  # every invocation with an error instead of speaking LSP. Probe it.
  setup_all do
    case System.find_executable("rust-analyzer") do
      nil ->
        raise "rust-analyzer is not on PATH. Install it (rustup component add rust-analyzer)."

      path ->
        case System.cmd(path, ["--version"], stderr_to_stdout: true) do
          {_output, 0} ->
            :ok

          {output, status} ->
            raise """
            rust-analyzer is on PATH at #{path} but is not usable (exit #{status}).
            This is usually a rustup/mise shim for a component that was never
            installed. Fix with: rustup component add rust-analyzer

            Its output was:
            #{String.trim(output)}
            """
        end
    end
  end

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol-lsp-live-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(dir, "src"))

    File.write!(Path.join(dir, "Cargo.toml"), """
    [package]
    name = "probe"
    version = "0.1.0"
    edition = "2021"
    """)

    File.write!(Path.join(dir, "src/main.rs"), """
    fn greeting() -> &'static str {
        "hello"
    }

    fn main() {
        println!("{}", greeting());
    }
    """)

    previous = System.get_env("RAXOL_CLI_CWD")
    System.put_env("RAXOL_CLI_CWD", dir)

    {:ok, pool} = Pool.start_link(root: dir)

    on_exit(fn ->
      Pool.stop(pool)

      case previous do
        nil -> System.delete_env("RAXOL_CLI_CWD")
        value -> System.put_env("RAXOL_CLI_CWD", value)
      end

      File.rm_rf!(dir)
    end)

    %{dir: dir, ctx: %{lsp_pool: pool, cwd: dir}}
  end

  test "reports the symbols rust-analyzer finds", %{ctx: ctx} do
    assert {:ok, %{symbols: symbols}} =
             Lsp.Query.run(%{op: "symbols", path: "src/main.rs"}, ctx)

    names = Enum.map(symbols, & &1.name)
    assert "greeting" in names
    assert "main" in names
  end

  test "resolves a call to its definition", %{ctx: ctx} do
    # Line 6 is the `greeting()` call; column 20 is inside the name.
    assert {:ok, %{locations: [location | _]}} =
             Lsp.Query.run(
               %{op: "definition", path: "src/main.rs", line: 6, column: 20},
               ctx
             )

    assert location.path == "src/main.rs"
    assert location.line == 1
  end

  test "renames a function everywhere it is used", %{dir: dir, ctx: ctx} do
    assert {:ok, result} =
             Lsp.Rename.run(
               %{path: "src/main.rs", line: 1, column: 4, new_name: "salutation"},
               ctx
             )

    assert result.edits >= 2

    source = File.read!(Path.join(dir, "src/main.rs"))
    assert source =~ "fn salutation()"
    assert source =~ "salutation()"
    refute source =~ "greeting"
  end
end
