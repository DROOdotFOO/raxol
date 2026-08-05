# Plugin Templates

Starting points for common plugin shapes. Each one is a real file under
`examples/plugins/`, so it can be read, copied, and run rather than
transcribed out of a code block.

All four implement `Raxol.Core.Runtime.Plugins.Plugin` via `use Raxol.Plugin`,
which supplies defaults for every callback except `init/1`. See
[Guide](GUIDE.md) for the behaviour itself and [Testing](TESTING.md) for the
test helpers.

| Template | File | Use it for |
|---|---|---|
| Basic | [`examples/plugins/basic_plugin.exs`](../../examples/plugins/basic_plugin.exs) | A manifest, `init/1`, and one command. The floor. |
| Background task | [`examples/plugins/background_task_plugin.exs`](../../examples/plugins/background_task_plugin.exs) | Periodic work: a GenServer alongside the plugin, timers started in `enable/1` and cancelled in `disable/1`. |
| File system | [`examples/plugins/file_system_plugin.exs`](../../examples/plugins/file_system_plugin.exs) | Watching paths and reacting to changes. |
| Tests | [`examples/plugins/plugin_test.exs`](../../examples/plugins/plugin_test.exs) | Lifecycle, command handling, and event filtering coverage. |

## Plugins do not render

There is no rendering callback on the behaviour. Plugins do not draw to the
screen. Two ways to get UI out of one:

1. Return a result from `handle_command/3` and let the host app or a Component
   consume it.
2. Run a companion [Component](../cookbook/CUSTOM_COMPONENTS.md) in the app and
   update its model over the command or event channel.

## Adapting a template

Replace the placeholder module name and manifest `id`, implement your logic,
list what you `provides:`, and declare any `depends_on:` plugin IDs. The third
element of each `get_commands/0` tuple is the *arity of the handler function*
(`handle_command/3` means `3`), not the number of arguments the command takes.

Clean up in `terminate/2`, and let errors return `{:error, reason, state}`
rather than crashing the plugin manager.
