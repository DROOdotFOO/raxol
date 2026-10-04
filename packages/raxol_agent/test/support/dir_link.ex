defmodule Raxol.Agent.Test.DirLink do
  @moduledoc """
  A symlink to a directory, removed before the test's own teardown.

  Windows treats a directory symlink as a directory: `File.rm/1` refuses it,
  so `File.rm_rf!/1` of the tree that holds one raises (`:eexist`, from
  removing the now non-empty parent) after every assertion has passed.
  `ln_s!/2` registers the link's removal with `on_exit/1`; registered after
  the caller's setup, it runs before that setup's `rm_rf!`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "`File.ln_s!/2`, plus removal of `link` when the test exits."
  def ln_s!(target, link) do
    File.ln_s!(target, link)
    on_exit(fn -> remove!(link) end)
    link
  end

  # `File.rm/1` is right on Unix (and for a file link on Windows); a
  # directory link on Windows is refused with :eperm/:eacces and needs
  # `File.rmdir!/1`. An already-removed link is the goal state.
  defp remove!(link) do
    case File.rm(link) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} -> File.rmdir!(link)
    end
  end
end
