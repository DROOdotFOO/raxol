# `:integration` boots `raxol mcp` as an OS process; CI runs it in its own step
# (`ci-unified.yml`, "raxol mcp subprocess").
ExUnit.start(exclude: [:integration])
