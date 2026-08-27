# SSH Deployment

Serve Raxol apps over SSH. Each connection gets its own process: one app, many users.
Erlang ships `:ssh` in the standard library, so this is a wrapper rather than a server: no extra dependency, no separate daemon.

## Quick start

Any TEA app can be served over SSH. Authentication is required unless anonymous access is explicitly requested, so a fund-bearing surface is never silently anonymous:

```elixir
# Public, read-only app (a dashboard, a component catalog): anonymous is fine,
# but an anonymous surface must state every resource cap or it refuses to start,
# and it binds loopback only until the exposure is separately acknowledged.
Raxol.SSH.serve(MyApp,
  port: 2222,
  allow_anonymous: true,
  max_connections: 50,
  max_per_ip: 10,
  idle_timeout: :timer.minutes(5),
  max_session_duration: :timer.hours(1)
)

# A surface that can reach payment Actions: require a public key.
Raxol.SSH.serve(MyApp, port: 2222, authorized_keys_dir: "/etc/raxol/authorized")
```

With neither option the server refuses to start. See [Authentication](#authentication) and [Anonymous surface defaults](#anonymous-surface-defaults) below.

Connect from any machine:

```bash
ssh localhost -p 2222
```

No client-side dependencies. Any SSH client works: PuTTY, OpenSSH, even `ssh` from a phone.

## Full example

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
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} -> {model, [Directive.stop()]}
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

# Start SSH server (a public counter demo, so anonymous access is intended;
# anonymous surfaces state their caps and stay on loopback by default)
{:ok, _} =
  Raxol.SSH.serve(MySshApp,
    port: 2222,
    allow_anonymous: true,
    max_connections: 10,
    max_per_ip: 2,
    idle_timeout: :timer.minutes(5),
    max_session_duration: :timer.hours(1)
  )

# Keep alive
Process.sleep(:infinity)
```

Run it:

```bash
mix run lib/my_ssh_app.exs
```

This is a simplified version of `examples/ssh/ssh_counter.exs`.

## How it works

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

### Authentication

A surface that can reach payment Actions must not be silently anonymous, so authentication is fail-closed: pass one of two options, or the server refuses to start.

- `allow_anonymous: true` accepts any connection. Use it for a public, read-only app (a dashboard, the component playground).
- `authorized_keys_dir: "/path"` requires public-key auth. The directory holds an `authorized_keys` file listing the permitted public keys, and a connection must present a listed key.

For any surface that can move funds, use `authorized_keys_dir` and bind the connection to that identity before it reaches a payment Action. Do not rely on an in-app login screen inside an otherwise-anonymous SSH session, which would put credential handling inside your `update/2` instead of the transport.

### Anonymous surface defaults

An anonymous surface once reached the public internet on the strength of one env var, so `allow_anonymous: true` now carries three defaults of its own:

- **Loopback bind.** An anonymous server binds `127.0.0.1` unless the exposure is separately acknowledged with `anonymous_public: true` (or `RAXOL_SSH_ANONYMOUS_PUBLIC=1`). One flag cannot carry a surface from laptop demo to public internet; the dangerous combination requires stating the danger.
- **Stated resource caps.** `max_connections`, `max_per_ip`, `idle_timeout`, and `max_session_duration` are required (positive integers, timeouts in milliseconds) or the server refuses to start. Fifty concurrent anonymous shells must be a decision, not an omission.
- **A boot posture line.** Every start logs one greppable line naming the resulting exposure:

  ```
  [SSH] listening 127.0.0.1:2222 auth=none max_conn=50 per_ip=10 idle=300s session_max=3600s host_keys=ed25519(/etc/raxol/ssh_keys)
  ```

  The posture is the thing that goes wrong silently; this puts it where people already look. Every accept and close is also logged with the peer address, authenticated user, duration, and outcome, so whether the surface is worth running is answerable from the logs.

When probing an exposure from outside, remember that "I could not connect" is not "it is closed": test every address family the host actually has, not just the one in DNS.

### Port and host keys

```elixir
Raxol.SSH.serve(MyApp,
  port: 3000,
  host_keys_dir: "/etc/raxol/ssh_keys",  # default: ~/.raxol/ssh_keys
  allow_anonymous: true
)
```

Host keys are auto-generated (ed25519, mode `0600`) on first run under a persistent per-user directory (`~/.raxol/ssh_keys`), so clients do not get host-key-changed warnings on restart. Point `host_keys_dir` at a directory your service account owns to keep the key stable across deploys. The server refuses to start if any host key in the directory is group- or world-readable: a readable private host key makes every client's host-key trust forgeable.

Never bake a host key into a container image: the same key ships on every deploy and every replica, readable by anyone who can pull the image. Generate at first boot into persistent storage (a volume) instead, and if no volume exists, leave the SSH surface off rather than shipping a static key.

### Running alongside a Phoenix app

Add the SSH server to your supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyAppWeb.Endpoint,
    {Raxol.SSH.Server,
     app_module: MyTerminalApp,
     port: 2222,
     authorized_keys_dir: "/etc/raxol/authorized"}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

Now the same app runs in the browser (via LiveView) and over SSH simultaneously.

## Production Considerations

### Persistent host keys

The server generates an ed25519 key on first boot; all it needs is a persistent, owner-only directory. To pre-generate instead:

```bash
mkdir -p /etc/raxol/ssh_keys
ssh-keygen -t ed25519 -f /etc/raxol/ssh_keys/ssh_host_ed25519_key -N ""
chmod 600 /etc/raxol/ssh_keys/ssh_host_ed25519_key
```

RSA is optional (`ssh-keygen -t rsa`) for very old clients; note current OpenSSH refuses SHA-1 RSA host keys, so an RSA-only server can be unreachable from modern clients.

### Isolation from signing

Do not co-locate an SSH surface with a node that holds signing keys. The interactive REPL and any anonymous surface are capability-escape risks next to a wallet, so keep the payment node separate. On the signing node, call `Raxol.Payments.Deployment.assert_signing_isolated!/0` at boot: it refuses to start when `RAXOL_REPL_EXPOSED=true`. If the SSH box joins an Erlang cluster with the signing node, run distribution over TLS (`-proto_dist inet_tls` with per-node certs), never a shared magic cookie, and gate it with `Raxol.Payments.Deployment.assert_distribution_secure!/0`.

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

Two things this block does that are easy to miss. First, for an anonymous server it needs `anonymous_public: true` (or `RAXOL_SSH_ANONYMOUS_PUBLIC=1`) or the daemon sits on loopback and the proxied port connects to nothing. That is the point: exposing an anonymous surface is a two-step, stated decision. Second, verify the exposure from outside the app on EVERY address the app holds. Fly's shared IPv4 proxies 80/443 only, so a TCP probe against it can look closed while a dedicated IPv6 (`fly ips list`) serves the port to anyone who scans for it. "I could not connect" is not "it is closed."

### Erlang distribution and epmd

This is a BEAM default, not a Raxol one, but it ships with every deployment: `epmd` binds `0.0.0.0:4369` (and `[::]`) by default, and the distribution listener binds every interface too. A cloud provider that only routes declared services will not expose these, but any extra interface on the machine (a Tailscale/WireGuard mesh, a second NIC) is bound as well, and anything that can reach the distribution port and knows the cookie has full remote code execution on the node.

For the common case of not clustering at all, pin both to loopback:

```bash
# epmd: loopback only (set before the VM starts)
export ERL_EPMD_ADDRESS=127.0.0.1
```

```elixir
# releases: rel/vm.args.eex -- distribution listener on loopback only
-kernel inet_dist_use_interface {127,0,0,1}
```

If you do cluster, treat the distribution port like a root shell: private network only, TLS distribution (`-proto_dist inet_tls`) across anything shared, and never a guessable cookie. See [Isolation from signing](#isolation-from-signing) above for the payment-node rules.

## Use Cases

SSH beats web dashboards when you want zero client setup: no HTTPS certs, no browser, works over slow networks, instant startup. Same `init/update/view` whether local, over SSH, or in a browser.

- **Shared dashboards**: Deploy a monitoring dashboard. Anyone with SSH access can view it.
- **Remote admin tools**: Database inspection, log viewers, config editors, all in the terminal.
- **Pair programming**: Multiple users connected to the same app. Each sees independent state (or share state via PubSub).
- **IoT/embedded**: Run on a Raspberry Pi. SSH in from anywhere to check sensor readings.
- **Bastion host UIs**: Replace clunky web admin panels with fast terminal interfaces.

## Next steps

- [Architecture](../core/ARCHITECTURE.md): how the render pipeline works
- [Cookbook index](./README.md): the other recipes
