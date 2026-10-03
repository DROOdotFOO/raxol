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
        args: [
          "-c",
          ~s(printf '%s|%s|%s' "${RAXOL_SLEUTH_API_KEY-unset}" "$FOO" "${HOME:+home}")
        ],
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
    assert child([{"RAXOL_SLEUTH_API_KEY", "given"}, {~c"FOO", ~c"bar"}]) ==
             "given|bar|home"
  end

  test "cmd_env/1 scrubs a System.cmd child the same way, nil unsetting" do
    script = ~s(printf '%s|%s|%s' "${RAXOL_SLEUTH_API_KEY-unset}" "$FOO" "${HOME:+home}")

    assert {"unset|bar|home", 0} =
             System.cmd("/bin/sh", ["-c", script], env: ChildEnv.cmd_env([{"FOO", "bar"}]))

    assert {"given||", 0} =
             System.cmd("/bin/sh", ["-c", script],
               env: ChildEnv.cmd_env([{"RAXOL_SLEUTH_API_KEY", "given"}, {"HOME", nil}])
             )
  end

  describe "configuration" do
    setup do
      previous = Application.get_env(:raxol_core, ChildEnv)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:raxol_core, ChildEnv, previous),
          else: Application.delete_env(:raxol_core, ChildEnv)
      end)
    end

    test "a passed name reaches the child, as a nested raxol node needs its key" do
      Application.put_env(:raxol_core, ChildEnv, pass: ["RAXOL_SLEUTH_API_KEY"])
      assert child([{"FOO", "bar"}]) == "sk-probe-not-real|bar|home"
    end

    test "extra secrets are unset too, and a caller's false unsets rather than sets" do
      System.put_env("RAXOL_TEST_EXTRA_SECRET", "x")
      on_exit(fn -> System.delete_env("RAXOL_TEST_EXTRA_SECRET") end)

      Application.put_env(:raxol_core, ChildEnv, extra_secrets: ["RAXOL_TEST_EXTRA_SECRET"])

      assert {~c"RAXOL_TEST_EXTRA_SECRET", false} in ChildEnv.port_env()
      assert {~c"FOO", false} in ChildEnv.port_env([{"FOO", false}])
    end

    test "a malformed config raises naming the config and the key instead of scrubbing less" do
      for {config, key} <- [
            {[pass: [nil]], ":pass"},
            {[extra_secrets: [:MY_WALLET_KEY]], ":extra_secrets"},
            {[pass: "RAXOL_SLEUTH_API_KEY"], ":pass"},
            {[extra_secrets: ["MY KEY"]], ":extra_secrets"},
            {%{pass: ["RAXOL_SLEUTH_API_KEY"]}, nil},
            {[{"pass", ["RAXOL_SLEUTH_API_KEY"]}], nil}
          ] do
        Application.put_env(:raxol_core, ChildEnv, config)

        error = assert_raise ArgumentError, fn -> ChildEnv.port_env() end
        assert error.message =~ "config :raxol_core, Raxol.Core.ChildEnv"
        if key, do: assert(error.message =~ key)
      end
    end
  end
end
