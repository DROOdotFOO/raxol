defmodule Raxol.System.PortCommandTest do
  use ExUnit.Case, async: true

  alias Raxol.System.PortCommand

  # These exercise the real stdin -> command -> output/exit-status path against
  # POSIX utilities. The whole point of the module is to deliver the child's
  # exit status after feeding it stdin to EOF, which a plain Port.close could
  # not do, so the assertions are on real process exit codes.
  @moduletag :unix_only

  describe "run/4" do
    test "captures stdout and returns :ok on exit 0" do
      assert {:ok, "hello world"} = PortCommand.run("cat", [], "hello world")
    end

    test "handles empty stdin without hanging" do
      assert {:ok, ""} = PortCommand.run("cat", [], "")
    end

    test "returns :error with output on a non-zero exit" do
      # grep exits 1 when nothing matches
      assert {:error, ""} = PortCommand.run("grep", ["zzz"], "no match here\n")
    end

    test "returns :ok when a filtering command matches" do
      assert {:ok, "keep me\n"} =
               PortCommand.run("grep", ["keep"], "keep me\ndrop me\n")
    end

    test "passes arguments through argv, never re-parsed by the shell" do
      # A shell metacharacter in the input must reach the command literally,
      # proving the input is a data stream and not interpolated into a command.
      payload = "$(touch /tmp/raxol_portcmd_injection_probe); rm -rf /"
      assert {:ok, output} = PortCommand.run("cat", [], payload)
      assert output == payload
      refute File.exists?("/tmp/raxol_portcmd_injection_probe")
    end

    test "returns an error tuple for a missing command" do
      assert {:error, "command not found: raxol-nonexistent-xyz"} =
               PortCommand.run("raxol-nonexistent-xyz", [], "")
    end

    test "times out and reports failure without blocking indefinitely" do
      assert {:error, "timeout waiting for command"} =
               PortCommand.run("sleep", ["30"], "", timeout: 200)
    end

    test "kills the child on timeout instead of orphaning it" do
      marker =
        Path.join(
          System.tmp_dir!(),
          "raxol_portcmd_kill_#{System.unique_integer([:positive])}"
        )

      File.rm(marker)

      assert {:error, "timeout waiting for command"} =
               PortCommand.run("sh", ["-c", "sleep 0.5 && touch #{marker}"], "",
                 timeout: 150
               )

      # A merely-detached shell (Port.close only) would still run `touch` after
      # its sleep; a real kill prevents the marker from ever appearing.
      Process.sleep(700)
      refute File.exists?(marker)
      File.rm(marker)
    end

    test "does not leak stdin temp files" do
      before = temp_buffers()
      assert {:ok, _} = PortCommand.run("cat", [], "leak check")
      assert {:error, _} = PortCommand.run("sleep", ["30"], "", timeout: 200)
      assert temp_buffers() == before
    end
  end

  defp temp_buffers do
    System.tmp_dir!()
    |> Path.join("raxol_portcmd_*")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
