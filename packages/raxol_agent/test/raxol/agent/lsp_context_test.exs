defmodule Raxol.Agent.LSPContextTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.LSPContext

  describe "format_context_from_data/3" do
    test "returns no context message when both empty" do
      result = LSPContext.format_context_from_data("file:///app/lib/foo.ex", [], [])
      assert result == "No LSP context available for /app/lib/foo.ex"
    end

    test "formats diagnostics" do
      diags = [
        %{
          uri: "file:///app/lib/foo.ex",
          range: %{start: %{line: 4, character: 0}, end: %{line: 4, character: 10}},
          severity: :error,
          message: "undefined function bar/0",
          source: "Elixir"
        },
        %{
          uri: "file:///app/lib/foo.ex",
          range: %{start: %{line: 10, character: 0}, end: %{line: 10, character: 5}},
          severity: :warning,
          message: "variable x is unused",
          source: nil
        }
      ]

      result = LSPContext.format_context_from_data("file:///app/lib/foo.ex", diags, [])

      assert result =~ "LSP context for /app/lib/foo.ex"
      assert result =~ "Diagnostics:"
      assert result =~ "ERROR L5: undefined function bar/0 [Elixir]"
      assert result =~ "WARNING L11: variable x is unused"
      refute result =~ "Symbols:"
    end

    test "formats symbols" do
      syms = [
        %{
          name: "MyModule",
          kind: :module,
          range: %{start: %{line: 0, character: 0}, end: %{line: 20, character: 3}},
          children: [
            %{
              name: "hello",
              kind: :function,
              range: %{start: %{line: 2, character: 2}, end: %{line: 4, character: 5}},
              children: []
            },
            %{
              name: "world",
              kind: :function,
              range: %{start: %{line: 6, character: 2}, end: %{line: 8, character: 5}},
              children: []
            }
          ]
        }
      ]

      result = LSPContext.format_context_from_data("file:///app/lib/foo.ex", [], syms)

      assert result =~ "LSP context for /app/lib/foo.ex"
      assert result =~ "Symbols:"
      assert result =~ "module MyModule (L1)"
      assert result =~ "function hello (L3)"
      assert result =~ "function world (L7)"
      refute result =~ "Diagnostics:"
    end

    test "formats both diagnostics and symbols" do
      diags = [
        %{
          uri: "file:///app/lib/foo.ex",
          range: %{start: %{line: 2, character: 0}, end: %{line: 2, character: 10}},
          severity: :info,
          message: "Consider using pattern matching",
          source: "credo"
        }
      ]

      syms = [
        %{
          name: "greet",
          kind: :function,
          range: %{start: %{line: 0, character: 0}, end: %{line: 5, character: 3}},
          children: []
        }
      ]

      result = LSPContext.format_context_from_data("file:///app/lib/foo.ex", diags, syms)

      assert result =~ "Diagnostics:"
      assert result =~ "Symbols:"
      assert result =~ "INFO L3: Consider using pattern matching [credo]"
      assert result =~ "function greet (L1)"
    end

    test "handles non-file URI" do
      result = LSPContext.format_context_from_data("untitled:Untitled-1", [], [])
      assert result =~ "untitled:Untitled-1"
    end

    test "formats hint severity" do
      diags = [
        %{
          uri: "file:///a.ex",
          range: %{start: %{line: 0, character: 0}, end: %{line: 0, character: 5}},
          severity: :hint,
          message: "Use alias",
          source: nil
        }
      ]

      result = LSPContext.format_context_from_data("file:///a.ex", diags, [])
      assert result =~ "HINT L1: Use alias"
    end

    test "formats deeply nested symbols" do
      syms = [
        %{
          name: "Outer",
          kind: :module,
          range: %{start: %{line: 0, character: 0}, end: %{line: 20, character: 3}},
          children: [
            %{
              name: "Inner",
              kind: :module,
              range: %{start: %{line: 2, character: 2}, end: %{line: 10, character: 5}},
              children: [
                %{
                  name: "deep_fn",
                  kind: :function,
                  range: %{start: %{line: 4, character: 4}, end: %{line: 6, character: 7}},
                  children: []
                }
              ]
            }
          ]
        }
      ]

      result = LSPContext.format_context_from_data("file:///a.ex", [], syms)
      assert result =~ "module Outer (L1)"
      assert result =~ "module Inner (L3)"
      assert result =~ "function deep_fn (L5)"
    end
  end

  describe "start_link/1" do
    test "returns error when command not found" do
      {:ok, pid} =
        LSPContext.start_link(
          command: "nonexistent_lsp_server_xyz_123",
          root_uri: "file:///tmp"
        )

      # Give it a moment to handle_continue
      Process.sleep(50)

      status = LSPContext.status(pid)
      assert status.status == :closed

      GenServer.stop(pid)
    end

    # The server is a sh script that writes what it inherited into a FIFO and
    # then idles on stdin; reading the FIFO blocks until it has written, so
    # nothing waits on a clock. The read is a `cat` port, not `File.read!/1`:
    # a server that never starts would leave a BEAM file open blocked for good,
    # while the `cat` is killed on exit. A hang is bounded by the tag timeout
    # alone. XOCHI_AUTH_TOKEN is set by no other test here and read by nothing
    # in this package, so the async run is safe.
    @tag :unix_only
    @tag :tmp_dir
    @tag timeout: 60_000
    test "the server does not inherit raxol's secrets, but does the rest", %{tmp_dir: dir} do
      previous = System.get_env("XOCHI_AUTH_TOKEN")
      System.put_env("XOCHI_AUTH_TOKEN", "probe-not-a-token")

      on_exit(fn ->
        if previous,
          do: System.put_env("XOCHI_AUTH_TOKEN", previous),
          else: System.delete_env("XOCHI_AUTH_TOKEN")
      end)

      fifo = Path.join(dir, "env")
      {_, 0} = System.cmd("mkfifo", [fifo])
      server = Path.join(dir, "server.sh")

      File.write!(server, """
      #!/bin/sh
      printf '%s|%s' "${XOCHI_AUTH_TOKEN-unset}" "${HOME:+home}" > "$1"
      exec cat >/dev/null
      """)

      File.chmod!(server, 0o755)

      {:ok, pid} = LSPContext.start_link(command: server, args: [fifo], root_uri: "file:///tmp")
      assert read_fifo(fifo) == "unset|home"
      GenServer.stop(pid)
    end
  end

  defp read_fifo(fifo) do
    reader =
      Port.open({:spawn_executable, System.find_executable("cat")}, [
        :binary,
        :exit_status,
        args: [fifo]
      ])

    # A server already blocked opening the FIFO lets `cat` copy it and exit at
    # once; its port can be closed before this runs. Its output and exit status
    # are in the mailbox by then, and there is nothing left to kill.
    case Port.info(reader, :os_pid) do
      {:os_pid, os_pid} ->
        on_exit(fn ->
          System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
        end)

      nil ->
        :ok
    end

    collect_fifo(reader, "")
  end

  defp collect_fifo(reader, acc) do
    receive do
      {^reader, {:data, data}} -> collect_fifo(reader, acc <> data)
      {^reader, {:exit_status, 0}} -> acc
    end
  end

  describe "diagnostics/2 when not ready" do
    test "returns not_ready error" do
      {:ok, pid} =
        LSPContext.start_link(
          command: "nonexistent_lsp_server_xyz_123",
          root_uri: "file:///tmp"
        )

      Process.sleep(50)

      assert {:error, {:not_ready, :closed}} =
               LSPContext.diagnostics(pid, "file:///tmp/foo.ex")

      GenServer.stop(pid)
    end
  end

  describe "symbols/2 when not ready" do
    test "returns not_ready error" do
      {:ok, pid} =
        LSPContext.start_link(
          command: "nonexistent_lsp_server_xyz_123",
          root_uri: "file:///tmp"
        )

      Process.sleep(50)

      assert {:error, {:not_ready, :closed}} =
               LSPContext.symbols(pid, "file:///tmp/foo.ex")

      GenServer.stop(pid)
    end
  end

  describe "hover/4 when not ready" do
    test "returns not_ready error" do
      {:ok, pid} =
        LSPContext.start_link(
          command: "nonexistent_lsp_server_xyz_123",
          root_uri: "file:///tmp"
        )

      Process.sleep(50)

      assert {:error, {:not_ready, :closed}} =
               LSPContext.hover(pid, "file:///tmp/foo.ex", 0, 0)

      GenServer.stop(pid)
    end
  end
end
