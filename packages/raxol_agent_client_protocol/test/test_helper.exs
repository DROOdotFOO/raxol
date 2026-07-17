# Raise assert_receive's default timeout from ExUnit's 100ms to 1s. This suite
# drives real cross-process message passing (Connection dispatch, session/update
# fan-out, reattach subscriber forwarding), so a message that is correct but
# arrives late under a loaded CI host should NOT read as a failure. 1s is far
# below any real hang and only bites when a message is genuinely absent. Tests
# that need a different bound still pass one explicitly.
ExUnit.configure(assert_receive_timeout: 1_000)
ExUnit.start()
