defmodule Raxol.Harness.Fixture.Projector do
  @moduledoc """
  Behaviour for a fixture-session projection function, pluggable into
  `mix raxol.harness.fixtures.bless`.

  The real journal-fold projection (roadmap unit T7, expected
  `Raxol.Harness.Projection` per 06-projection §7 open question 4) does
  not exist in code yet. `Raxol.Harness.Fixture.Projectors.Identity` is
  the trivial placeholder that keeps the bless task testable ahead of it;
  any module implementing this one callback can be swapped in via
  `--projector`.
  """

  alias Raxol.Harness.Fixture.Session

  @callback project(Session.t()) :: term()
end
