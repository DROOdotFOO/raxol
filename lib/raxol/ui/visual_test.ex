defmodule Raxol.UI.VisualTest do
  @moduledoc deprecated:
               "Scheduled for removal in Raxol 3.0; no replacement planned."
  @moduledoc """
  Visual regression testing utilities for Raxol applications.

  > #### Deprecated {: .warning}
  >
  > This module has no callers and is scheduled for removal in Raxol 3.0.

  Provides helpers for capturing screenshots, comparing renders,
  and detecting visual regressions in component output.

  ## Usage

      defmodule MyComponentVisualTest do
        use ExUnit.Case
        import Raxol.UI.VisualTest

        test "button renders correctly" do
          result = render_snapshot(MyButton, label: "Click")
          assert_snapshot(result, "button_default")
        end

        test "button hover state" do
          result = render_snapshot(MyButton, label: "Click", state: :hover)
          assert_snapshot(result, "button_hover")
        end
      end

  ## Snapshot Storage

  Snapshots are stored in `test/snapshots/` by default. The first run
  creates baseline snapshots, subsequent runs compare against them.
  """

  alias Raxol.Core.Buffer

  @default_snapshot_dir "test/snapshots"

  @doc """
  Render a component and capture it as a snapshot.

  ## Options

    - `:width` - Buffer width (default: 80)
    - `:height` - Buffer height (default: 24)
    - Additional options are passed to the component

  ## Example

      snapshot = render_snapshot(MyButton, label: "Click", width: 20, height: 3)
  """
  @spec render_snapshot(module(), keyword()) :: %{
          content: String.t(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          component: module(),
          props: keyword(),
          checksum: String.t()
        }
  def render_snapshot(component, opts \\ []) do
    width = Keyword.get(opts, :width, Raxol.Core.Defaults.terminal_width())
    height = Keyword.get(opts, :height, Raxol.Core.Defaults.terminal_height())
    props = Keyword.drop(opts, [:width, :height])

    buffer = Buffer.create_blank_buffer(width, height)

    state =
      if function_exported?(component, :init, 1) do
        component.init(props)
      else
        %{}
      end

    rendered_buffer =
      if function_exported?(component, :render, 2) do
        component.render(state, buffer)
      else
        buffer
      end

    content = Buffer.to_string(rendered_buffer)

    %{
      content: content,
      width: width,
      height: height,
      component: component,
      props: props,
      checksum: compute_checksum(content)
    }
  end

  @doc """
  Assert that a snapshot matches the stored baseline.

  On first run, creates the baseline. On subsequent runs, compares
  against the baseline and fails if different.

  ## Options

    - `:update` - Force update the baseline (default: false)
    - `:snapshot_dir` - Custom snapshot directory

  ## Example

      assert_snapshot(snapshot, "my_component_default")
  """
  @spec assert_snapshot(map(), String.t(), keyword()) :: :ok
  def assert_snapshot(snapshot, name, opts \\ []) do
    update = Keyword.get(opts, :update, false)
    snapshot_dir = Keyword.get(opts, :snapshot_dir, @default_snapshot_dir)

    snapshot_path = Path.join(snapshot_dir, "#{name}.snapshot")

    case {File.exists?(snapshot_path), update} do
      {false, _} ->
        # First run - create baseline
        write_snapshot(snapshot_path, snapshot)
        :ok

      {true, true} ->
        # Force update
        write_snapshot(snapshot_path, snapshot)
        :ok

      {true, false} ->
        # Compare against baseline
        baseline = read_snapshot(snapshot_path)
        compare_snapshots(snapshot, baseline, name)
    end
  end

  @doc """
  Compare two renders and return the differences.

  ## Example

      diff = compare_renders(old_snapshot, new_snapshot)
  """
  @spec compare_renders(map(), map()) :: map()
  def compare_renders(snapshot_a, snapshot_b) do
    lines_a = String.split(snapshot_a.content, "\n")
    lines_b = String.split(snapshot_b.content, "\n")

    max_lines = max(length(lines_a), length(lines_b))

    differences =
      0..(max_lines - 1)
      |> Enum.filter(fn i ->
        Enum.at(lines_a, i) != Enum.at(lines_b, i)
      end)
      |> Enum.map(fn i ->
        %{
          line: i,
          expected: Enum.at(lines_a, i),
          actual: Enum.at(lines_b, i)
        }
      end)

    %{
      identical: Enum.empty?(differences),
      difference_count: length(differences),
      differences: differences,
      checksum_a: snapshot_a.checksum,
      checksum_b: snapshot_b.checksum
    }
  end

  @doc """
  Generate a visual diff representation.

  Returns a string showing the differences between two snapshots.

  ## Example

      diff_text = visual_diff(old_snapshot, new_snapshot)
      IO.puts(diff_text)
  """
  @spec visual_diff(map(), map()) :: String.t()
  def visual_diff(snapshot_a, snapshot_b) do
    comparison = compare_renders(snapshot_a, snapshot_b)

    if comparison.identical do
      "Snapshots are identical"
    else
      header =
        "=== Visual Diff (#{comparison.difference_count} differences) ===\n\n"

      diff_lines =
        comparison.differences
        |> Enum.map_join("\n", fn %{
                                    line: line,
                                    expected: expected,
                                    actual: actual
                                  } ->
          """
          Line #{line}:
            Expected: #{inspect(expected)}
            Actual:   #{inspect(actual)}
          """
        end)

      header <> diff_lines
    end
  end

  @doc """
  List all snapshots in the snapshot directory.

  ## Example

      snapshots = list_snapshots()
  """
  @spec list_snapshots(keyword()) :: [String.t()]
  def list_snapshots(opts \\ []) do
    snapshot_dir = Keyword.get(opts, :snapshot_dir, @default_snapshot_dir)

    case File.ls(snapshot_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".snapshot"))
        |> Enum.map(&String.replace_suffix(&1, ".snapshot", ""))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Delete a snapshot.

  ## Example

      delete_snapshot("my_component_default")
  """
  @spec delete_snapshot(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_snapshot(name, opts \\ []) do
    snapshot_dir = Keyword.get(opts, :snapshot_dir, @default_snapshot_dir)
    snapshot_path = Path.join(snapshot_dir, "#{name}.snapshot")

    case File.rm(snapshot_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Assert that two snapshots are visually identical.

  ## Example

      assert_identical(snapshot_a, snapshot_b)
  """
  @spec assert_identical(map(), map()) :: :ok
  def assert_identical(snapshot_a, snapshot_b) do
    comparison = compare_renders(snapshot_a, snapshot_b)

    unless comparison.identical do
      diff = visual_diff(snapshot_a, snapshot_b)

      raise ExUnit.AssertionError,
        message: "Snapshots are not identical\n\n#{diff}"
    end

    :ok
  end

  @doc """
  Assert that two snapshots are different.

  ## Example

      assert_different(snapshot_a, snapshot_b)
  """
  @spec assert_different(map(), map()) :: :ok
  def assert_different(snapshot_a, snapshot_b) do
    comparison = compare_renders(snapshot_a, snapshot_b)

    if comparison.identical do
      raise ExUnit.AssertionError,
        message: "Expected snapshots to be different, but they are identical"
    end

    :ok
  end

  # Private helpers

  defp compute_checksum(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp write_snapshot(path, snapshot) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    data = %{
      content: snapshot.content,
      width: snapshot.width,
      height: snapshot.height,
      checksum: snapshot.checksum,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(path, :erlang.term_to_binary(data))
  end

  defp read_snapshot(path) do
    data =
      path
      |> File.read!()
      |> :erlang.binary_to_term()

    %{
      content: data.content,
      width: data.width,
      height: data.height,
      checksum: data.checksum
    }
  end

  defp compare_snapshots(snapshot, baseline, name) do
    if snapshot.checksum == baseline.checksum do
      :ok
    else
      diff = visual_diff(baseline, snapshot)

      raise ExUnit.AssertionError,
        message: """
        Snapshot "#{name}" does not match baseline

        #{diff}

        To update the baseline, run with:
          assert_snapshot(snapshot, "#{name}", update: true)
        """
    end
  end
end
