# No suppressions. The Action behaviour and CommandHook callbacks resolve via
# `plt_add_apps: [:raxol_agent]` in mix.exs (raxol_agent is a compile-time-only
# dep). If a genuine, unavoidable false positive appears, add a narrow
# {file, warning, line} entry here with a comment explaining why.
[]
