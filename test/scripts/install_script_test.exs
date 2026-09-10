defmodule Raxol.InstallScriptTest do
  use ExUnit.Case, async: true

  # The product under test is the POSIX curl|bash installer. Windows installs
  # use the npm platform package and do not provide bash on every CI image.
  @moduletag :unix_only

  @script Path.expand("../../scripts/install.sh", __DIR__)

  test "missing option values are usage errors" do
    for option <- ["--version", "--dir"] do
      {output, status} =
        System.cmd("bash", [@script, option], stderr_to_stdout: true)

      assert status == 64
      assert output =~ "#{option} requires a value"
    end
  end

  test "refuses to install when the release manifest is unavailable" do
    fake_bin = tmp_dir("fake-bin")
    install_dir = tmp_dir("install")
    curl = Path.join(fake_bin, "curl")

    File.write!(curl, """
    #!/usr/bin/env bash
    exit 22
    """)

    File.chmod!(curl, 0o755)

    path = fake_bin <> ":" <> System.fetch_env!("PATH")

    {output, status} =
      System.cmd(
        "bash",
        [@script, "--version", "9.9.9", "--dir", install_dir],
        env: [{"PATH", path}],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "release manifest unavailable"
    refute File.exists?(Path.join(install_dir, "raxol"))
  end

  test "provenance environment accepts only explicit boolean values" do
    {output, status} =
      System.cmd("bash", [@script],
        env: [{"RAXOL_VERIFY_PROVENANCE", "sometimes"}],
        stderr_to_stdout: true
      )

    assert status == 64
    assert output =~ "RAXOL_VERIFY_PROVENANCE must be 0 or 1"
  end

  defp tmp_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "raxol_install_#{label}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
