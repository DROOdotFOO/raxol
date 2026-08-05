# Time-Travel Debugging

Every `update/2` call gets snapshotted: the message, the model before, the model after. Step backwards and forwards through your app's history, diff any two points, restore old state into the live app. Disabled by default, zero overhead when off.

## Enabling

```elixir
Raxol.start_link(MyApp, time_travel: true)
```

That's it. The Dispatcher now records a snapshot after every `update/2`.

## Navigation

`Raxol.Debug.TimeTravel` keeps a cursor into the snapshot history:

```elixir
alias Raxol.Debug.TimeTravel

{:ok, snapshot} = TimeTravel.current()

# Walk through history
{:ok, snapshot} = TimeTravel.step_back()
{:ok, snapshot} = TimeTravel.step_forward()
{:ok, snapshot} = TimeTravel.jump_to(42)

# Push a historical model back into the live app
# (sends {:restore_model, model} to the Dispatcher)
:ok = TimeTravel.restore()

# Resume recording after restoring
:ok = TimeTravel.resume()

# Pause recording while you poke around
:ok = TimeTravel.pause()

entries = TimeTravel.list_entries()
# => [%{index: 0, message: :inc, changed: true}, ...]

count = TimeTravel.count()
:ok = TimeTravel.clear()
```

## Diffing

Pick any two snapshots and see exactly what changed between them:

```elixir
{:ok, changes} = TimeTravel.diff(10, 15)

# Each change is one of:
# {:changed, [:path, :to, :key], old_value, new_value}
# {:added, [:path, :to, :key], value}
# {:removed, [:path, :to, :key], value}
```

You can also diff arbitrary maps directly with `Snapshot.diff/2`, which does recursive comparison and tracks the key path:

```elixir
alias Raxol.Debug.Snapshot

Snapshot.diff(
  %{count: 1, items: [1, 2]},
  %{count: 2, items: [1, 2, 3]}
)
# => [
#   {:changed, [:count], 1, 2},
#   {:changed, [:items], [1, 2], [1, 2, 3]}
# ]

Snapshot.changed?(snapshot)  # did the model actually change?
Snapshot.summary(snapshot)   # "Snapshot #42: :inc (2 changes)"
```

## Export / Import

Save a debugging session to disk and load it later:

```elixir
:ok = TimeTravel.export("debug_session.bin")

{:ok, count} = TimeTravel.import_file("debug_session.bin")
# => {:ok, 150}
```

Uses Erlang's binary term format.

## Manual recording

`TimeTravel.record/4` is called by the Dispatcher automatically, but you can also record snapshots yourself:

```elixir
TimeTravel.record(message, model_before, model_after)
```

Snapshots live in a CircularBuffer. Old ones get evicted when it's full, so memory stays bounded.
