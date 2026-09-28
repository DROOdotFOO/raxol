# Configure ExUnit
ExUnit.start(exclude: [:slow, :integration, :docker, :skip_on_ci])

# Set test environment variables
System.put_env("MIX_ENV", "test")

# Keep `Raxol.Terminal.Integration.Renderer` off the real termbox, as the root
# test/test_helper.exs does. Unset, `Integration.init/0` calls the real
# `tb_init()`: without a controlling terminal (CI) it returns
# TB_ERR_INIT_OPEN, and from a terminal it succeeds and nothing shuts it down,
# so the run leaves that terminal raw (-icanon -echo -isig). Tests that mean
# to exercise the NIF branch set it to false themselves.
Application.put_env(:raxol, :terminal_test_mode, true)
