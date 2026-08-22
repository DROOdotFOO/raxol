# Every test in this suite boots a Console runtime: a supervision tree with a
# scheduler, a reconciler, a gateway (pairing + session supervisor + router) and
# sometimes a per-chat TEA app. A "chat turn" assertion is therefore waiting on
# a supervised agent turn, not on a message send, and ExUnit's 100ms default is
# the wrong order of magnitude for it -- tight enough that merely adding test
# cases to the suite made unrelated ones flake.
ExUnit.start(assert_receive_timeout: 2_000)
