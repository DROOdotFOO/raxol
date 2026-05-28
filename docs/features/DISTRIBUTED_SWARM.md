# Distributed Swarm

Cluster BEAM nodes with automatic discovery, track their health, elect a commander, and sync shared state with CRDTs. Works with libcluster's gossip, epmd, and DNS strategies, plus a custom Tailscale strategy for zero-config encrypted mesh.

## Quick Start

```elixir
# Gossip: LAN multicast, no config needed
{:ok, _} = Raxol.Swarm.Discovery.start_link(strategy: :gossip)

# Tailscale: encrypted mesh, tag-filtered
{:ok, _} = Raxol.Swarm.Discovery.start_link(
  strategy: :tailscale,
  node_basename: "raxol",
  tag_filter: "tag:raxol"
)
```

## Discovery Strategies

`Raxol.Swarm.Discovery` wraps libcluster with preset strategies:

| Strategy     | Use Case                   | Key Options                                     |
| ------------ | -------------------------- | ----------------------------------------------- |
| `:gossip`    | LAN multicast, zero config | --                                              |
| `:epmd`      | Static node list           | `hosts: [:"app@host1", :"app@host2"]`           |
| `:dns`       | Fly.io, Kubernetes         | `query: "app.internal", node_basename: "app"`   |
| `:tailscale` | Mesh VPN, encrypted        | `node_basename: "app", tag_filter: "tag:raxol"` |

```elixir
Raxol.Swarm.Discovery.available?()  # => true if libcluster is loaded

# Or bypass presets entirely with raw topologies
Raxol.Swarm.Discovery.start_link(
  topologies: [
    my_cluster: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"app@host1"]]
    ]
  ]
)
```

### Tailscale Strategy

`Raxol.Swarm.Strategy.Tailscale` shells out to `tailscale status --json`, grabs online peers, filters by tag if configured, and builds BEAM node names from the results.

```elixir
Raxol.Swarm.Discovery.start_link(
  strategy: :tailscale,
  node_basename: "raxol",
  tag_filter: "tag:raxol",    # optional, only nodes with this tag
  use_dns_names: true,         # MagicDNS names instead of IPs
  poll_interval: 5_000         # ms between polls
)
```

## Node Monitoring

`Raxol.Swarm.NodeMonitor` watches cluster nodes via `:net_kernel.monitor_nodes/1`, pings them on a timer, and tracks RTT history.

```elixir
{:ok, _} = Raxol.Swarm.NodeMonitor.start_link(ping_interval_ms: 1_000)

{:ok, health} = Raxol.Swarm.NodeMonitor.get_health(:"app@host1")
# => %{node: :"app@host1", status: :healthy, avg_rtt_ms: 2.4, ...}

healthy = Raxol.Swarm.NodeMonitor.list_healthy()
suspect = Raxol.Swarm.NodeMonitor.list_suspect()
all = Raxol.Swarm.NodeMonitor.list_all()

# Subscribe to status changes
Raxol.Swarm.NodeMonitor.subscribe()
# Receive: {:swarm_event, {:node_up, node}}
# Receive: {:swarm_event, {:node_down, node}}
# Receive: {:swarm_event, {:status_change, node, :healthy, :suspect}}
```

A node goes `:suspect` after 5s without a ping response, `:down` after 30s. RTT history keeps the last 60 measurements.

## Topology & Election

`Raxol.Swarm.Topology` assigns roles to nodes and runs seniority-based commander election. The longest-running node wins.

```elixir
{:ok, _} = Raxol.Swarm.Topology.start_link(quorum_size: 2)

role = Raxol.Swarm.Topology.get_role()        # :commander | :wingmate | :observer | :relay
{:ok, commander} = Raxol.Swarm.Topology.get_commander()
nodes = Raxol.Swarm.Topology.list_nodes()      # [{node, role}, ...]
count = Raxol.Swarm.Topology.node_count()

# Manual override
:ok = Raxol.Swarm.Topology.promote(:"app@host2", :wingmate)
```

Topology subscribes to NodeMonitor automatically. If the commander goes down, re-election kicks in.

## CRDTs

Two pure functional CRDT types, no coordination required:

### LWW Register (Last-Writer-Wins)

```elixir
alias Raxol.Swarm.CRDT.LWWRegister

reg = LWWRegister.new("initial_value")
reg = LWWRegister.update(reg, "new_value")

# Merge from another node: highest timestamp wins
merged = LWWRegister.merge(local_reg, remote_reg)
value = LWWRegister.value(merged)
```

### OR-Set (Observed-Remove Set)

Add-wins: if one node adds and another removes concurrently, the element stays.

```elixir
alias Raxol.Swarm.CRDT.ORSet

set = ORSet.new()
set = ORSet.add(set, "item_a")
set = ORSet.add(set, "item_b")
set = ORSet.remove(set, "item_a")

ORSet.member?(set, "item_a")  # => false
ORSet.to_list(set)             # => ["item_b"]
ORSet.size(set)                # => 1

merged = ORSet.merge(local_set, remote_set)
```

## Tactical Overlay

`Raxol.Swarm.TacticalOverlay` is the shared state layer. Entities are LWW registers, waypoints are OR-sets. It syncs deltas between nodes periodically and does full anti-entropy exchanges to catch anything missed.

```elixir
{:ok, _} = Raxol.Swarm.TacticalOverlay.start_link(
  sync_interval_ms: 500,
  anti_entropy_interval_ms: 60_000
)

# Entities (LWW)
Raxol.Swarm.TacticalOverlay.update_entity(:unit_1, %{
  position: {10.0, 20.0, 0.0},
  heading: 45.0,
  status: :active
})

# Waypoints (OR-Set)
Raxol.Swarm.TacticalOverlay.add_waypoint(%{
  id: "wp_alpha",
  position: {50.0, 50.0, 0.0},
  label: "Rally Point"
})
Raxol.Swarm.TacticalOverlay.remove_waypoint("wp_alpha")

# Query
entities = Raxol.Swarm.TacticalOverlay.get_all_entities()
waypoints = Raxol.Swarm.TacticalOverlay.get_all_waypoints()

# Subscribe
Raxol.Swarm.TacticalOverlay.subscribe()
# Receive: {:overlay_event, {:entity_updated, :unit_1, data}}
# Receive: {:overlay_event, {:waypoint_added, waypoint}}
```

## CommsManager

`Raxol.Swarm.CommsManager` routes messages based on link quality. Critical messages always go through; low-priority ones get dropped when the link is bad.

```elixir
{:ok, _} = Raxol.Swarm.CommsManager.start_link()

:ok = Raxol.Swarm.CommsManager.send_msg(:"app@host2", data, :critical)
:ok = Raxol.Swarm.CommsManager.send_msg(:"app@host2", data, :normal)

quality = Raxol.Swarm.CommsManager.get_link_quality(:"app@host2")
# => :excellent | :good | :degraded | :poor | :disconnected
```

`:critical` and `:high` always send. `:normal` gets dropped on `:poor` links. `:low` gets dropped on `:degraded` or worse.

## Without libcluster

libcluster is optional. If it's not there:

- `Discovery.available?/0` returns `false`
- `Discovery.start_link/1` starts but doesn't do anything
- Everything else works in single-node mode
- You can still connect nodes manually with `:net_kernel.connect_node/1`
