import Config

# Skills subsystem.
#
# Setting :skills_provider starts Raxol.Agent.Skills.Store (the supervisor gate
# in Raxol.Agent.Supervisor.skills_children/0), and an agent whose
# `skills_provider/0` returns it exposes the skills_list / skill_view /
# skill_manage tools.
#
#   skills_root          -- writable managed root for agent-authored skills;
#                           runtime state, left unmanaged by chezmoi.
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
