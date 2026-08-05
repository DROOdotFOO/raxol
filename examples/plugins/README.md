# Raxol Plugin Examples

Runnable starting points for the plugin behaviour. Copy one and edit it.

| File | What it shows |
|---|---|
| `basic_plugin.exs` | The floor: a manifest, `init/1`, and one command. |
| `background_task_plugin.exs` | Periodic work: a GenServer beside the plugin, timers started in `enable/1` and cancelled in `disable/1`. |
| `file_system_plugin.exs` | Watching paths and reacting to changes. |
| `plugin_test.exs` | Lifecycle, command handling, and event filtering coverage. |

## The behaviour

A plugin implements `Raxol.Core.Runtime.Plugins.Plugin`. Using `use Raxol.Plugin`
supplies a default for every callback except `init/1`:

```elixir
defmodule MyPlugin do
  use Raxol.Plugin

  def manifest do
    %{
      id: "my-plugin",
      name: "My Plugin",
      version: "1.0.0",
      author: "Your Name",
      module: __MODULE__,
      depends_on: [],
      provides: [:command_handler]
    }
  end

  @impl true
  def init(config), do: {:ok, %{config: config}}

  @impl true
  def handle_command(:hello, _args, state), do: {:ok, state, "hello"}

  @impl true
  def get_commands, do: [{:hello, :handle_command, 3}]
end
```

The full callback set is `init/1`, `terminate/2`, `enable/1`, `disable/1`,
`filter_event/2`, `handle_command/3`, and `get_commands/0`.

Two things that trip people up:

- **Plugins do not render.** There is no rendering callback. Return a result from
  `handle_command/3` and let the host app or a Component draw it, or run a
  companion Component and update it over the command channel.
- The third element of a `get_commands/0` tuple is the **arity of the handler
  function** (`handle_command/3` means `3`), not the number of arguments the
  command takes.

## Docs

- [Plugin Templates](../../docs/plugins/PLUGIN_TEMPLATES.md)
- [Plugin Development Guide](../../docs/plugins/GUIDE.md)
- [Plugin Testing](../../docs/plugins/TESTING.md)
- [Plugin SDK](../../docs/features/PLUGIN_SDK.md)
- Behaviour source: `packages/raxol_core/lib/raxol/core/runtime/plugins/plugin.ex`
