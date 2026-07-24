defmodule Raxol.Agent.Backend.CliTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Raxol.Agent.Backend.Cli

  describe "resolve/2 name resolution" do
    test "defaults to lm_studio when neither flag is given" do
      assert {:ok, :lm_studio} = Cli.resolve([], "raxol.code")
    end

    test "resolves the canonical --backend flag" do
      assert {:ok, :anthropic} = Cli.resolve([backend: "anthropic"], "raxol.code")
    end

    test "resolves the deprecated --harness alias" do
      assert {:ok, :anthropic} =
               capture_backend(fn -> Cli.resolve([harness: "anthropic"], "raxol.code") end)
    end

    test "--backend wins when both flags are given" do
      assert {:ok, :openai} =
               capture_backend(fn ->
                 Cli.resolve([backend: "openai", harness: "anthropic"], "raxol.code")
               end)
    end

    test "returns an error with the supported list for an unknown name" do
      assert {:error, message} = Cli.resolve([backend: "nonsense"], "raxol.code")
      assert message =~ ~s(unknown backend "nonsense")
      assert message =~ "mock"
    end
  end

  describe "resolve/2 stderr notices" do
    test "warns when the deprecated alias is used" do
      stderr = capture_io(:stderr, fn -> Cli.resolve([harness: "mock"], "raxol.code") end)
      assert stderr =~ "raxol.code: --harness is deprecated; use --backend"
    end

    test "warns when both flags are given" do
      stderr =
        capture_io(:stderr, fn ->
          Cli.resolve([backend: "mock", harness: "openai"], "raxol.code")
        end)

      assert stderr =~ "raxol.code: both --backend and --harness given"
    end

    test "canonical --backend emits nothing to stderr" do
      assert capture_io(:stderr, fn -> Cli.resolve([backend: "mock"], "raxol.code") end) == ""
    end

    test "prog: nil suppresses every notice (protects the raxol.p JSONL stream)" do
      # Even the deprecated-alias and both-given paths must stay silent so a
      # strict JSONL consumer of raxol.p's stderr is never handed a plain line.
      assert capture_io(:stderr, fn -> Cli.resolve([harness: "mock"], nil) end) == ""

      assert capture_io(:stderr, fn -> Cli.resolve([backend: "mock", harness: "openai"], nil) end) ==
               ""
    end
  end

  # Resolve while swallowing any deprecation notice the case under test expects.
  defp capture_backend(fun) do
    parent = self()
    capture_io(:stderr, fn -> send(parent, {:result, fun.()}) end)

    receive do
      {:result, result} -> result
    after
      0 -> flunk("resolve/2 did not return")
    end
  end
end
