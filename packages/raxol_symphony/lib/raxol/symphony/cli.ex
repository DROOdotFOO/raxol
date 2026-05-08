defmodule Raxol.Symphony.CLI do
  @moduledoc """
  Headless launcher for the Symphony orchestrator.

  Owns the bootstrap sequence used by `mix raxol.symphony`:

  1. Resolve and validate the `WORKFLOW.md` path.
  2. Start `Raxol.Symphony.Supervisor` with that path (so the WorkflowStore
     watches the file and the Orchestrator pulls config per tick).
  3. Optionally launch the terminal dashboard via
     `Raxol.Core.Runtime.Lifecycle.start_link/2` (only when the optional
     `:raxol` dep is present).

  The launcher is split out from the Mix task so the orchestrator-only path
  can be exercised without spinning up a TUI.
  """

  alias Raxol.Symphony.{Config, Supervisor}

  @type opts :: [
          workflow: Path.t(),
          headless: boolean(),
          watch: boolean(),
          surface_module: module() | nil,
          auto_start_tick: boolean()
        ]

  @type result ::
          {:ok, %{supervisor: pid(), surface: pid() | nil}}
          | {:error, term()}

  @doc """
  Boots the orchestrator from a workflow file.

  ## Options

  - `:workflow` -- path to `WORKFLOW.md`. Defaults to `./WORKFLOW.md`.
  - `:headless` (boolean) -- skip the TUI. Defaults to `false`.
  - `:watch` (boolean) -- enable WorkflowStore file watching. Defaults to
    `true`.
  - `:surface_module` (module) -- override the default
    `Raxol.Symphony.Surfaces.Terminal`. Useful in tests.
  """
  @spec start(opts()) :: result()
  def start(opts) do
    workflow = Keyword.get(opts, :workflow, "./WORKFLOW.md")
    headless? = Keyword.get(opts, :headless, false)
    watch? = Keyword.get(opts, :watch, true)
    surface_module = Keyword.get(opts, :surface_module, default_surface())

    with {:ok, expanded_path} <- expand_path(workflow),
         {:ok, _config} <- Config.load_and_validate(expanded_path),
         {:ok, sup} <- start_supervisor(expanded_path, watch?, opts) do
      surface =
        if headless? do
          nil
        else
          start_surface(surface_module)
        end

      {:ok, %{supervisor: sup, surface: surface}}
    end
  end

  @doc """
  Starts and blocks until the surface (or supervisor in `--headless`)
  exits. Used by the Mix task entrypoint.
  """
  @spec run(opts()) :: :ok | {:error, term()}
  def run(opts) do
    case start(opts) do
      {:ok, %{surface: nil, supervisor: sup}} ->
        wait_for(sup)

      {:ok, %{surface: surface}} ->
        wait_for(surface)

      {:error, _} = err ->
        err
    end
  end

  # -- Internals --------------------------------------------------------------

  defp expand_path(path) do
    full = Path.expand(path)

    if File.exists?(full) do
      {:ok, full}
    else
      {:error, {:workflow_not_found, full}}
    end
  end

  defp start_supervisor(path, watch?, opts) do
    sup_opts =
      [workflow_path: path, watch?: watch?]
      |> Keyword.merge(Keyword.take(opts, [:auto_start_tick, :runner_module, :tracker_module]))

    case Supervisor.start_link(sup_opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      err -> err
    end
  end

  defp default_surface, do: Raxol.Symphony.Surfaces.Terminal

  defp start_surface(module) do
    if Code.ensure_loaded?(Raxol) and function_exported?(Raxol, :start_link, 2) do
      case Raxol.start_link(module, []) do
        {:ok, pid} -> pid
        _ -> nil
      end
    else
      nil
    end
  end

  defp wait_for(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp wait_for(_), do: :ok
end
