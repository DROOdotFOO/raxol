defmodule Raxol.Symphony.Evidence.RecordingTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.{Config, Evidence}
  alias Raxol.Symphony.Evidence.Recording

  defp config do
    Config.from_workflow(%{
      config: %{tracker: %{kind: "memory"}},
      prompt_template: ""
    })
  end

  setup do
    path =
      Path.join(System.tmp_dir!(), "evidence_recording_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    %{workspace: path}
  end

  test "returns [] when scan_dir does not exist", %{workspace: workspace} do
    result = Recording.collect(%Evidence{workspace: workspace}, config(), [])
    assert result.recordings == []
  end

  test "returns metadata for each .cast file", %{workspace: workspace} do
    scan_dir = Path.join(workspace, ".raxol_symphony")
    File.mkdir_p!(scan_dir)
    File.write!(Path.join(scan_dir, "run-1.cast"), "{}")
    File.write!(Path.join(scan_dir, "run-2.asciinema"), "{}")
    File.write!(Path.join(scan_dir, "ignore.txt"), "noise")

    result = Recording.collect(%Evidence{workspace: workspace}, config(), [])
    names = Enum.map(result.recordings, & &1.name)

    assert "run-1.cast" in names
    assert "run-2.asciinema" in names
    refute "ignore.txt" in names
  end

  test "tags errors[:recording] when scan_dir is a regular file", %{workspace: workspace} do
    scan_dir = Path.join(workspace, "blocking-file")
    File.write!(scan_dir, "not a dir")

    result =
      Recording.collect(%Evidence{workspace: workspace}, config(), scan_dir: scan_dir)

    assert result.errors[:recording] == :scan_dir_not_a_directory
  end

  test "no_workspace error when workspace is nil" do
    result = Recording.collect(%Evidence{workspace: nil}, config(), [])
    assert result.errors[:recording] == :no_workspace
  end

  test "extension override is respected", %{workspace: workspace} do
    scan_dir = Path.join(workspace, ".raxol_symphony")
    File.mkdir_p!(scan_dir)
    File.write!(Path.join(scan_dir, "run.replay"), "{}")

    result =
      Recording.collect(%Evidence{workspace: workspace}, config(), extensions: [".replay"])

    assert [%{name: "run.replay"}] = result.recordings
  end
end
