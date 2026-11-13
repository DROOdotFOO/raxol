defmodule Raxol.Journal.Test.MutationAnchor do
  @moduledoc """
  The anchor check of a mutation-control checklist: the line a control tells a
  reader to mutate must still exist verbatim in the source.

  For ExUnit suites: a missing anchor fails the calling test.
  """

  import ExUnit.Assertions

  @doc """
  Fail unless the file at `path` still contains `fragment`. `mutation` and
  `must_fail` are the control's own text, repeated in the failure message.
  """
  @spec assert_anchor!(Path.t(), String.t(), String.t(), String.t()) :: true
  def assert_anchor!(path, fragment, mutation, must_fail) do
    source = File.read!(path)

    assert String.contains?(source, fragment),
           """
           mutation-control anchor rotted: #{Path.relative_to_cwd(path)} no longer contains

               #{fragment}

           The guarded line moved or was renamed. Update this control:
             MUTATION: #{mutation}
             MUST FAIL: #{must_fail}
           """
  end
end
