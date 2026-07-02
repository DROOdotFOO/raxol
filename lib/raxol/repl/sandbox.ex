defmodule Raxol.REPL.Sandbox do
  @moduledoc """
  AST-based safety checker for REPL code evaluation.

  Scans Elixir code for potentially dangerous operations before evaluation.
  Three strictness levels:

  - `:none` -- allow everything (local terminal use)
  - `:standard` -- deny destructive system/file/network ops (default)
  - `:strict` -- whitelist-only (SSH/web use)

      iex> Sandbox.check("Enum.map([1,2], & &1 * 2)")
      :ok

      iex> match?({:error, _}, Sandbox.check(~s[System.cmd("rm", ["-rf", "/"])]))
      true
  """

  @type level :: :none | :standard | :strict

  @denied_standard [
    {System, :cmd, "system command execution"},
    {System, :shell, "shell command execution"},
    {System, :halt, "system halt"},
    {System, :stop, "system stop"},
    {Port, :open, "port execution"},
    {Port, :command, "port command"},
    {File, :rm, "file deletion"},
    {File, :rm!, "file deletion"},
    {File, :rm_rf, "recursive file deletion"},
    {File, :rm_rf!, "recursive file deletion"},
    {File, :write, "file write"},
    {File, :write!, "file write"},
    {File, :rename, "file rename"},
    {File, :rename!, "file rename"},
    {File, :chmod, "file permission change"},
    {File, :chmod!, "file permission change"},
    {File, :chown, "file ownership change"},
    {File, :chown!, "file ownership change"},
    {Code, :eval_string, "dynamic code evaluation"},
    {Code, :eval_file, "file code evaluation"},
    {Code, :eval_quoted, "dynamic code evaluation"},
    {Code, :compile_string, "dynamic code compilation"},
    {Code, :compile_file, "dynamic code compilation"},
    {:os, :cmd, "OS command execution"},
    {:erlang, :halt, "VM halt"},
    {:erlang, :open_port, "port execution"},
    {:init, :stop, "VM stop"},
    {Process, :exit, "process termination"},
    {Node, :spawn, "remote code execution"},
    {Node, :spawn_link, "remote code execution"},
    {Node, :connect, "node connection"},
    {GenServer, :call, "arbitrary GenServer interaction"},
    {GenServer, :cast, "arbitrary GenServer interaction"},
    {Kernel, :apply, "dynamic function application"},
    # Message passing / process reach: a sandboxed eval sharing a node with a
    # signing process must not be able to message or look it up. `send` (special
    # form) is handled separately; these close the qualified-call variants and
    # the erlang-atom bypasses that a module whitelist alone would still permit.
    {Kernel, :send, "message sending"},
    {Kernel, :spawn, "process spawning"},
    {Kernel, :spawn_link, "process spawning"},
    {Kernel, :spawn_monitor, "process spawning"},
    {Kernel, :exit, "process termination"},
    {Process, :send, "message sending"},
    {Process, :send_after, "delayed message sending"},
    {Process, :whereis, "process lookup"},
    {Process, :register, "process registration"},
    {:erlang, :send, "message sending"},
    {:erlang, :whereis, "process lookup"},
    {:erlang, :spawn, "process spawning"},
    {:erlang, :spawn_link, "process spawning"},
    {:erlang, :binary_to_term, "term deserialization"},
    {:erlang, :binary_to_atom, "dynamic atom creation"},
    {:erlang, :list_to_atom, "dynamic atom creation"},
    {:gen_server, :call, "arbitrary GenServer interaction"},
    {:gen_server, :cast, "arbitrary GenServer interaction"},
    {:rpc, :call, "remote procedure call"},
    {:rpc, :cast, "remote procedure call"},
    {:global, :whereis_name, "process lookup"}
  ]

  @allowed_strict_modules [
    Enum,
    Stream,
    Map,
    Keyword,
    List,
    Tuple,
    MapSet,
    String,
    Integer,
    Float,
    Atom,
    IO,
    Kernel,
    Range,
    Regex,
    Date,
    Time,
    DateTime,
    NaiveDateTime,
    Calendar,
    Access,
    Base,
    URI,
    Jason,
    Inspect
  ]

  @denied_erlang_modules [:file, :net_adm, :gen_tcp, :gen_udp, :httpc, :ssl]

  @doc """
  Checks code for safety violations at the given strictness level.

  Returns `:ok` if safe, or `{:error, [violation_message]}` if violations found.
  """
  @spec check(String.t(), level()) :: :ok | {:error, [String.t()]}
  def check(code, level \\ :standard)
  def check(_code, :none), do: :ok

  def check(code, level) do
    case Code.string_to_quoted(code) do
      {:ok, ast} ->
        violations = scan(ast, level)
        if violations == [], do: :ok, else: {:error, Enum.uniq(violations)}

      {:error, {_meta, message, _token}} ->
        {:error, ["Syntax error: #{message}"]}
    end
  end

  defp scan(ast, level) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn node, acc ->
        new_violations = check_node(node, level)
        {node, new_violations ++ acc}
      end)

    Enum.reverse(violations)
  end

  defp check_node(
         {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _args},
         :standard
       ) do
    module = Module.concat(mod_parts)
    check_denied_call(module, func)
  end

  defp check_node({{:., _, [mod, func]}, _, _args}, :standard)
       when is_atom(mod) do
    if mod in @denied_erlang_modules do
      ["#{inspect(mod)}.#{func} is not allowed (dangerous erlang module)"]
    else
      check_denied_call(mod, func)
    end
  end

  defp check_node(
         {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, _args},
         :strict
       ) do
    module = Module.concat(mod_parts)

    if module in @allowed_strict_modules do
      check_denied_call(module, func)
    else
      ["#{inspect(module)}.#{func} is not allowed (module not in whitelist)"]
    end
  end

  defp check_node({{:., _, [mod, func]}, _, _args}, :strict)
       when is_atom(mod) do
    if mod in @allowed_strict_modules do
      check_denied_call(mod, func)
    else
      ["#{inspect(mod)}.#{func} is not allowed (module not in whitelist)"]
    end
  end

  defp check_node({:apply, _, args}, _level) when is_list(args) do
    ["apply is not allowed (dynamic function application)"]
  end

  defp check_node({:send, _, args}, _level) when is_list(args) do
    ["send is not allowed (message sending to arbitrary processes)"]
  end

  defp check_node({kind, _, args}, _level)
       when kind in [:spawn, :spawn_link, :spawn_monitor] and is_list(args) do
    ["#{kind} is not allowed (process spawning)"]
  end

  defp check_node({:receive, _, _}, _level) do
    ["receive is not allowed (message interception)"]
  end

  defp check_node({kind, _, _}, _level)
       when kind in [:defmodule, :defprotocol, :defimpl] do
    ["#{kind} is not allowed (runtime module definition)"]
  end

  defp check_node(_node, _level), do: []

  defp check_denied_call(module, func) do
    case Enum.find(@denied_standard, fn {m, f, _} ->
           m == module and f == func
         end) do
      {_, _, reason} ->
        ["#{inspect(module)}.#{func} is not allowed (#{reason})"]

      nil ->
        []
    end
  end
end
