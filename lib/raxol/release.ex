defmodule Raxol.Release do
  @moduledoc """
  Release entrypoints for the `raxol` OTP release.

  `playground/0` boots the component playground TUI and blocks until the user
  quits. `golden/0` runs the RATE golden render smoke and exits non-zero on any
  mismatch, so it doubles as a per-architecture determinism check.

  Both are invoked from the release (see the `releases/0` entry in `mix.exs`),
  typically via `bin/raxol eval "Raxol.Release.playground()"`. Mix is not
  available at runtime in a release, so nothing here may call `Mix`.
  """

  @doc "Boot the playground TUI and block until the user quits."
  @spec playground() :: :ok
  def playground do
    {:ok, _} = Application.ensure_all_started(:raxol)
    {:ok, pid} = Raxol.start_link(Raxol.Playground.App, mouse: false)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  @doc """
  Run the RATE golden render, printing `name  hash` per fixture.

  Halts with exit code 0 when every fixture matches its committed reference and
  exit code 1 on any mismatch or missing reference.
  """
  @spec golden() :: no_return()
  def golden do
    # Raxol.RATE.run/0 self-starts UserPreferences and is otherwise a pure
    # render (no NIF, tty, wall clock, or randomness), so the full application
    # does not need to be started for the golden smoke.
    Enum.each(Raxol.RATE.run(), fn {name, hash} ->
      IO.puts("#{name}  #{hash}")
    end)

    case Raxol.RATE.verify() do
      {:ok, _results} ->
        System.halt(0)

      {:error, %{mismatches: mismatches, missing: missing}} ->
        Enum.each(mismatches, fn %{
                                   name: name,
                                   expected: expected,
                                   actual: actual
                                 } ->
          IO.puts(
            :stderr,
            "MISMATCH #{name}: expected #{expected} got #{actual}"
          )
        end)

        Enum.each(missing, fn name ->
          IO.puts(:stderr, "MISSING #{name}: no reference")
        end)

        System.halt(1)
    end
  end
end
