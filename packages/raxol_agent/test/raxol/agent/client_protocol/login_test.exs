defmodule Raxol.Agent.ClientProtocol.LoginTest do
  @moduledoc """
  `raxol login` is the command an ACP client relaunches us with for Terminal
  Auth, so its contract is the exit code and what it does with a typed key --
  a client reads the former and a user pays for the latter.

  Prompt and print are injected, so nothing here reads a terminal.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.ClientProtocol.Login
  alias Raxol.Agent.ClientProtocol.StdioAgent

  defp io(lines, read \\ fn _ -> "sk-test" end) do
    [print_fn: fn msg -> send(self(), {:printed, msg}) end, read_fn: read] ++ lines
  end

  defp captured do
    receive do
      {:printed, msg} -> msg
    after
      0 -> nil
    end
  end

  test "--help exits 0 and names the command" do
    assert 0 = Login.run(["--help"], io([]))
    assert captured() =~ "raxol login"
  end

  test "an unknown option is a usage error, not a silent success" do
    assert 64 = Login.run(["--nope"], io([]))
  end

  test "an empty key is refused rather than stored" do
    assert 1 = Login.run(["anthropic"], io([], fn _ -> "" end))
    assert captured() =~ "no key entered"
  end

  describe "the advertised auth method" do
    # The registry's validator infers `terminal` from this _meta key and
    # defaults anything untyped to `agent` -- which we do not implement. The
    # marker is what keeps the claim honest.
    test "is terminal, and carries the args a client relaunches us with" do
      assert [method] = StdioAgent.auth_methods()
      assert method.id == "terminal"
      assert %{"terminal-auth" => %{"args" => ["login"]}} = method._meta
    end

    # If these drift, a client runs a subcommand that does not exist.
    test "names a subcommand the CLI actually dispatches" do
      [method] = StdioAgent.auth_methods()
      %{"terminal-auth" => %{"args" => [subcommand]}} = method._meta

      assert subcommand == "login"
    end
  end
end
