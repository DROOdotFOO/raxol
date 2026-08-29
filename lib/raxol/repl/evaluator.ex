defmodule Raxol.REPL.Evaluator do
  @moduledoc """
  Elixir code evaluator with timeout protection, IO capture, and persistent bindings.

  Each evaluator maintains its own binding context across evaluations, so variables
  defined in one eval call are available in the next.

      evaluator = Evaluator.new()
      {:ok, result, evaluator} = Evaluator.eval(evaluator, "x = 1 + 2")
      {:ok, result, evaluator} = Evaluator.eval(evaluator, "x * 10")
      result.value  #=> 30
  """

  @default_timeout Raxol.Core.Defaults.timeout_ms()
  @default_max_history Raxol.Core.Defaults.history_limit()
  @default_max_heap_bytes 64 * 1024 * 1024
  @default_max_result_bytes 1024 * 1024

  @type t :: %__MODULE__{
          bindings: keyword(),
          history: [{String.t(), result()}],
          env: Macro.Env.t(),
          prelude: String.t()
        }

  @type result :: %{
          value: term(),
          output: String.t(),
          formatted: String.t()
        }

  defstruct bindings: [],
            history: [],
            env: nil,
            prelude: ""

  @doc "Creates a new evaluator with an empty binding context."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, fn -> base_env() end)
    %__MODULE__{bindings: [], history: [], env: env, prelude: ""}
  end

  @doc """
  Enable VFS helpers for this evaluator.

  Seeds a `vfs` binding with a fresh virtual filesystem and auto-imports
  `Raxol.REPL.VfsHelpers` so shell-like commands are available directly:

      evaluator = Evaluator.new() |> Evaluator.with_vfs()
      {:ok, _, evaluator} = Evaluator.eval(evaluator, "vfs = mkdir(vfs, \\"/docs\\")")
      {:ok, _, evaluator} = Evaluator.eval(evaluator, "vfs = ls(vfs)")
  """
  @spec with_vfs(t()) :: t()
  def with_vfs(evaluator) do
    %{
      evaluator
      | bindings:
          Keyword.put(evaluator.bindings, :vfs, Raxol.Commands.FileSystem.new()),
        prelude:
          append_prelude(evaluator.prelude, "import Raxol.REPL.VfsHelpers")
    }
  end

  @doc """
  Evaluates code in the evaluator's binding context.

  Returns `{:ok, result, new_evaluator}` on success or `{:error, reason, evaluator}` on failure.
  Bindings persist across calls. IO output is captured separately from the return value.
  """
  @spec eval(t(), String.t(), keyword()) ::
          {:ok, result(), t()} | {:error, String.t(), t()}
  def eval(evaluator, code, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_heap_bytes = Keyword.get(opts, :max_heap_bytes, @default_max_heap_bytes)

    max_result_bytes =
      Keyword.get(opts, :max_result_bytes, @default_max_result_bytes)

    parent = self()
    full_code = apply_prelude(evaluator.prelude, code)
    word_size = :erlang.system_info(:wordsize)
    heap_words = div(max_heap_bytes + word_size - 1, word_size)

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result =
            eval_with_capture(full_code, evaluator.bindings, evaluator.env)

          send(parent, {:eval_result, bound_result(result, max_result_bytes)})
        end,
        [
          :monitor,
          {:max_heap_size, %{size: heap_words, kill: true, error_logger: false}}
        ]
      )

    handle_eval_response(evaluator, code, pid, ref, timeout, max_heap_bytes)
  end

  defp bound_result(
         {:ok, value, new_bindings, output} = result,
         max_result_bytes
       ) do
    result_bytes =
      :erlang.external_size(value) + :erlang.external_size(new_bindings) +
        byte_size(output)

    if result_bytes <= max_result_bytes do
      result
    else
      {:error,
       "Evaluation result exceeded the #{max_result_bytes}-byte result limit"}
    end
  end

  defp bound_result(result, _max_result_bytes), do: result

  defp handle_eval_response(evaluator, code, pid, ref, timeout, max_heap_bytes) do
    receive do
      {:eval_result, {:ok, value, new_bindings, output}} ->
        Process.demonitor(ref, [:flush])
        build_success(evaluator, code, value, new_bindings, output)

      {:eval_result, {:error, message}} ->
        Process.demonitor(ref, [:flush])
        {:error, message, evaluator}

      {:DOWN, ^ref, :process, ^pid, :killed} ->
        {:error, "Evaluation exceeded the #{max_heap_bytes}-byte memory limit",
         evaluator}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, "Process crashed: #{Exception.format_exit(reason)}", evaluator}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :brutal_kill)
        {:error, "Evaluation timed out after #{timeout}ms", evaluator}
    end
  end

  defp build_success(evaluator, code, value, new_bindings, output) do
    formatted =
      inspect(value,
        pretty: true,
        width: Raxol.Core.Defaults.terminal_width(),
        limit: 50
      )

    result = %{value: value, output: output, formatted: formatted}

    history =
      Enum.take([{code, result} | evaluator.history], @default_max_history)

    {:ok, result, %{evaluator | bindings: new_bindings, history: history}}
  end

  @doc "Returns the list of current variable bindings as `[{name, value}]`."
  @spec bindings(t()) :: keyword()
  def bindings(%__MODULE__{bindings: b}), do: b

  @doc "Returns evaluation history as `[{code, result}]`, newest first."
  @spec history(t()) :: [{String.t(), result()}]
  def history(%__MODULE__{history: h}), do: h

  @doc "Resets all bindings, keeping history."
  @spec reset_bindings(t()) :: t()
  def reset_bindings(evaluator), do: %{evaluator | bindings: []}

  @doc "Clears evaluation history, keeping bindings."
  @spec clear_history(t()) :: t()
  def clear_history(evaluator), do: %{evaluator | history: []}

  # -- Private --

  @spec eval_with_capture(String.t(), keyword(), Macro.Env.t() | nil) ::
          {:ok, term(), keyword(), String.t()} | {:error, String.t()}
  defp eval_with_capture(code, bindings, env) do
    {output, result} = capture_io(fn -> do_eval(code, bindings, env) end)

    case result do
      {:ok, value, new_bindings} -> {:ok, value, new_bindings, output}
      {:error, _} = err -> err
    end
  end

  @spec do_eval(String.t(), keyword(), Macro.Env.t() | nil) ::
          {:ok, term(), keyword()} | {:error, String.t()}
  defp do_eval(code, bindings, env) do
    {value, new_bindings} =
      Code.eval_string(code, bindings, env || base_env())

    {:ok, value, new_bindings}
  catch
    kind, reason ->
      {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp capture_io(fun) do
    {:ok, string_io} = StringIO.open("")
    original_gl = Process.group_leader()
    Process.group_leader(self(), string_io)

    try do
      result = fun.()
      {_, captured} = StringIO.contents(string_io)
      {captured, result}
    after
      Process.group_leader(self(), original_gl)
      StringIO.close(string_io)
    end
  end

  @spec base_env() :: Macro.Env.t()
  defp base_env do
    %{__ENV__ | file: "iex", line: 1}
  end

  @spec apply_prelude(String.t(), String.t()) :: String.t()
  defp apply_prelude("", code), do: code
  defp apply_prelude(prelude, code), do: prelude <> "\n" <> code

  @spec append_prelude(String.t(), String.t()) :: String.t()
  defp append_prelude("", new), do: new
  defp append_prelude(existing, new), do: existing <> "\n" <> new
end
