defmodule Raxol.Harness.Fixture.Projector do
  @moduledoc """
  Behaviour for a fixture-session projection function, pluggable into
  `mix raxol.harness.fixtures.bless`.

  `Raxol.Harness.Fixture.Projectors.Identity` is the trivial default that
  keeps the bless task independent of `Raxol.Harness.Projection`; any
  module implementing this one callback can be swapped in via
  `--projector`.
  """

  alias Raxol.Harness.Fixture.Session

  @callback project(Session.t()) :: term()
end
