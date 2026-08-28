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

  test "refuses to install when the release checksum file is unavailable" do
    fake_bin = tmp_dir("fake-bin")
    install_dir = tmp_dir("install")
    curl = Path.join(fake_bin, "curl")

    File.write!(curl, """
    #!/usr/bin/env bash
    set -euo pipefail
    output=""
    url=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -o) output="$2"; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
      esac
    done
    if [[ "$url" == *SHA256SUMS ]]; then
      exit 22
    fi
    printf 'fake binary' > "$output"
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
    assert output =~ "refusing an unverified install"
    refute File.exists?(Path.join(install_dir, "raxol"))
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
