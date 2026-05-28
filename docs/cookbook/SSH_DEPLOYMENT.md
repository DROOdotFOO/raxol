# SSH Deployment

Serve Raxol apps over SSH. Each connection gets its own process: one app, many users.
This is one of the things that falls out naturally from running on the BEAM, where Erlang's SSH server does the heavy lifting.

## Quick Start

Any TEA app can be served over SSH with one line:

```elixir
Raxol.SSH.serve(MyApp, port: 2222)
```

Connect from any machine:

```bash
ssh localhost -p 2222
```

No client-side dependencies. Any SSH client works: PuTTY, OpenSSH, even `ssh` from a phone.

## Full Example

```elixir
# lib/my_ssh_app.exs
defmodule MySshApp do
  use Raxol.Core.Runtime.Application

  @impl true
  def init(_ctx), do: %{count: 0}

  @impl true
  def update(msg, model) do
    case msg do
      :increment -> {%{model | count: model.count + 1}, []}
      :decrement -> {%{model | count: model.count - 1}, []}
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} -> {model, [command(:quit)]}
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "="}} -> update(:increment, model)
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "-"}} -> update(:decrement, model)
      _ -> {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, align_items: :center} do
      [
        text("SSH Counter", fg: :cyan, style: [:bold]),
        text("Count: #{model.count}", style: [:bold]),
        row style: %{gap: 1} do
          [button("=", on_click: :increment), button("-", on_click: :decrement)]
        end,
        text("Press q to disconnect", fg: :magenta)
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end

# Start SSH server
{:ok, _} = Raxol.SSH.serve(MySshApp, port: 2222)

# Keep alive
Process.sleep(:infinity)
```

Run it:

```bash
mix run lib/my_ssh_app.exs
```

This is a simplified version of `examples/ssh/ssh_counter.exs`.

## How It Works

```
SSH Client  --->  :ssh.daemon (Erlang)
                    |
                    +--> CLIHandler (SSH protocol)
                           |
                           +--> Session (per-connection)
                                  |
                                  +--> Lifecycle (TEA loop)
                                         |
                                         +--> Your App
```

1. Erlang's built-in `:ssh` module handles the SSH protocol
2. The SSH CLI handler translates SSH channel events to Raxol events
3. The SSH session manager creates a per-connection Lifecycle process
4. Your app runs identically to local mode, with the same `init/update/view`

Each connection is isolated. One user's crash doesn't affect others.

## Configuration

### Port and host keys

```elixir
Raxol.SSH.serve(MyApp,
  port: 3000,
  host_keys_dir: "/etc/raxol/ssh_keys"  # default: /tmp/raxol_ssh_keys
)
```

Host keys are auto-generated on first run. For production, use a persistent directory so clients don't get host key warnings on restart.

### Running alongside a Phoenix app

Add the SSH server to your supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyAppWeb.Endpoint,
    {Raxol.SSH.Server, app_module: MyTerminalApp, port: 2222}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

Now the same app runs in the browser (via LiveView) and over SSH simultaneously.

## Production Considerations

### Persistent host keys

Generate keys once and store them:

```bash
mkdir -p /etc/raxol/ssh_keys
ssh-keygen -t rsa -f /etc/raxol/ssh_keys/ssh_host_rsa_key -N ""
ssh-keygen -t ecdsa -f /etc/raxol/ssh_keys/ssh_host_ecdsa_key -N ""
```

### Systemd service

```ini
[Unit]
Description=Raxol SSH App
After=network.target

[Service]
Type=simple
User=raxol
ExecStart=/usr/local/bin/mix run --no-halt
WorkingDirectory=/opt/my_app
Environment=MIX_ENV=prod
Restart=always

[Install]
WantedBy=multi-user.target
```

### Fly.io

Expose the SSH port in `fly.toml`:

```toml
[[services]]
  internal_port = 2222
  protocol = "tcp"

  [[services.ports]]
    port = 2222
```

Then connect:

```bash
ssh your-app.fly.dev -p 2222
```

## Use Cases

SSH beats web dashboards when you want zero client setup: no HTTPS certs, no browser, works over slow networks, instant startup. Same `init/update/view` whether local, over SSH, or in a browser.

- **Shared dashboards**: Deploy a monitoring dashboard. Anyone with SSH access can view it.
- **Remote admin tools**: Database inspection, log viewers, config editors, all in the terminal.
- **Pair programming**: Multiple users connected to the same app. Each sees independent state (or share state via PubSub).
- **IoT/embedded**: Run on a Raspberry Pi. SSH in from anywhere to check sensor readings.
- **Bastion host UIs**: Replace clunky web admin panels with fast terminal interfaces.

## Next Steps

- [Building Apps](./BUILDING_APPS.md): TEA patterns and recipes
- [Theming](./THEMING.md): Custom color schemes
- [Architecture](../core/ARCHITECTURE.md): How the render pipeline works
