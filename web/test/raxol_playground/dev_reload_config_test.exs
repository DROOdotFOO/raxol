defmodule RaxolPlayground.DevReloadConfigTest do
  # Two files have to agree for `mix phx.server` to work in dev, and nothing
  # else in this repo can notice when they stop agreeing:
  #
  #   * config/dev.exs sets `code_reloader: true` on the endpoint
  #   * mix.exs must then list `Phoenix.CodeReloader` in `:listeners`
  #
  # Phoenix 1.8 drives dev reloading through Mix's compiler-listener API, so
  # without the listener every request in dev raises out of
  # `Phoenix.CodeReloader.Server` ("a Mix listener expected by
  # Phoenix.CodeReloader is missing"). That shipped, and no suite saw it:
  # `mix test` runs in :test where the reloader is off, and Web Deploy Check
  # boots a prod release in minimal mode where it is off too. The only reporter
  # left was a human running the dev server.
  #
  # Asserted against config/dev.exs on disk rather than the loaded env, because
  # the loaded env here is :test.
  use ExUnit.Case, async: true

  @dev_config Path.expand("../../config/dev.exs", __DIR__)
  @mix_exs Path.expand("../../mix.exs", __DIR__)

  test "enabling the dev code reloader also registers its Mix listener" do
    endpoint_config =
      @dev_config
      |> Config.Reader.read!(env: :dev)
      |> get_in([:raxol_playground, RaxolPlaygroundWeb.Endpoint])

    if endpoint_config[:code_reloader] do
      listeners = Mix.Project.config()[:listeners] || []

      assert Phoenix.CodeReloader in listeners, """
      config/dev.exs enables :code_reloader, so #{@mix_exs} must carry

          listeners: [Phoenix.CodeReloader]

      in project/0. Without it `mix phx.server` raises on every dev request.
      Got listeners: #{inspect(listeners)}
      """
    end
  end
end
