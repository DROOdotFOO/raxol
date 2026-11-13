# Skill Authoring

A skill is procedural memory: a reusable `SKILL.md` file that teaches an agent how to do
something. Raxol uses the [agentskills.io](https://agentskills.io) `SKILL.md` format, so a
skill you write here sits alongside the ones under `~/.agents/skills` and is portable to
other tools that speak the same format.

Agents author skills through the `skill_manage` tool, and you can author them by hand.
This guide is the hand-authoring contract.

## The format

A `SKILL.md` is YAML frontmatter followed by a markdown body:

```markdown
---
name: git-bisect-a-regression
description: Find the commit that introduced a bug using git bisect.
version: "1"
category: git
---

# Git bisect a regression

Use this when a test passed at some older commit and fails now.

1. `git bisect start`
2. `git bisect bad` at the current (broken) commit.
3. `git bisect good <known-good-sha>`.
4. For each commit git checks out, run the failing test and mark
   `git bisect good` or `git bisect bad`.
5. When git prints the first bad commit, run `git bisect reset`.

Keep the working tree clean before you start; stash or commit first.
```

### Frontmatter fields

| Field | Required | Notes |
|-------|:---:|-------|
| `name` | yes | A kebab-case identifier, unique within a store. |
| `description` | no | One line. This is what an agent sees in `skills_list` before opening the skill. |
| `version` | no | A string. |
| `category` | no | Groups the skill on disk (`<root>/<category>/<name>/`). |
| `created_by` | no | `agent` or `user`. Set by the writer: `skill_manage` tags what it creates `user`. |

Any other frontmatter key is preserved under the skill's metadata, so fields another tool
depends on survive a round trip. Nothing from a `SKILL.md` is ever turned into an atom.

### Body

Write the body for the reader that will act on it: an LLM with tools. Be concrete and
procedural. State the trigger ("use this when..."), then the steps, then the caveats. Keep
it focused on one task; a skill that tries to cover everything gets opened for nothing.

## Where skills live

`Raxol.Agent.Skill` parses and renders the format. `Raxol.Agent.Skills.Store` is the warm
index over the files (a supervised GenServer), and reads from two places:

- **Managed root** (writable, default `~/.raxol/skills`): skills the agent or you author
  here. New skills are written here.
- **External dirs** (read-only, default `~/.agents/skills`): shared skills, scanned for
  `**/SKILL.md`. A managed skill wins over an external one of the same name.

Skill content is re-read from disk on every boot, so disk is the source of truth and stale
content cannot outlive its file. Usage telemetry (`use_count`, `view_count`,
`last_used_at`, `created_at`, `state`, `pinned`) is persisted to DETS and replayed on boot.

Bring the store up under supervision through app config, and return it from the agent
module's `skills_provider/0`:

```elixir
config :raxol_agent,
  skills_provider: Raxol.Agent.Skills.Store,
  skills_root: "~/.raxol/skills"
```

## Authoring from an agent

Three tools let an agent manage its own procedures:

| Tool | Input | Returns |
|------|-------|---------|
| `skills_list` | none | skill metadata only (the cheap disclosure level) |
| `skill_view` | `name`, optional `path` | the `SKILL.md` body, or one supporting file |
| `skill_manage` | `action` (`create`/`patch`/`edit`/`delete`), `name`, fields | `ok`, `name` |

A supporting-file read through `skill_view` is path-guarded: absolute paths and `..` are
rejected, so a skill cannot read outside its own directory.

## Lifecycle state

The store records a lifecycle state per skill (`active`, `stale`, `archived`) and a pin.
`Skills.Store.set_state/3`, `pin/2`, `archive/2` and `telemetry/1` are what a host uses to
age skills; nothing in Raxol ages them on its own.

## The safety dimension

A tool call made while following a skill is a tool call like any other. An action marked
`sensitive` is denied unless the context of the call carries a `:tool_authorizer` that
allows it (see the [Tool Catalog](../reference/TOOL_CATALOG.md#authorization)), on whichever
[surface](SURFACES.md) the agent is running, so a skill cannot smuggle in a privileged
action. A turn run by `Raxol.Agent.Turn` records each call in the
[conversation item-log](../features/AGENT_FRAMEWORK.md#conversation-item-log).

## See also

- [Build Your First Agent](../getting-started/BUILD_AN_AGENT.md): enabling the skills store.
- [Tool Catalog](../reference/TOOL_CATALOG.md): the built-in tools skills can drive.
