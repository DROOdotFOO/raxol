# Skill Authoring

A skill is procedural memory: a reusable `SKILL.md` file that teaches an agent how to do
something. Raxol uses the [agentskills.io](https://agentskills.io) `SKILL.md` format, so a
skill you write here sits alongside the ones under `~/.agents/skills` and is portable to
other tools that speak the same format.

Agents author skills on their own (the [self-improvement](../features/SELF_IMPROVEMENT.md)
reviewer writes them after a successful turn), and you can author them by hand. This guide
is the hand-authoring contract.

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
| `created_by` | no | `agent` or `user`. Set automatically; only agent-authored skills are curated. |

Any other frontmatter key is preserved under the skill's metadata, so fields another tool
depends on survive a round trip. Nothing from a `SKILL.md` is ever turned into an atom.

### Body

Write the body for the reader that will act on it: an LLM with tools. Be concrete and
procedural. State the trigger ("use this when..."), then the steps, then the caveats. Keep
it focused on one task; a skill that tries to cover everything gets opened for nothing.

## Where skills live

`Raxol.Agent.Skills.Store` reads from two places:

- **Managed root** (writable, default `~/.raxol/skills`): skills the agent or you author
  here. New skills are written here.
- **External dirs** (read-only, default `~/.agents/skills`): shared skills. A managed skill
  wins over an external one of the same name.

Skill content is re-read from disk on every boot, so disk is the source of truth. Usage
telemetry (how often a skill is used and viewed, its lifecycle state) is persisted
separately and survives restarts.

## Authoring from an agent

The three skills tools let an agent manage its own procedures:

| Tool | Purpose |
|------|---------|
| `skills_list` | List skills as metadata only (the cheap disclosure level). |
| `skill_view` | Read a skill's body, or one supporting file inside its directory. |
| `skill_manage` | Create, patch, or delete a skill. |

A supporting-file read through `skill_view` is path-guarded: absolute paths and `..` are
rejected, so a skill cannot read outside its own directory.

## Curation

Agent-authored skills are aged by the [Curator](../features/SELF_IMPROVEMENT.md#curator):
`active` to `stale` (default 30 idle days) to `archived` (default 90). Pin a skill to
protect it from aging, and note that user-authored and external skills are never curated.
Every Curator pass writes a backup first and is reversible.

## The safety dimension

A skill in Raxol carries more than instructions. When a skill's steps call tools, those
calls run under the same [ALLOW/ASK/DENY authorization](../features/AGENT_FRAMEWORK.md#authorization-allowaskdeny)
as any other tool call, and across whichever [surface](SURFACES.md) the agent is running
on. A skill cannot smuggle in a privileged action: writing a file or running a shell
command from inside a skill is still a sensitive tool call, still gated, still auditable in
the [conversation item-log](../features/AGENT_FRAMEWORK.md#conversation-item-log).

## See also

- [Self-Improvement](../features/SELF_IMPROVEMENT.md): how agents author and curate skills.
- [Build Your First Agent](../getting-started/BUILD_AN_AGENT.md): enabling the skills store.
- [Tool Catalog](../reference/TOOL_CATALOG.md): the built-in tools skills can drive.
