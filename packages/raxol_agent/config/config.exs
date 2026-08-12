import Config

# Procedural-memory (skills) subsystem.
#
# Setting :skills_provider starts Raxol.Agent.Skills.Store (the supervisor gate
# in Raxol.Agent.Supervisor.skills_children/0). The surface wiring in
# raxol/agent/code/app.ex and mix/tasks/raxol.p.ex then exposes the
# skills_list / skill_view / skill_manage tools whenever this key is set.
#
#   skills_root          -- writable managed root for agent-authored skills
#                           (the curation loop writes here); runtime state, left
#                           unmanaged by chezmoi.
#   skills_external_dirs  -- read-only skill sources, scanned for **/SKILL.md:
#                              ~/.agents/skills        chezmoi external ->
#                                                      DROOdotFOO/agent-skills
#                              ~/.agents/skills-extra  chezmoi-vendored
#                                                      third-party skills
# Not enabled in :test — the suite must not depend on the machine's on-disk
# skills; tests set :skills_provider explicitly to exercise both states.
if config_env() != :test do
  config :raxol_agent,
    skills_provider: Raxol.Agent.Skills.Store,
    skills_root: "~/.raxol/skills",
    skills_external_dirs: ["~/.agents/skills", "~/.agents/skills-extra"]
end

# Auto-detecting the subscription harness asks whether a vendor CLI is
# installed and signed in, which is a property of the host, not the project:
# the suite must not resolve a provider on a machine with `claude` installed
# and none on a machine without it. Same rule as the skills root above. Tests
# that exercise the subscription path set this key explicitly.
if config_env() == :test do
  config :raxol_agent, native_probe: false
end
