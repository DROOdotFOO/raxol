defmodule Raxol.REPL.Sandbox do
  @moduledoc """
  AST-based safety checker for REPL code evaluation.

  ## Not a security boundary

  This is a MITIGATION. It raises the cost of the obvious attempts; it does not
  confine anything. A gap in it reaches the OS user the BEAM node runs as, with
  that node's full authority: its file handles, its network, its signing keys if
  it has any. Read the trust-boundary section of `Raxol.REPL.Evaluator` before
  putting this in front of input you do not trust.

  Why it cannot be a boundary: every clause decides safety from a module NAME,
  resolved statically from the submitted AST. Anything that changes which module
  a name reaches at runtime sits underneath the check rather than inside it,
  which is why `import`, `alias`, `require` and `use` are refused outright
  rather than resolved (#1045). Each such form found so far has been a
  CVE-class hole on an anonymous surface, and the checker's own history is the
  argument against trusting it: computed receivers, `Module.concat/1`
  alias resolution, the bare-name capture forms of `apply` and `spawn`, and
  maps forged with a `__struct__` key were each `:ok` at `:strict` until they
  were not.

  A forged struct is the same hole reached through data rather than a name. A
  map whose `__struct__` key names a module is protocol-dispatched
  (`Collectable`, `Enumerable`, `String.Chars`, `Inspect`, `Access`) to that
  module's implementations, so collecting into
  `%{__struct__: File.Stream, ...}` writes a file without `File` ever
  appearing in a call. `:strict` refuses every form it knows can set that key
  where a map is built: a `:__struct__` or computed map key, a struct literal
  outside a short allowlist, and the calls that write keys or values from
  runtime data (`Map.put/3` with a computed key, `Map.new/1` or `Enum.into/2`
  into a map from a computed input, `put_in/3` with a computed path, ...).
  That closes what the source shows, not what runtime data can hide: a form
  this list does not name reaches the same implementations, and only the
  OS-isolated peer node of #1231 closes the class.

  What actually keeps an untrusted caller away from the evaluator is the
  deployment flag, `Raxol.Core.Boundary.Evaluation.exposed?/0`. A node with that
  flag set is a node you have decided may run submitted code.

  ## Levels

  - `:none` -- allow everything (explicit trusted-local launcher opt-in)
  - `:standard` -- deny destructive and process-creation operations (`check/1` default)
  - `:strict` -- whitelist-only (the level every served launch gets)

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
    {Node, :connect, "node connection"},
    {Kernel, :apply, "dynamic function application"},
    # Message passing / process reach: a sandboxed eval sharing a node with a
    # signing process must not be able to message or look it up. `send` (special
    # form) is handled separately; these close the qualified-call variants and
    # the erlang-atom bypasses that a module whitelist alone would still permit.
    {Kernel, :send, "message sending"},
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
    {:erlang, :send_after, "delayed message sending"},
    {:erlang, :start_timer, "delayed message sending"},
    {:erlang, :whereis, "process lookup"},
    {:erlang, :binary_to_term, "term deserialization"},
    {:erlang, :binary_to_atom, "dynamic atom creation"},
    {:erlang, :list_to_atom, "dynamic atom creation"},
    {:rpc, :call, "remote procedure call"},
    {:rpc, :cast, "remote procedure call"},
    {:global, :whereis_name, "process lookup"}
  ]

  # Every module here is part of the forged-struct guarantee (see the
  # `%{}` clause of `check_node/2`): none may build a map whose `__struct__`
  # key holds an atom chosen at runtime. Before adding a module, audit every
  # function it exports for maps built from runtime keys and values, and add
  # any such function to the forge rules.
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

  # These APIs create, supervise, or schedule processes. Deny the whole API
  # rather than chasing individual arities and newly added `start*`/`async*`
  # variants: an evaluation has no child tree that can be cleaned up when its
  # own timeout kills it.
  @denied_process_modules %{
    Task => "process spawning and task supervision",
    Task.Supervisor => "process spawning and task supervision",
    Agent => "process spawning and process interaction",
    GenServer => "process spawning and process interaction",
    Supervisor => "process spawning and supervision",
    DynamicSupervisor => "process spawning and supervision",
    PartitionSupervisor => "process spawning and supervision",
    Registry => "process spawning and process registration",
    :proc_lib => "process spawning",
    :gen => "process spawning and process interaction",
    :gen_server => "process spawning and process interaction",
    :gen_event => "process spawning and process interaction",
    :gen_statem => "process spawning and process interaction",
    :supervisor => "process spawning and supervision",
    :supervisor_bridge => "process spawning and supervision",
    :timer => "delayed process scheduling"
  }

  @denied_erlang_modules [:file, :net_adm, :gen_tcp, :gen_udp, :httpc, :ssl]

  # Builtins that size their WHOLE result before a garbage collection can
  # check the evaluation's `:max_heap_size`, so that cap only fires after the
  # allocation has landed -- and an allocation the allocator cannot satisfy
  # aborts the node, not the evaluation. Measured under ReplDemo's 8 MB cap,
  # each one `:ok` here before these rules existed:
  #
  #   * `String.duplicate/2`, `String.pad_leading/2,3` with a count of 10^15:
  #     VM abort, `binary_alloc: Cannot allocate`
  #   * `IO.iodata_to_binary/1`, `Enum.join/1,2`, `Enum.map_join/2,3`,
  #     `Jason.encode!/1` over 500 references to one 2 MB binary: ~1.1 GB;
  #     `Enum.into(l, "")` and `for x <- l, into: ""` over 300: ~700 MB
  #   * `String.replace/3` with a held 1 MB replacement and 100 matches:
  #     192 MB, as much as `Enum.join` over the same list
  #   * `Tuple.duplicate/2` at the 16M maximum arity: ~230 MB
  #   * `List.to_string/1` and `IO.chardata_to_string/1` reserve the result's
  #     worst-case UTF-8 size (8x the bytes) in one block: 258 MB for 32 MB
  #   * `Calendar.strftime/2` with `%Z`, which copies the input's
  #     `:zone_abbr` once per directive and flattens the lot
  #
  # NOT covered, because the checker cannot see the argument's type:
  # `"#{list}"` and `to_string(list)` reach `List.to_string/1` through
  # `String.Chars`, `IO.write(list)`/`IO.puts(list)` run the same conversion
  # in the caller before the capture sees it, and `String.split/2` sizes its
  # whole result list (~57x the subject) in one block. Only #1231 closes
  # those.
  #
  # Each rule sizes a call from its LITERAL arguments, by position. A pipe
  # (`|>` or `Kernel.|>/2`) or a capture removes arguments from the call node,
  # so a call with fewer arguments than a rule needs is refused rather than
  # guessed at.
  #
  # This is a denylist of what has been measured or read in the stdlib, so it
  # narrows the abort path rather than closing it; issue #1231 moves served
  # evaluation into an OS-limited peer node, which closes the class.
  @strict_flatteners [
    {IO, :iodata_to_binary},
    {IO, :binwrite},
    {Enum, :join},
    {Enum, :map_join},
    {Jason, :encode},
    {Jason, :encode!},
    {List, :to_string},
    {IO, :chardata_to_string}
  ]

  @strict_size_rules %{
    {String, :duplicate} => :duplicate,
    {String, :pad_leading} => :pad,
    {String, :pad_trailing} => :pad,
    {Tuple, :duplicate} => :tuple_duplicate,
    {String, :replace} => :replace,
    {String, :replace_leading} => :replace,
    {String, :replace_trailing} => :replace,
    {Regex, :replace} => :replace,
    {Enum, :into} => :into,
    {Stream, :into} => :into,
    {Calendar, :strftime} => :strftime
  }

  # Largest result a literal repeater or bitstring segment may build: far
  # under any served heap cap, far over what REPL code writes by hand.
  @max_strict_literal_bytes 1_048_576

  # A replacement is copied once per match, so its size is the amplification
  # factor over the subject the evaluation already holds (and the cap counts).
  @max_strict_replacement_bytes 8

  # Struct literals `:strict` lets the source name: each module's own
  # whitelisted functions already build its struct, so a literal reaches no
  # protocol impl those functions do not.
  @strict_struct_modules [
    URI,
    Date,
    Time,
    DateTime,
    NaiveDateTime,
    Range,
    MapSet
  ]

  # Kernel calls that can put a runtime-chosen module under `__struct__`:
  # `struct/2` names it directly, the `*_in` family writes whatever key its
  # path names.
  @kernel_forge_calls [
    :struct,
    :struct!,
    :put_in,
    :update_in,
    :get_and_update_in
  ]

  # Calls that write ONE map key, by their full arity; the key is the second
  # argument, or the first when a pipe has removed the map.
  @struct_key_writers %{
    {Map, :put} => 3,
    {Map, :put_new} => 3,
    {Map, :put_new_lazy} => 3,
    {Map, :replace} => 3,
    {Map, :replace!} => 3,
    {Map, :replace_lazy} => 3,
    {Map, :update} => 4,
    {Map, :update!} => 3,
    {Map, :get_and_update} => 3,
    {Map, :get_and_update!} => 3,
    {Access, :get_and_update} => 3
  }

  # Path selectors that only walk lists and tuples, so never add a map key.
  # `Access.values/0` is not one: it rewrites every value of a map, including
  # a `__struct__` key that `Enum.frequencies([:__struct__])` put there.
  @access_list_selectors [:all, :at, :at!, :elem, :filter, :find, :slice]

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
         {{:., _, [{:__aliases__, _, mod_parts}, func]}, _, args},
         :strict
       ) do
    case resolve_alias(mod_parts) do
      {:unknown, name} ->
        ["#{name}.#{func} is not allowed (module not in whitelist)"]

      {:ok, module} ->
        if module in @allowed_strict_modules do
          check_denied_call(module, func) ++
            check_strict_size(module, func, args) ++
            forge_rule(module, func, args)
        else
          [
            "#{inspect(module)}.#{func} is not allowed (module not in whitelist)"
          ]
        end
    end
  end

  defp check_node({{:., _, [mod, func]}, _, args}, :strict)
       when is_atom(mod) do
    if mod in @allowed_strict_modules do
      check_denied_call(mod, func) ++
        check_strict_size(mod, func, args) ++ forge_rule(mod, func, args)
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

  # A capture writes the same local call with `args == nil`: `&apply/3` parses
  # as `{:&, _, [{:/, _, [{:apply, _, nil}, 3]}]}`, so the `is_list(args)`
  # guards on the `apply`, `send` and spawn clauses skip the inner node and it
  # falls through to the catch-all. `(&apply/3).(:os, :cmd, ...)` and
  # `Enum.map([f], &spawn/1)` therefore returned `:ok` at `:strict`, the level
  # documented as safe for anonymous exposure, and both do exactly what the
  # unwrapped call would (#1045 review).
  #
  # The denial belongs on the capture form, not on the name: a bare
  # `{:apply, _, nil}` on its own is a VARIABLE named `apply`, which is
  # harmless. Qualified captures (`&:os.cmd/1`, `&File.read!/1`) already fail
  # the module clauses above, because their inner node is a dot call whose
  # `args` IS a list.
  defp check_node({:&, _, [{:/, _, [{name, _, _ctx}, arity]}]}, level)
       when is_atom(name) and is_integer(arity) do
    cond do
      name == :apply ->
        ["&apply/#{arity} is not allowed (dynamic function application)"]

      name == :send ->
        [
          "&send/#{arity} is not allowed (message sending to arbitrary processes)"
        ]

      spawn_function?(name) ->
        ["&#{name}/#{arity} is not allowed (process spawning)"]

      level == :strict and name in @kernel_forge_calls ->
        [
          "&#{name}/#{arity} is not allowed at :strict " <>
            "(its arguments cannot be checked for a forged struct)"
        ]

      true ->
        []
    end
  end

  # A qualified capture removes every argument, so a function that can write a
  # `__struct__` key from runtime data is refused captured: `&Map.put/3`
  # applied to a computed key forges as well as the call does.
  defp check_node(
         {:&, _, [{:/, _, [{{:., _, [module, func]}, _, _}, arity]}]},
         :strict
       )
       when is_atom(func) and is_integer(arity) do
    with {:ok, module} <- strict_module(module),
         true <- forge_capture?(module, func, arity) do
      [
        "&#{inspect(module)}.#{func}/#{arity} is not allowed at :strict " <>
          "(its arguments cannot be checked for a forged struct)"
      ]
    else
      _ -> []
    end
  end

  # Module directives can rename or import a denied API before calling it:
  # `alias Task, as: T; T.async(...)` and `import Task; async(...)` otherwise
  # bypass a checker that sees only the submitted AST, not the expanded code.
  defp check_node({directive, _, _args}, level)
       when level in [:standard, :strict] and
              directive in [:alias, :import, :require, :use] do
    ["#{directive} is not allowed (module indirection cannot be checked)"]
  end

  defp check_node({:receive, _, _}, _level) do
    ["receive is not allowed (message interception)"]
  end

  # `import`, `alias`, `require` and `use` decide WHICH module a name reaches,
  # and every clause above decides safety FROM that name, so these four forms
  # sit underneath the whole check rather than inside it. `import System` turns
  # the following `cmd("id", [])` into a bare local call that matches no clause
  # at all; `alias :os, as: Enum` rebinds a whitelisted name onto a denied
  # module, so the checker approves a call the runtime then dispatches to
  # `:os.cmd/1`. Both returned `:ok` at `:strict` -- the level documented as
  # safe for anonymous exposure -- which is CVE-class on a network surface
  # (#1045).
  #
  # Re-checking after alias resolution would mean carrying a `Macro.Env`
  # through the walk and re-deriving what the evaluator is going to do with it.
  # Refusing the four forms is the same guarantee in one clause, and costs
  # sandboxed code nothing it can express another way: the whitelist is written
  # in full module names, and full module names still work.
  #
  # `:none` -- the local-terminal level -- never reaches any clause here;
  # `check/2` returns `:ok` for it before the walk starts.
  defp check_node({kind, _, args}, _level)
       when kind in [:import, :alias, :require, :use] and is_list(args) do
    [
      "#{kind} is not allowed " <>
        "(it rebinds the module names this checker resolves statically)"
    ]
  end

  defp check_node({kind, _, _}, _level)
       when kind in [:defmodule, :defprotocol, :defimpl] do
    ["#{kind} is not allowed (runtime module definition)"]
  end

  # `<<0::size(n)>>` allocates `n` bits in one step: 8 billion reached a
  # ~2.1 GB footprint under an 8 MB cap. Unsized segments need no limit:
  # the evaluator runs `erl_eval`, which appends one segment at a time, so
  # the cap sees a many-part interpolation or `<>` chain grow. Match patterns
  # share the shape and are refused with construction: this walk checks one
  # node at a time and does not track whether it is under a pattern.
  defp check_node({:<<>>, _, segments}, :strict) when is_list(segments) do
    Enum.flat_map(segments, &check_segment_size/1)
  end

  # `for x <- l, into: ""` collects through the same `IO.iodata_to_binary` as
  # `Enum.into(l, "")`.
  defp check_node({:for, _, args}, :strict) when is_list(args) do
    args
    |> Enum.filter(&Keyword.keyword?/1)
    |> Enum.flat_map(fn opts ->
      case Keyword.fetch(opts, :into) do
        {:ok, target} ->
          check_collect_target(target, "for ... into:") ++
            check_for_into_forge(target)

        :error ->
          []
      end
    end)
  end

  # A map whose `__struct__` key names a module is dispatched to that module's
  # protocol impls (`Collectable`, `Enumerable`, `String.Chars`, `Inspect`,
  # `Access`), so the code they run is reached without its module name ever
  # appearing in a call. `m = %{__struct__: File.Stream, path: p, ...};
  # Enum.into(["hi"], m)` wrote a file at `:strict`. The key is refused where a
  # map is BUILT, not where it is used: the uses include string interpolation
  # and the REPL printing its result, which no AST walk can enumerate.
  #
  # Every key must be a literal other than `:__struct__`; a computed key is
  # refused because atoms are free at runtime (`String.to_existing_atom/1`).
  # An update `%{m | a: 1}` only replaces keys `m` already has, so it forges
  # nothing its own keys do not name. Patterns share the shape, so
  # `%{__struct__: mod} = x` is refused too: this walk does not track whether
  # a node is under a pattern, and fails closed as the `<<>>` clause does.
  #
  # `:standard` is untouched: it is a denylist that already allows
  # `File.stream!/1` and `File.open/2` by name, so a forged struct reaches
  # nothing there that a direct call does not.
  defp check_node({:%{}, _, [{:|, _, [_base, pairs]}]}, :strict)
       when is_list(pairs),
       do: check_map_keys(pairs)

  defp check_node({:%{}, _, pairs}, :strict) when is_list(pairs),
    do: check_map_keys(pairs)

  # `%Mod{}` builds a struct of the module it names. Only modules whose own
  # whitelisted functions already build that struct may be named, so a
  # literal reaches no impl the functions do not.
  defp check_node({:%, _, [module, _fields]}, :strict) do
    if struct_module?(module) do
      []
    else
      [
        "%#{Macro.to_string(module)}{} is not allowed at :strict (only " <>
          "#{Enum.map_join(@strict_struct_modules, ", ", &inspect/1)} structs " <>
          "may be built; a struct dispatches to its module's protocol impls)"
      ]
    end
  end

  defp check_node({name, _, args}, :strict)
       when name in [:|> | @kernel_forge_calls] and is_list(args),
       do: forge_rule(Kernel, name, args)

  defp check_node({kind, _, args}, level)
       when level in [:standard, :strict] and is_atom(kind) and is_list(args) do
    if spawn_function?(kind) do
      ["#{kind} is not allowed (process spawning)"]
    else
      []
    end
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

  defp check_strict_size(module, func, args) do
    cond do
      {module, func} in @strict_flatteners and
          not source_literal_call?({module, func}, args) ->
        [
          "#{inspect(module)}.#{func} is not allowed at :strict (it flattens " <>
            "its whole input in one allocation the heap cap only sees " <>
            "afterwards). Print the parts one at a time instead, e.g. " <>
            "`l |> Enum.map(&to_string/1) |> Enum.intersperse(sep) |> Enum.each(&IO.write/1)`"
        ]

      rule = Map.get(@strict_size_rules, {module, func}) ->
        check_size_rule(rule, "#{inspect(module)}.#{func}", args)

      true ->
        []
    end
  end

  # `String.duplicate(s, n)` is the one repeater that multiplies its subject,
  # so both must be literal; a pipe leaves one argument and is refused.
  defp check_size_rule(:duplicate, name, [subject, count])
       when is_binary(subject) and is_integer(count),
       do: within_literal_bound(name, byte_size(subject) * count)

  defp check_size_rule(:duplicate, name, _args),
    do: needs_literals(name, "its string and count")

  # Padding copies the subject once and repeats only the padding, so the
  # subject may be anything; the count and padding must be literal. The
  # forms are `pad(s, n)`, `pad(s, n, p)`, piped `pad(n)` and `pad(n, p)`.
  defp check_size_rule(:pad, name, args) do
    case pad_count_and_padding(args) do
      {count, padding} when is_integer(count) and is_binary(padding) ->
        within_literal_bound(name, count * max(byte_size(padding), 1))

      _unsized ->
        needs_literals(name, "its count and padding")
    end
  end

  # The data is shared, not copied: only the count sizes the tuple.
  defp check_size_rule(:tuple_duplicate, name, args) do
    case args do
      [_data, count] when is_integer(count) ->
        within_literal_bound(name, 8 * count)

      [count] when is_integer(count) ->
        within_literal_bound(name, 8 * count)

      _other ->
        needs_literals(name, "its count")
    end
  end

  # The replacement lands in the result once per match, so its size is the
  # amplification over the subject. It is the last argument that is not an
  # options list, in the direct form and the piped one alike. Options may
  # only be `global:`: `insert_replaced:` inserts the match once per listed
  # position, a factor the caller computes.
  defp check_size_rule(:replace, name, args) when length(args) >= 2 do
    {options, positional} = Enum.split_with(args, &options_list?/1)

    cond do
      not Enum.all?(options, &(Keyword.keys(&1) -- [:global] == [])) ->
        ["#{name} is not allowed at :strict with options other than :global"]

      replacement_ok?(List.last(positional)) ->
        []

      true ->
        [
          "#{name} is not allowed at :strict unless its replacement is a " <>
            "string literal of at most #{@max_strict_replacement_bytes} bytes " <>
            "written in the call"
        ]
    end
  end

  defp check_size_rule(:replace, name, _args),
    do: needs_literals(name, "its replacement")

  defp check_size_rule(:into, name, args) do
    case into_target(args) do
      {:ok, target} ->
        if source_bounded_into?(args),
          do: [],
          else: check_collect_target(target, name)

      :capture ->
        needs_literals(name, "its target")
    end
  end

  # A literal format bounds the number of directives, and every directive is
  # bounded except `%Z`, which copies the input's `:zone_abbr` -- any binary,
  # since `strftime/2` accepts any map. Options carry formatter functions
  # whose output is unbounded, so only the two-argument form (format last,
  # direct or piped) is allowed.
  defp check_size_rule(:strftime, name, args) do
    format = List.last(args)

    if is_binary(format) and not zone_directive?(format) do
      []
    else
      needs_literals(name, "its format (without %Z or options)")
    end
  end

  # `%%` is an escaped percent, so `"%%Z"` prints the text "%Z".
  defp zone_directive?(format) do
    ~r/%%|%[-_0-9]*Z/
    |> Regex.scan(format)
    |> Enum.any?(&(&1 != ["%%"]))
  end

  defp pad_count_and_padding([_subject, count, padding]), do: {count, padding}

  defp pad_count_and_padding([_subject, count]) when is_integer(count),
    do: {count, " "}

  defp pad_count_and_padding([count, padding]), do: {count, padding}
  defp pad_count_and_padding([count]), do: {count, " "}
  defp pad_count_and_padding(_capture), do: :capture

  defp within_literal_bound(_name, bytes)
       when bytes <= @max_strict_literal_bytes,
       do: []

  defp within_literal_bound(name, _bytes) do
    [
      "#{name} is not allowed at :strict beyond #{@max_strict_literal_bytes} bytes of result"
    ]
  end

  defp needs_literals(name, what) do
    [
      "#{name} is not allowed at :strict unless #{what} are literals written " <>
        "in the call (a variable, expression, pipe or capture cannot be sized)"
    ]
  end

  defp options_list?(list) when is_list(list), do: Keyword.keyword?(list)
  defp options_list?(_term), do: false

  defp replacement_ok?(replacement),
    do:
      is_binary(replacement) and
        byte_size(replacement) <= @max_strict_replacement_bytes

  # The collectable's position: `into(enum, target)`, `into(enum, target,
  # fun)`, piped `into(target)` and piped `into(target, fun)`. With two
  # arguments a function in second place means the piped three-argument form;
  # a capture placeholder (`&1`) is a value, never that function.
  defp into_target([_enum, target, _fun]), do: {:ok, target}

  defp into_target([_enum, {:&, _, [n]} = target]) when is_integer(n),
    do: {:ok, target}

  defp into_target([target, {kind, _, _}]) when kind in [:fn, :&],
    do: {:ok, target}

  defp into_target([_enum, target]), do: {:ok, target}
  defp into_target([target]), do: {:ok, target}
  defp into_target(_capture), do: :capture

  # Collecting into a binary flattens at the end; into a list, map or set it
  # does not. Only the TARGET decides: a literal source list can still hold
  # any number of references to a large binary.
  defp check_collect_target(target, name) do
    if non_binary_collectable?(target) do
      []
    else
      [
        "#{name} is not allowed at :strict unless it collects into a literal " <>
          "list or map, or MapSet.new()/Map.new() (collecting into a string " <>
          "flattens in one allocation)"
      ]
    end
  end

  defp non_binary_collectable?(list) when is_list(list), do: true

  # A map literal's keys are checked where it is built (`check_map_keys/1`).
  defp non_binary_collectable?({:%{}, _, _pairs}), do: true

  defp non_binary_collectable?(
         {{:., _, [{:__aliases__, _, [mod]}, :new]}, _, _args}
       )
       when mod in [:MapSet, :Map],
       do: true

  defp non_binary_collectable?(_target), do: false

  # A flattener whose input is written out in the source (`~c"abc"`,
  # `["a", ?b]`) is bounded by the source's own size. Only the forms whose
  # input is the FIRST argument and that do not multiply it qualify: a pipe
  # leaves no first argument (or a separator in its place, which is not a
  # list), and `map_join`'s mapper or `encode`'s options could grow it.
  defp source_literal_call?({mod, func}, [input])
       when {mod, func} in [
              {List, :to_string},
              {IO, :chardata_to_string},
              {IO, :iodata_to_binary}
            ],
       do: source_literal?(input)

  defp source_literal_call?({Enum, :join}, [list | separator])
       when is_list(list) and length(separator) <= 1,
       do: Enum.all?([list | separator], &source_literal?/1)

  defp source_literal_call?(_mfa, _args), do: false

  defp source_literal?({:sigil_c, _, [{:<<>>, _, parts}, _mods]}),
    do: Enum.all?(parts, &is_binary/1)

  defp source_literal?(term), do: Macro.quoted_literal?(term)

  # Only the direct two-argument form names its source, first: a fully
  # literal source, as in `Enum.into([a: 1], m)`, is bounded by the source
  # text. A transform (`into(src, target, fun)`) can grow every element, and
  # the piped `into(target, fun)` has no source to look at.
  defp source_bounded_into?([_target, {:fn, _, _}]), do: false

  defp source_bounded_into?([_target, {:&, _, [body]}])
       when not is_integer(body),
       do: false

  defp source_bounded_into?([source, _target]), do: source_literal?(source)
  defp source_bounded_into?(_piped), do: false

  defp check_map_keys(pairs) do
    if Enum.all?(pairs, &plain_pair?/1) do
      []
    else
      [
        "a map key that is :__struct__ or computed is not allowed at :strict " <>
          "(it can forge a struct, which dispatches to another module's " <>
          "protocol impls); write each key as a literal"
      ]
    end
  end

  defp plain_pair?({key, _value}), do: plain_key?(key)
  defp plain_pair?(_other), do: false

  # Only the atom `:__struct__` forges, so the key's top-level form decides:
  # a literal atom other than it, a number, or a container (string, list,
  # tuple, map, struct, binary) can never evaluate to that atom, whatever it
  # holds. Looking no deeper keeps the walk linear: recursing into the key
  # made nested map keys quadratic, since each nested map rechecks its own.
  defp plain_key?(:__struct__), do: false

  defp plain_key?(key)
       when is_atom(key) or is_number(key) or is_binary(key) or is_list(key),
       do: true

  defp plain_key?({_left, _right}), do: true

  defp plain_key?({form, _, args})
       when form in [:{}, :%{}, :%, :<<>>, :__aliases__] and is_list(args),
       do: true

  defp plain_key?(_computed), do: false

  defp struct_module?({:__aliases__, _, parts}) do
    case resolve_alias(parts) do
      {:ok, module} -> module in @strict_struct_modules
      {:unknown, _name} -> false
    end
  end

  defp struct_module?(_computed), do: false

  defp strict_module({:__aliases__, _, parts}) do
    case resolve_alias(parts) do
      {:ok, module} -> {:ok, module}
      {:unknown, _name} -> :unknown
    end
  end

  defp strict_module(module) when is_atom(module), do: {:ok, module}
  defp strict_module(_computed), do: :unknown

  # The forge rules for one call, local or remote. Only a pipe rebuilds a
  # call: the right-hand side's arguments are short by the piped value, which
  # can be the very input a rule must see (`pairs |> Map.new()` is the same
  # node as `Map.new()` otherwise). The call node is also checked on its own,
  # so the pipe can only add refusals.
  defp forge_violations({{:., _, [module, func]}, _, args})
       when is_atom(func) and is_list(args) do
    case strict_module(module) do
      {:ok, module} -> forge_rule(module, func, args)
      :unknown -> []
    end
  end

  defp forge_violations({name, _, args}) when is_atom(name) and is_list(args),
    do: forge_rule(Kernel, name, args)

  defp forge_violations(_node), do: []

  defp forge_rule(Kernel, :|>, [lhs, {call, meta, args}]) when is_list(args),
    do: forge_violations({call, meta, [lhs | args]})

  # `struct/2` drops a `__struct__` field and `struct!/2` raises on one, so
  # only the module argument can forge.
  defp forge_rule(Kernel, func, args) when func in [:struct, :struct!] do
    case args do
      [module | _fields] ->
        if struct_module?(module),
          do: [],
          else:
            forge_refusal(
              func,
              "only #{Enum.map_join(@strict_struct_modules, ", ", &inspect/1)} " <>
                "may be named, as a literal"
            )

      [] ->
        forge_refusal(func, "its module cannot be seen")
    end
  end

  defp forge_rule(Kernel, func, args)
       when func in [:put_in, :update_in, :get_and_update_in] do
    if access_path_ok?(args),
      do: [],
      else:
        forge_refusal(
          func,
          "its path must be written out from literal keys other than " <>
            ":__struct__, anonymous functions and Access list selectors"
        )
  end

  defp forge_rule(module, func, args)
       when is_map_key(@struct_key_writers, {module, func}) do
    arity = Map.fetch!(@struct_key_writers, {module, func})

    key =
      case length(args) do
        ^arity -> {:ok, Enum.at(args, 1)}
        piped when piped == arity - 1 -> {:ok, hd(args)}
        _capture -> :error
      end

    case key do
      {:ok, key} ->
        if plain_key?(key),
          do: [],
          else:
            forge_refusal(
              module,
              func,
              "its key must be a literal other than :__struct__"
            )

      :error ->
        forge_refusal(module, func, "its key cannot be seen")
    end
  end

  defp forge_rule(Access, func, args) when func in [:key, :key!] do
    case args do
      [key | _default] ->
        if plain_key?(key),
          do: [],
          else:
            forge_refusal(
              Access,
              func,
              "its key must be a literal other than :__struct__"
            )

      [] ->
        forge_refusal(Access, func, "its key cannot be seen")
    end
  end

  # `Map.new()` and the piped `l |> Map.new()` are the same node; the pipe
  # clause above sees the second with its input.
  defp forge_rule(Map, :new, []), do: []

  defp forge_rule(Map, :new, [source]) do
    if forge_free_entries?(source) or match?({:%{}, _, _}, source),
      do: [],
      else: forge_refusal(Map, :new, entries_reason())
  end

  defp forge_rule(Map, :new, _with_transform),
    do: forge_refusal(Map, :new, "its transform computes every key")

  defp forge_rule(Map, :from_keys, [keys, _value]) do
    if is_list(keys) and Enum.all?(keys, &plain_key?/1),
      do: [],
      else:
        forge_refusal(
          Map,
          :from_keys,
          "its keys must be written out as literals other than :__struct__"
        )
  end

  defp forge_rule(Map, :from_keys, _piped),
    do: forge_refusal(Map, :from_keys, "its keys cannot be seen")

  # Both maps can be real structs, and the resolver picks the `__struct__`
  # value: `Map.merge(%URI{}, %URI{}, fn _, _, _ -> File.Stream end)`.
  defp forge_rule(Map, func, args) when func in [:merge, :intersect] do
    case args do
      [_left, _right, _resolver] ->
        forge_refusal(Map, func, resolver_reason())

      [_right, resolver] ->
        if function_literal?(resolver),
          do: forge_refusal(Map, func, resolver_reason()),
          else: []

      _other ->
        []
    end
  end

  defp forge_rule(Map, :map, _args),
    do:
      forge_refusal(
        Map,
        :map,
        "its function rewrites every value, a `__struct__` one included"
      )

  # Collecting into a list, a binary or a `MapSet` builds no map a caller can
  # reach; any other target may be a map, so its entries must be written out.
  defp forge_rule(module, :into, args) when module in [Enum, Stream] do
    case into_target(args) do
      {:ok, target} ->
        if forge_free_target?(target) or forge_free_into_source?(args),
          do: [],
          else:
            forge_refusal(
              module,
              :into,
              entries_reason() <> " unless it collects into a list or MapSet"
            )

      :capture ->
        forge_refusal(module, :into, "its target cannot be seen")
    end
  end

  defp forge_rule(_module, _func, _args), do: []

  # A `for` body computes every entry, so only the target can make it safe.
  defp check_for_into_forge(target) do
    if forge_free_target?(target),
      do: [],
      else: [
        "for ... into: is not allowed at :strict unless it collects into a " <>
          "list or MapSet (its body computes every key, which can forge a struct)"
      ]
  end

  defp forge_capture?(Kernel, func, _arity), do: func in @kernel_forge_calls

  defp forge_capture?(Map, func, arity) when func in [:merge, :intersect],
    do: arity == 3

  defp forge_capture?(Map, :new, arity), do: arity >= 1

  defp forge_capture?(Map, func, _arity) when func in [:from_keys, :map],
    do: true

  defp forge_capture?(module, :into, _arity) when module in [Enum, Stream],
    do: true

  defp forge_capture?(Access, func, _arity) when func in [:key, :key!], do: true

  defp forge_capture?(module, func, _arity),
    do: is_map_key(@struct_key_writers, {module, func})

  defp forge_refusal(Kernel, func, why), do: forge_refusal(func, why)

  defp forge_refusal(module, func, why),
    do: forge_refusal("#{inspect(module)}.#{func}", why)

  defp forge_refusal(name, why) do
    [
      "#{name} is not allowed at :strict here (#{why}; a map with a " <>
        "`__struct__` key dispatches to that module's protocol impls)"
    ]
  end

  defp entries_reason,
    do:
      "its entries must be written out with literal keys other than :__struct__"

  defp resolver_reason,
    do: "its function can rewrite a struct's `__struct__` value"

  defp function_literal?({:fn, _, _}), do: true
  defp function_literal?({:&, _, [body]}) when not is_integer(body), do: true
  defp function_literal?(_value), do: false

  defp forge_free_target?(target) when is_list(target) or is_binary(target),
    do: true

  defp forge_free_target?(
         {{:., _, [{:__aliases__, _, [:MapSet]}, :new]}, _, _args}
       ),
       do: true

  defp forge_free_target?(_target), do: false

  # Only the direct two-argument form names its source (see
  # `source_bounded_into?/1`); the piped `into(target, fun)` has none.
  defp forge_free_into_source?([source, target]),
    do: not function_literal?(target) and forge_free_entries?(source)

  defp forge_free_into_source?(_args), do: false

  # Every entry is a pair whose key is a plain literal, or a literal that is
  # no pair at all (which a map refuses at runtime rather than storing).
  defp forge_free_entries?(entries) when is_list(entries),
    do: Enum.all?(entries, &forge_free_entry?/1)

  defp forge_free_entries?(_computed), do: false

  defp forge_free_entry?({key, _value}), do: plain_key?(key)
  defp forge_free_entry?(entry), do: Macro.quoted_literal?(entry)

  defp access_path_ok?([_data, path, _value]), do: literal_path?(path)

  defp access_path_ok?([path, _value]) when is_list(path),
    do: literal_path?(path)

  defp access_path_ok?([access, _value]), do: access_chain?(access)
  defp access_path_ok?(_args), do: false

  defp literal_path?(path) when is_list(path),
    do: Enum.all?(path, &path_element?/1)

  defp literal_path?(_computed), do: false

  # An anonymous function in a path builds its own data; anything it forges
  # is a node this walk checks like any other.
  defp path_element?({:fn, _, _}), do: true

  defp path_element?({{:., _, [{:__aliases__, _, [:Access]}, func]}, _, args})
       when is_list(args) do
    cond do
      func in @access_list_selectors -> true
      func in [:key, :key!] -> match?([_ | _], args) and plain_key?(hd(args))
      true -> false
    end
  end

  defp path_element?(key), do: plain_key?(key)

  # The `put_in/2` form: `m[:a][:b]` is a chain of `Access.get/2` calls.
  defp access_chain?({{:., _, [Access, :get]}, _, [inner, key]}),
    do: plain_key?(key) and access_base?(inner)

  defp access_chain?(_other), do: false

  defp access_base?({{:., _, [Access, :get]}, _, [_data, _key]} = inner),
    do: access_chain?(inner)

  defp access_base?(_data), do: true

  defp check_segment_size({:"::", _, [_value, spec]}) do
    case collect_segment_size(spec, {nil, nil}) do
      {nil, _unit} ->
        []

      {size, unit}
      when is_integer(size) and (is_integer(unit) or is_nil(unit)) ->
        # Without an explicit unit, assume `binary`'s 8: an overestimate for
        # integer and bits segments, never an underestimate.
        if size * (unit || 8) <= @max_strict_literal_bytes * 8 do
          []
        else
          [
            "bitstring segment over #{@max_strict_literal_bytes} bytes " <>
              "is not allowed at :strict"
          ]
        end

      _computed ->
        [
          "bitstring segment with a computed size or unit is not allowed " <>
            "at :strict (it cannot be sized before it runs)"
        ]
    end
  end

  defp check_segment_size(_segment), do: []

  # A segment spec is a `-` chain of types and modifiers: `binary-size(n)`,
  # `size(4)-unit(8)`, a bare integer (shorthand for `size/1`), or
  # `size*unit` shorthand. A unit with no size is harmless (nothing to
  # multiply), so only a size makes a segment checkable; any call-shaped
  # spec this does not recognise fails closed.
  defp collect_segment_size({:-, _, [left, right]}, acc),
    do: collect_segment_size(right, collect_segment_size(left, acc))

  defp collect_segment_size(n, {_size, unit}) when is_integer(n), do: {n, unit}

  defp collect_segment_size({:*, _, [size, unit]}, _acc),
    do: {literal_or_computed(size), literal_or_computed(unit)}

  defp collect_segment_size({:size, _, [n]}, {_size, unit}),
    do: {literal_or_computed(n), unit}

  defp collect_segment_size({:unit, _, [u]}, {size, _unit}),
    do: {size, literal_or_computed(u)}

  # Types (`binary`, `integer`, `big`, `utf8`, ...) parse as variables.
  defp collect_segment_size({_type, _, ctx}, acc) when is_atom(ctx), do: acc
  defp collect_segment_size(_unknown, {_size, unit}), do: {:computed, unit}

  defp literal_or_computed(n) when is_integer(n), do: n
  defp literal_or_computed(_n), do: :computed

  defp check_denied_call(module, func) do
    case Map.fetch(@denied_process_modules, module) do
      {:ok, reason} ->
        ["#{inspect(module)}.#{func} is not allowed (#{reason})"]

      :error ->
        check_denied_function(module, func)
    end
  end

  defp check_denied_function(module, func)
       when module in [Kernel, Node, :erlang] do
    if spawn_function?(func) do
      ["#{inspect(module)}.#{func} is not allowed (process spawning)"]
    else
      check_denied_standard_function(module, func)
    end
  end

  defp check_denied_function(module, func),
    do: check_denied_standard_function(module, func)

  defp check_denied_standard_function(module, func) do
    case Enum.find(@denied_standard, fn {m, f, _} ->
           m == module and f == func
         end) do
      {_, _, reason} ->
        ["#{inspect(module)}.#{func} is not allowed (#{reason})"]

      nil ->
        []
    end
  end

  defp spawn_function?(func),
    do: func |> Atom.to_string() |> String.starts_with?("spawn")
end
