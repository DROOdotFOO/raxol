# `:live_web3` opens a socket to a third-party explorer. It is the only test in
# this package that exercises the whole pipeline (system trust store, real DNS,
# real TLS, a real response), and the only one that can fail because someone
# else's service is down, so it is a deliberate run rather than part of every
# save: `mix test --include live_web3`.
ExUnit.start(exclude: [:live_web3])
