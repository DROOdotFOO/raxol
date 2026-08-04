defmodule Raxol.Harness.SurfaceParityTest do
  @moduledoc """
  The multi-surface parity matrix, run inside the normal suite so every CI
  arch exercises it (same reason `test/rate/golden_test.exs` re-runs the RATE
  corpus rather than leaving it to the mix task).

  Two independent properties:

    * **Drift** -- every fixture x surface artifact still matches a fresh
      render, and the hash refs still match the artifacts.
    * **Parity** -- the surfaces agree with each other. This is the one a
      single-surface golden cannot catch: an encoder that drops a wide
      character or mis-orders a cursor move still hashes consistently with
      itself, and only diverges when compared against a sibling surface.
  """
  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface.Parity

  @fixtures Parity.fixtures()

  describe "corpus" do
    test "every projectable fixture is covered on every surface" do
      refute @fixtures == [], "the parity corpus is empty"

      for fixture <- @fixtures, surface <- Parity.surfaces() do
        path = Parity.artifact_path(fixture, surface)

        assert File.exists?(path),
               "#{fixture} has no #{surface} artifact — run " <>
                 "`mix raxol.harness.parity.bless`"
      end
    end

    test "the refs file pins exactly the artifacts on disk" do
      pinned =
        Parity.refs_path()
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.split(~r/\s+/) |> List.first()))
        |> MapSet.new()

      expected =
        for fixture <- @fixtures,
            surface <- Parity.surfaces(),
            into: MapSet.new(),
            do: "#{fixture}.#{surface}"

      assert pinned == expected
    end
  end

  describe "drift" do
    test "no artifact or ref has drifted from a fresh render" do
      assert {:ok, results} = Parity.run(check: true)
      assert Enum.all?(results, &(&1.status == :current))
    end
  end

  describe "parity" do
    for fixture <- @fixtures do
      test "#{fixture}: every surface shows the same screen" do
        assert Parity.parity(unquote(fixture)) == :ok
      end
    end

    test "the three grid-derived surfaces are character-for-character equal" do
      for fixture <- @fixtures do
        %{cells: cells, liveview_dom: dom, ssh_ansi: ansi} =
          Parity.visible_text(fixture)

        assert cells == dom, "#{fixture}: LiveView DOM diverged from the grid"

        assert cells == ansi,
               "#{fixture}: SSH byte stream diverged from the grid"
      end
    end
  end

  describe "determinism" do
    test "rendering the same fixture twice produces identical projections" do
      # Catches unseeded randomness, clock leakage, and state leaking between
      # calls in ONE VM. The committed artifacts are the cross-machine
      # backstop for anything environment-shaped this cannot see.
      for fixture <- @fixtures, surface <- Parity.surfaces() do
        assert Parity.project(fixture, surface) ==
                 Parity.project(fixture, surface),
               "#{fixture}.#{surface} is not deterministic within one VM"
      end
    end
  end
end
