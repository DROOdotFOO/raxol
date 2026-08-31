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
    {String, :to_atom, "dynamic atom creation"},
    {List, :to_atom, "dynamic atom creation"},
    # Atoms are never garbage collected, so the evaluation timeout and the heap
    # cap do not undo one of these -- the table stays grown after the process
    # dies. Every primitive that can mint one from runtime data belongs here.
    # `Module.concat` builds an atom from its parts; `Jason.decode` with
    # `keys: :atoms` does it in BULK from attacker-supplied JSON, and the option
    # can arrive in a variable, so the call is refused rather than inspected.
    {Module, :concat, "dynamic atom creation"},
    {Module, :safe_concat, "dynamic atom creation"},
    {Jason, :decode, "bulk dynamic atom creation (keys: :atoms)"},
    {Jason, :decode!, "bulk dynamic atom creation (keys: :atoms)"},
    {:erlang, :apply, "dynamic function application"},
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
    case resolve_alias(mod_parts) do
      # A name with no atom cannot be in `@denied_standard`, and cannot be
      # called either -- there is no such module to dispatch to.
      {:unknown, _name} -> []
      {:ok, module} -> check_denied_call(module, func)
    end
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
    case resolve_alias(mod_parts) do
      {:unknown, name} ->
        ["#{name}.#{func} is not allowed (module not in whitelist)"]

      {:ok, module} ->
        if module in @allowed_strict_modules do
          check_denied_call(module, func)
        else
          [
            "#{inspect(module)}.#{func} is not allowed (module not in whitelist)"
          ]
        end
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

  # A dot-CALL whose module is neither a literal alias nor a literal atom --
  # `m = String; m.to_atom(s)`, `mod.().f()`, `hd(mods).f()`. Neither level can
  # decide it: a whitelist cannot confirm the module is allowed and a blocklist
  # cannot confirm it is not, so every named check above is simply bypassed.
  # `apply` was already refused for exactly this reason; this is the same hole
  # reached through the dot.
  #
  # `map.field` has the SAME AST shape as a zero-arity `mod.fun`, and NOTHING in
  # the AST tells them apart. `no_parens: true` looked like it did, and does not:
  # the parser sets it on a genuine remote call written without parentheses, and
  # Elixir still dispatches that call. `m = System; m.halt` reached
  # `System.halt/0` through this clause, as did `m.get_env` and `:init.stop` --
  # at `:strict`, the level documented as safe for anonymous SSH exposure.
  #
  # Deciding it needs the RECEIVER's value, which exists only at runtime. A
  # checker that never evaluates therefore cannot allow the form safely, so both
  # sandboxed levels refuse it whole. Dot access is not lost: `u[:a]` reads a
  # map and `Map.fetch!(u, :a)` reads either (`Map` is whitelisted at `:strict`),
  # and `:none` -- the local-terminal level -- is unaffected.
  #
  # Restoring `u.a` under a sandbox means rewriting the node to a guarded call
  # that raises when the receiver is an atom, which makes `check/2` a transformer
  # rather than a checker. That is a larger change than a security fix should
  # carry; see the PR that introduced this comment.
  defp check_node({{:., _, [_mod, func]}, meta, _args}, level)
       when level in [:standard, :strict] and is_list(meta) do
    # Reached only when the earlier clauses did not match, i.e. the module is
    # neither a literal alias nor a literal atom.
    if Keyword.get(meta, :no_parens, false) do
      [
        "#{func} on a computed receiver is not allowed " <>
          "(a zero-arity remote call and map field access are indistinguishable; " <>
          "use u[:#{func}] or Map.fetch!(u, :#{func}) to read a field)"
      ]
    else
      [
        "#{func} on a computed module is not allowed " <>
          "(dynamic dispatch cannot be checked)"
      ]
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

  # `Module.concat/1` MINTS an atom, and atoms are never collected. Resolving
  # aliases with it made the CHECKER the very primitive `{Module, :concat}` is
  # on the denied list for: every alias in submitted source became permanent VM
  # memory, before evaluation and therefore whether or not the code was allowed
  # to run at all. Neither the heap cap nor the timeout undoes one, and
  # `ReplDemo` is served anonymously over SSH.
  #
  # `safe_concat/1` raises instead of minting. Every entry in
  # `@denied_standard` and `@allowed_strict_modules` names a module compiled
  # into this VM, so its atom already exists -- which makes "no such atom" a
  # complete answer for both levels rather than a case they have to guess at.
  #
  # This removes the CHECKER's contribution, not the whole leak. Measured over
  # 500 unknown aliases: the tokenizer mints 506 reading them (`Foo` becomes
  # the atom `:Foo` before any of this runs), `Module.concat/1` minted 500 more
  # on top, and `safe_concat/1` mints none. The tokenizer's half is inherent to
  # parsing Elixir at all -- `existing_atoms_only: true` would close it and
  # would also reject every new variable name, which a REPL cannot do. Bounding
  # that half is a matter of how much source a session may submit, not of this
  # function.
  #
  # The rescue is broad because `mod_parts` comes from the parser: a dynamic
  # segment puts a non-atom in the list, which `Module.concat/1` did not
  # survive either (it raised out of `check/2` instead of returning a
  # violation).
  defp resolve_alias(mod_parts) do
    {:ok, Module.safe_concat(mod_parts)}
  rescue
    _ -> {:unknown, alias_name(mod_parts)}
  end

  defp alias_name(mod_parts) do
    Enum.map_join(mod_parts, ".", fn
      part when is_atom(part) -> Atom.to_string(part)
      _dynamic -> "_"
    end)
  end

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
