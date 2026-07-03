import Config

# Compile-time base config for the raxol_acp sidecar release. The accounting
# deployment contract is read at boot from the environment in runtime.exs; this
# file only sets defaults that must exist before boot.
#
# Accounting is off unless RAXOL_ACCOUNTING_ENABLED=true (see runtime.exs), so the
# release is inert until the operator opts in.
config :raxol_acp, accounting_enabled: false
