defmodule Raxol.Core.ChildEnvTest do
  use ExUnit.Case, async: false

  @moduletag :unix_only

  alias Raxol.Core.ChildEnv

  setup do
    previous = System.get_env("RAXOL_SLEUTH_API_KEY")
    System.put_env("RAXOL_SLEUTH_API_KEY", "sk-probe-not-real")

    on_exit(fn ->
      if previous,
        do: System.put_env("RAXOL_SLEUTH_API_KEY", previous),
        else: System.delete_env("RAXOL_SLEUTH_API_KEY")
    end)
  end

  defp child(env) do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :in,
        args: ["-c", ~s(printf '%s|%s|%s' "${RAXOL_SLEUTH_API_KEY-unset}" "$FOO" "${HOME:+home}")],
        env: ChildEnv.port_env(env)
      ])

    collect(port, "")
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, _}} -> acc
    after
      5_000 -> flunk("child did not exit")
    end
  end

  test "a child gets the node's environment and the caller's, minus raxol's secrets" do
    assert child([{"FOO", "bar"}]) == "unset|bar|home"
  end

  test "a secret the caller passes explicitly is kept" do
    assert child([{"RAXOL_SLEUTH_API_KEY", "given"}, {~c"FOO", ~c"bar"}]) == "given|bar|home"
  end
end
