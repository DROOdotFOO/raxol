defmodule Raxol.CLI.UpdateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Raxol.CLI.Update

  @asset "raxol_cli_macos"
  @binary "new raxol binary\n"
  @sha :crypto.hash(:sha256, @binary) |> Base.encode16(case: :lower)
  @target %{asset: @asset, label: "raxol-darwin-arm64", windows?: false}
  @release_url "https://api.github.com/repos/DROOdotFOO/raxol/releases?per_page=20"
  @tag_url "https://api.github.com/repos/DROOdotFOO/raxol/releases/tags/raxol-cli-v0.2.7"
  @binary_url "https://example.test/raxol_cli_macos"
  @sums_url "https://example.test/SHA256SUMS"

  test "check reports the newest CLI release without installing" do
    out =
      capture_io(fn ->
        assert Update.run(["--check"], runtime_opts(current_version: "0.2.6+abc")) == 0
      end)

    assert out =~ "Current version: 0.2.6"
    assert out =~ "New version available: 0.2.7"
    assert out =~ "Run `raxol update` to install the update"
  end

  test "update downloads, verifies, and replaces the current binary" do
    {dir, current_exe} = current_exe_fixture()

    out =
      capture_io(fn ->
        assert Update.run([], runtime_opts(current_executable: current_exe)) == 0
      end)

    assert out =~ "Current version: 0.2.6"
    assert out =~ "New version available: 0.2.7"
    assert out =~ "Downloading raxol-darwin-arm64…"
    assert out =~ "Verified sha256:#{@sha}"
    assert out =~ "Installing update..."
    assert out =~ "✔ Updated to 0.2.7"
    assert out =~ "Restart raxol to use the new version"
    assert File.read!(current_exe) == @binary
    File.rm_rf!(dir)
  end

  test "checksum mismatch leaves the installed binary untouched" do
    {dir, current_exe} = current_exe_fixture()

    stderr =
      capture_io(:stderr, fn ->
        _stdout =
          capture_io(fn ->
            assert Update.run(
                     [],
                     runtime_opts(
                       current_executable: current_exe,
                       checksum: String.duplicate("0", 64)
                     )
                   ) == 1
          end)
      end)

    assert stderr =~ "checksum mismatch"
    assert File.read!(current_exe) == "old raxol binary\n"
    File.rm_rf!(dir)
  end

  test "specific version resolves the matching release tag" do
    {dir, current_exe} = current_exe_fixture()

    out =
      capture_io(fn ->
        assert Update.run(["--version", "0.2.7"], runtime_opts(current_executable: current_exe)) ==
                 0
      end)

    assert out =~ "Updated to 0.2.7"
    assert File.read!(current_exe) == @binary
    File.rm_rf!(dir)
  end

  test "source builds fail clearly when installation needs a binary path" do
    stderr =
      capture_io(:stderr, fn ->
        _stdout = capture_io(fn -> assert Update.run([], runtime_opts()) == 1 end)
      end)

    assert stderr =~ "not running as a Burrito binary"
  end

  test "auto prompt installs the update when the user accepts" do
    {dir, current_exe} = current_exe_fixture()

    out =
      capture_io([input: "y\n"], fn ->
        assert Update.auto_prompt(auto_opts(current_executable: current_exe)) == :updated
      end)

    assert out =~ "Raxol 0.2.7 is available (current 0.2.6)."
    assert out =~ "Update now? [y/N]"
    assert out =~ "Updated to 0.2.7"
    assert File.read!(current_exe) == @binary
    File.rm_rf!(dir)
  end

  test "auto prompt skips the update when the user declines" do
    {dir, current_exe} = current_exe_fixture()

    out =
      capture_io([input: "n\n"], fn ->
        assert Update.auto_prompt(auto_opts(current_executable: current_exe)) == :ok
      end)

    assert out =~ "Raxol 0.2.7 is available"
    assert out =~ "Skipping update. Run `raxol update` later."
    assert File.read!(current_exe) == "old raxol binary\n"
    File.rm_rf!(dir)
  end

  test "auto prompt honors a fresh check cache" do
    cache_path = cache_path_fixture()

    File.mkdir_p!(Path.dirname(cache_path))
    File.write!(cache_path, Jason.encode!(%{"last_checked_at" => 1_000}))

    out =
      capture_io([input: "y\n"], fn ->
        assert Update.auto_prompt(
                 prompt?: true,
                 now_s: 1_100,
                 auto_check_path: cache_path,
                 http_get_json: fn _url -> flunk("fresh cache must not hit the network") end
               ) == :ok
      end)

    assert out == ""
    File.rm_rf!(Path.dirname(cache_path))
  end

  test "bad options are usage errors" do
    stderr = capture_io(:stderr, fn -> assert Update.run(["--wat"], runtime_opts()) == 64 end)

    assert stderr =~ "unknown options"
  end

  defp current_exe_fixture do
    dir = Path.join(System.tmp_dir!(), "raxol-update-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    current_exe = Path.join(dir, @asset)
    File.write!(current_exe, "old raxol binary\n")
    File.chmod!(current_exe, 0o755)
    {dir, current_exe}
  end

  defp cache_path_fixture do
    Path.join(
      System.tmp_dir!(),
      "raxol-update-cache-#{System.unique_integer([:positive])}/check.json"
    )
  end

  defp auto_opts(overrides) do
    overrides
    |> runtime_opts()
    |> Keyword.put(:prompt?, true)
    |> Keyword.put(:now_s, 1_000)
    |> Keyword.put(:auto_check_path, cache_path_fixture())
  end

  defp runtime_opts(overrides \\ []) do
    checksum = Keyword.get(overrides, :checksum, @sha)
    current_executable = Keyword.get(overrides, :current_executable)
    current_version = Keyword.get(overrides, :current_version, "0.2.6+abc")

    [
      current_version: current_version,
      target: @target,
      http_get_json: &get_json/1,
      http_get_text: fn @sums_url -> {:ok, "#{checksum}  #{@asset}\n"} end,
      download_file: fn @binary_url, path -> File.write(path, @binary) end
    ]
    |> maybe_put(:current_executable, current_executable)
  end

  defp get_json(@release_url), do: {:ok, [release()]}
  defp get_json(@tag_url), do: {:ok, release()}

  defp release do
    %{
      "tag_name" => "raxol-cli-v0.2.7",
      "draft" => false,
      "prerelease" => false,
      "assets" => [
        %{"name" => @asset, "browser_download_url" => @binary_url},
        %{"name" => "SHA256SUMS", "browser_download_url" => @sums_url}
      ]
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
