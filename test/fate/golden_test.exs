defmodule Raxol.FATEGoldenTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Runs the FATE render corpus inside the normal suite so every arch CI builds
  on (x86_64-linux, aarch64-darwin) checks the golden hashes. A mismatch here is
  either a render regression or a cross-arch determinism bug.
  """

  setup do
    case Raxol.Core.UserPreferences.start_link(test_mode?: true) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "render corpus matches committed references" do
    refs = Raxol.FATE.load_refs()

    assert map_size(refs) > 0,
           "no references at priv/fate/golden.refs (run mix raxol.fate --gen)"

    case Raxol.FATE.verify() do
      {:ok, results} ->
        assert length(results) == map_size(refs)

      {:error, %{mismatches: mismatches, missing: missing}} ->
        flunk("""
        FATE golden mismatch:
          mismatches: #{inspect(mismatches, pretty: true)}
          missing:    #{inspect(missing)}
        If this is an intended render change, regenerate with: mix raxol.fate --gen
        """)
    end
  end

  test "render is deterministic across repeated runs" do
    assert Raxol.FATE.run() == Raxol.FATE.run()
  end
end
