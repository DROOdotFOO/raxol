# TEA Counter in LiveView
#
# Runs the same CounterExample module that works in the terminal,
# but hosted in a Phoenix LiveView via Raxol.LiveView.TEALive.
#
# This is the proof of the multi-target claim: one TEA app, three targets.
#
# == Setup ==
#
# 1. Define the shared TEA module (this file includes a minimal one):
#
#      defmodule CounterExample do
#        use Raxol.Core.Runtime.Application
#
#        def init(_ctx), do: %{count: 0}
#        def update(:inc, model), do: {%{model | count: model.count + 1}, []}
#        def update(:dec, model), do: {%{model | count: model.count - 1}, []}
#        def update(_, model), do: {model, []}
#
#        def view(model) do
#          column do
#            [text("Count: #{model.count}"), row(do: [button("+", on_click: :inc), button("-", on_click: :dec)])]
#          end
#        end
#
#        def subscribe(_), do: []
#      end
#
# 2. Add the LiveView to your router (lib/raxol_web/router.ex):
#
#      scope "/", RaxolWeb do
#        pipe_through(:browser)
#        live "/counter", CounterLive
#      end
#
# 3. Start Phoenix:
#
#      mix phx.server
#
# 4. Visit http://localhost:4000/counter
#
# The same module also runs in a terminal:
#
#      Raxol.start_link(CounterExample, [])
#
# And over SSH:
#
#      Raxol.SSH.serve(CounterExample, port: 2222)

defmodule CounterLive do
  @moduledoc """
  LiveView wrapper that hosts CounterExample via `Raxol.LiveView.TEALive`.

  All LiveView callbacks delegate to TEALive, which starts a Lifecycle
  process for the TEA app and renders its output as HTML. Browser keydown
  events are translated to `Raxol.Core.Events.Event` structs via
  `InputAdapter`, so the TEA module's `update/2` receives the same events
  it would in a terminal.

  This module is ~15 lines because TEALive does the heavy lifting.
  """

  if Code.ensure_loaded?(Phoenix.LiveView) do
    use Phoenix.LiveView

    @impl true
    def mount(params, session, socket) do
      Raxol.LiveView.TEALive.mount(params, session, socket,
        app_module: CounterExample
      )
    end

    @impl true
    defdelegate handle_event(event, params, socket), to: Raxol.LiveView.TEALive

    @impl true
    defdelegate handle_info(msg, socket), to: Raxol.LiveView.TEALive

    @impl true
    defdelegate render(assigns), to: Raxol.LiveView.TEALive

    @impl true
    defdelegate terminate(reason, socket), to: Raxol.LiveView.TEALive
  end
end
