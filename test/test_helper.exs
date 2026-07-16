IO.puts("[TestHelper] === TEST HELPER STARTING ===")

# Capture boot start time for the boot-budget telemetry below.
boot_start_us = System.monotonic_time(:microsecond)

# Start Mox - wrapped in try/catch for safety
try do
  {:ok, _} = Application.ensure_all_started(:mox)
  IO.puts("[TestHelper] Mox started successfully")
rescue
  e ->
    IO.puts(:stderr, "[TestHelper] Warning: Could not start Mox: #{inspect(e)}")
end

# --- Global Docker Test Skip Logic ---
if System.get_env("SKIP_TERMBOX2_TESTS") == "true" do
  IO.puts(
    :stderr,
    "[CI] Skipping Docker-dependent tests (SKIP_TERMBOX2_TESTS=true)"
  )

  ExUnit.configure(exclude: [docker: true, skip_on_ci: true])
end

# --- Platform-specific Test Skip Logic ---
# Skip Unix-only tests (like NIF loading) on Windows
if :os.type() == {:win32, :nt} do
  IO.puts(
    :stderr,
    "[CI] Skipping Unix-only tests on Windows (termbox2 NIF not compiled)"
  )

  ExUnit.configure(exclude: [unix_only: true, skip_on_windows: true])
end

# --- Ring B (T0 harness-UI automated real-terminal driver) is NEVER run
# by default, on ANY platform or env-var combination -- unlike
# docker/skip_on_ci above, this isn't conditioned on SKIP_TERMBOX2_TESTS.
# `test/harness/ringb_*.exs` opens real GUI windows in iTerm2/Terminal.app/
# WezTerm/kitty via AppleScript/CLI device control; it needs a real macOS
# Aqua session and installed GUI terminals, and must not run headless/CI.
# Read-then-append (rather than a bare `ExUnit.configure(exclude: ...)`)
# so this can never accidentally clobber the docker/skip_on_ci or
# unix_only/skip_on_windows exclusions set by the branches above,
# regardless of call ordering.
ExUnit.configure(
  exclude:
    Enum.uniq((Application.get_env(:ex_unit, :exclude) || []) ++ [ring_b: true])
)

# To mark a test as Docker-dependent, use:
#   @tag :docker
#   test "..." do ... end
#
# To mark a test as Unix-only, use:
#   @tag :unix_only
#   test "..." do ... end
#
# To mark a test as Ring B (real macOS GUI terminal device control,
# never run by default), use:
#   @moduletag :ring_b
#   @moduletag :macos_gui

# Start ExUnit
IO.puts("[TestHelper] Starting ExUnit...")

# Cap concurrent async test cases on CI to half the default (schedulers * 2).
# GitHub Actions runners have 4 cores and ~7GB RAM; 8 concurrent test
# processes each holding module heap + GenServer state pushed peak memory
# over the runner's OOM threshold. 4 fits comfortably.
exunit_opts =
  if System.get_env("CI") == "true" do
    [max_failures: 10, max_cases: System.schedulers_online()]
  else
    [max_failures: 10]
  end

ExUnit.start(exunit_opts)
ExUnit.configure(formatters: [ExUnit.CLIFormatter, JUnitFormatter])

# Set test environment
IO.puts("[TestHelper] Setting test environment...")
Application.put_env(:raxol, :test_mode, true)

# Set up database BEFORE starting the application
if Application.get_env(:raxol, :database_enabled, true) do
  IO.puts("[TestHelper] Setting up database...")
  # Ensure Ecto is started
  # {:ok, _} = Application.ensure_all_started(:ecto)  # Removed to prevent auto-starting Repo
  # {:ok, _} = Application.ensure_all_started(:ecto_sql)  # Removed to prevent auto-starting Repo

  # Start the application (which includes the repo)
  IO.puts("[TestHelper] Starting application for testing...")
  {:ok, _} = Application.ensure_all_started(:raxol)

  # Don't set up sandbox mode for MockDB - it doesn't support it
  # Ecto.Adapters.SQL.Sandbox.mode(Raxol.Repo, :manual)
else
  # Start the application without database setup
  IO.puts("[TestHelper] Starting application for testing...")
  Application.ensure_all_started(:raxol)
end

# Mox is a library, not an application - no need to start it

# Note: Module redefinition warnings are expected in test environment
# as test modules are often redefined during test runs.
# These warnings can be safely ignored.

# Support files are automatically compiled by Mix due to elixirc_paths configuration
# No need to require them explicitly
IO.puts("[TestHelper] Support files loaded via elixirc_paths...")

# Set up mocks
IO.puts("[TestHelper] Setting up mocks...")
# Raxol.Test.Support.MockSetup.setup_mocks()  # Removed, handled elsewhere

# Initialize terminal for tests unless explicitly skipped
if System.get_env("RAXOL_SKIP_TERMINAL_INIT") != "true" and
     not Enum.any?(
       System.argv(),
       &String.contains?(&1, "csi_handlers_test.exs")
     ) do
  IO.puts("[TestHelper] Initializing terminal (test mode)...")

  # In test mode, we don't actually initialize the real terminal
  # Instead, we just set up the test environment
  Application.put_env(:raxol, :terminal_test_mode, true)

  # Mock the terminal initialization for tests
  # This prevents the actual termbox2_nif.tb_init() call that hangs in test environments
  :ok

  # Temporarily disable the at_exit handler to avoid the crash
  # System.at_exit(fn _exit_status ->
  #   IO.puts("[TestHelper] Shutting down terminal (test mode)...")
  #   # In test mode, we don't need to actually shutdown the terminal
  #   :ok
  # end)
else
  IO.puts("[TestHelper] Skipping terminal initialization and shutdown.")
end

# Initialize default theme for tests
IO.puts("[TestHelper] Initializing default theme...")
Raxol.UI.Theming.Theme.init()

# Make UserPreferences globally available
IO.puts("[TestHelper] Initializing UserPreferences...")

# Raxol.Core.UserPreferences is started by the supervision tree; do not start it manually here.
# Manual start_link removed to avoid race/duplication issues. See test stabilization notes.

# Reset UserPreferences to defaults after the test suite
# Temporarily disable the at_exit handler to avoid the crash
# System.at_exit(fn _exit_status ->
#   IO.puts("[TestHelper] Resetting UserPreferences to defaults...")
#   Raxol.Core.UserPreferences.reset_to_defaults_for_test!()
# end)

# Start the Accessibility Announcements Agent for global subscription storage
{:ok, _} = Raxol.Core.Accessibility.Announcements.start_link([])

# Start ProcessStore for replacing Process dictionary usage
{:ok, _} = Raxol.Core.Runtime.ProcessStore.start_link()

# Set up global test configuration
IO.puts("[TestHelper] Setting up global test configuration...")

# Configure test helpers
Application.put_env(:ex_unit, :capture_log, true)
Application.put_env(:ex_unit, :assert_receive_timeout, 1000)
Application.put_env(:ex_unit, :refute_receive_timeout, 1000)

# Configure test mode for all components
Application.put_env(:raxol, :terminal, test_mode: true)
Application.put_env(:raxol, :web, test_mode: true)
Application.put_env(:raxol, :core, test_mode: true)
Application.put_env(:raxol, :plugins, test_mode: true)

# Phoenix and plug_cowboy are intentionally NOT started here. No test in this
# suite exercises an HTTP endpoint, and Phoenix was removed from
# `extra_applications` in :test env (mix.exs phoenix_applications/0) to cut
# test boot memory. Tests that need Phoenix can start it in their own setup.
IO.puts("[TestHelper] Skipping Phoenix/plug_cowboy auto-start in test env")

# Configure Mox mocks after application is started
IO.puts("[TestHelper] Configuring Mox mocks...")

# Skip Mox configuration if Mox is not available
if Code.ensure_loaded?(Mox) do
  # Core runtime mocks
  Mox.defmock(Raxol.Core.Runtime.Plugins.FileWatcherMock,
    for: Raxol.Core.Runtime.Plugins.FileWatcherBehaviour
  )

  Mox.defmock(Raxol.Core.Runtime.Plugins.LoaderMock,
    for: Raxol.Core.Runtime.Plugins.LoaderBehaviour
  )

  Mox.defmock(Raxol.Core.Runtime.Plugins.LifecycleHelperMock,
    for: Raxol.Core.Runtime.Plugins.LifecycleHelper.Behaviour
  )

  Mox.defmock(Raxol.Core.Runtime.Plugins.PluginEventFilterMock,
    for: Raxol.Core.Runtime.Plugins.PluginEventFilter.Behaviour
  )

  Mox.defmock(Raxol.Core.Runtime.Plugins.PluginReloaderMock,
    for: Raxol.Core.Runtime.Plugins.PluginReloader.Behaviour
  )

  Mox.defmock(Raxol.Core.Runtime.Plugins.PluginCommandHandlerMock,
    for: Raxol.Core.Runtime.Plugins.PluginCommandHandler.Behaviour
  )

  # TimerManager mock removed - no behavior exists for TimerManager
  # Mox.defmock(Raxol.Core.Runtime.Plugins.TimerManagerMock,
  #   for: Raxol.Core.Runtime.Plugins.TimerManager.Behaviour
  # )

  # Rendering Engine mock removed - no behavior exists for Rendering Engine
  # Mox.defmock(Raxol.Core.Runtime.Rendering.EngineMock,
  #   for: Raxol.Core.Runtime.Rendering.Engine.Behaviour
  # )

  # System and UI mocks
  Mox.defmock(Raxol.System.DeltaUpdaterSystemAdapterMock,
    for: Raxol.System.DeltaUpdaterSystemAdapterBehaviour
  )

  Mox.defmock(SystemInteractionMock,
    for: Raxol.System.Interaction
  )

  Mox.defmock(Raxol.Terminal.Config.EnvironmentAdapterMock,
    for: Raxol.Terminal.Config.EnvironmentAdapterBehaviour
  )

  Mox.defmock(Raxol.Core.ClipboardMock,
    for: Raxol.Core.Clipboard.Behaviour
  )

  # Accessibility and UX mocks
  Mox.defmock(Raxol.Mocks.AccessibilityMock,
    for: Raxol.Core.Accessibility.Behaviour
  )

  Mox.defmock(Raxol.Mocks.FocusManagerMock,
    for: Raxol.Core.FocusManager.Behaviour
  )

  # KeyboardShortcuts mock for UX refinement tests
  Mox.defmock(Raxol.Mocks.KeyboardShortcutsMock,
    for: Raxol.Core.KeyboardShortcutsBehaviour
  )

  IO.puts("[TestHelper] Mox mocks configured successfully")
else
  IO.puts("[TestHelper] Skipping Mox mock configuration - Mox not available")
end

# Clipboard assertions are automatically loaded via elixirc_paths
IO.puts("[TestHelper] Clipboard assertions loaded via elixirc_paths...")

# Start the event registry for tests
IO.puts("[TestHelper] Starting event registry...")

case Registry.start_link(keys: :duplicate, name: :raxol_event_subscriptions) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# Start the EventManager for tests
IO.puts("[TestHelper] Starting EventManager...")

case Raxol.Core.Events.EventManager.start_link(
       name: Raxol.Core.Events.EventManager
     ) do
  {:ok, _pid} ->
    IO.puts("[TestHelper] EventManager started successfully")

  {:error, {:already_started, _pid}} ->
    IO.puts("[TestHelper] EventManager already running")

  {:error, reason} ->
    IO.puts(
      :stderr,
      "[TestHelper] Failed to start EventManager: #{inspect(reason)}"
    )
end

# Skip endpoint startup - Phoenix web interface removed
# if Process.whereis(RaxolWeb.Endpoint) do
#   IO.puts("[TestHelper] Endpoint already running")
# else
#   {:ok, _pid} = RaxolWeb.Endpoint.start_link()
#   IO.puts("[TestHelper] Endpoint started successfully")
# end
IO.puts("[TestHelper] Skipping endpoint - Phoenix web interface disabled")

# Reset global state to ensure clean slate before tests run
# This clears any accumulated state from module loading
Raxol.Test.IsolationHelper.reset_global_state()
IO.puts("[TestHelper] Global state reset for test isolation")

IO.puts("[TestHelper] Test helper setup complete!")

# Boot-budget telemetry. Captures elapsed time and resident memory after
# the test_helper finishes. Written to _build/test/boot_metrics.json for
# CI artifact upload, also printed to stderr in JSON for easy log scrape.
#
# Today this is informational. When we have a stable baseline, add a CI
# step that fails if either metric exceeds budget so memory regressions
# (the kind that triggered the runner OOMs in late April 2026) are caught
# at the moment they're introduced rather than when they cascade.
defmodule Raxol.Test.BootMetrics do
  @moduledoc false

  def emit(start_us) do
    elapsed_ms = div(System.monotonic_time(:microsecond) - start_us, 1000)
    mem_total = :erlang.memory(:total)
    mem_processes = :erlang.memory(:processes)
    mem_binary = :erlang.memory(:binary)
    mem_ets = :erlang.memory(:ets)
    proc_count = :erlang.system_info(:process_count)

    payload = %{
      kind: "raxol.test.boot_budget",
      elapsed_ms: elapsed_ms,
      memory_total_mb: div(mem_total, 1_048_576),
      memory_processes_mb: div(mem_processes, 1_048_576),
      memory_binary_mb: div(mem_binary, 1_048_576),
      memory_ets_mb: div(mem_ets, 1_048_576),
      process_count: proc_count,
      ci: System.get_env("CI") == "true",
      mix_env: to_string(Mix.env())
    }

    IO.puts(:stderr, "[TestHelper.boot_budget] #{Jason.encode!(payload)}")

    out_dir = Path.join([Mix.Project.build_path(), "test"])
    File.mkdir_p!(out_dir)

    File.write!(
      Path.join(out_dir, "boot_metrics.json"),
      Jason.encode_to_iodata!(payload)
    )
  rescue
    e ->
      IO.puts(
        :stderr,
        "[TestHelper.boot_budget] failed to emit metrics: #{inspect(e)}"
      )
  end
end

Raxol.Test.BootMetrics.emit(boot_start_us)
