# SSH Counter Example
#
# Serves a TEA app over SSH. Each connection gets its own process.
#
# What you'll learn:
#   - Raxol.SSH.serve/2 wraps :ssh.daemon and auto-generates host keys
#   - Each SSH connection spawns a separate Lifecycle process
#     (environment: :ssh) with full crash isolation
#   - The app module is an ordinary TEA app -- no SSH-specific code needed
#   - SSH channel I/O is translated to Raxol events automatically
#
# Usage:
#   mix run examples/ssh/ssh_counter.exs
#
# Then in another terminal:
#   ssh localhost -p 2222
#
# Controls:
#   =   = increment
#   -   = decrement
#   q   = quit (closes SSH session)

defmodule SSHCounterExample do
  use Raxol.Core.Runtime.Application

  @impl true
  def init(_context) do
    %{count: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "="}} ->
        {%{model | count: model.count + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "-"}} ->
        {%{model | count: model.count - 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1, align_items: :center} do
      [
        text("SSH Counter (connected via SSH!)", style: [:bold]),
        box style: %{
              padding: 1,
              border: :single,
              width: 20,
              justify_content: :center
            } do
          text("Count: #{model.count}", style: [:bold])
        end,
        text("Press '='/'-' to change, 'q' to quit")
      ]
    end
  end
end

IO.puts("Starting SSH server on port 2222...")
IO.puts("Connect with: ssh localhost -p 2222")

# Raxol.SSH.serve/2 starts an SSH daemon. For each incoming connection,
# it spawns a new Lifecycle running SSHCounterExample. The SSH channel
# data is translated to Raxol keyboard events, and rendered output is
# sent back over the channel.
#
# An anonymous surface states its resource caps or refuses to start, and
# binds loopback only (pass anonymous_public: true to expose it).
{:ok, _server} =
  Raxol.SSH.serve(SSHCounterExample,
    port: 2222,
    allow_anonymous: true,
    max_connections: 10,
    max_per_ip: 2,
    idle_timeout: :timer.minutes(5),
    max_session_duration: :timer.hours(1)
  )

# Keep the script alive
Process.sleep(:infinity)
