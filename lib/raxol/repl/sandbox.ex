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
  alias resolution, and the bare-name capture forms of `apply` and `spawn` were
  each `:ok` at `:strict` until they were not.

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
  #
  # `List.to_string/1`, `IO.chardata_to_string/1` and `inspect/2` build their
  # output in chunks the cap does see, so they stay allowed.
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
    {Jason, :encode!}
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

  # Unsized binary segments in one `<<>>`, interpolation or `<>` chain. Each
  # is something the evaluation already holds, so the construction is bounded
  # by this many times the cap.
  @max_strict_unsized_segments 8

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
            check_strict_size(module, func, args)
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
      check_denied_call(mod, func) ++ check_strict_size(mod, func, args)
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
  defp check_node({:&, _, [{:/, _, [{name, _, _ctx}, arity]}]}, _level)
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

      true ->
        []
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
  # ~2.1 GB footprint under an 8 MB cap, and a construction with many
  # unsized `::binary` segments (what interpolation expands to) is sized and
  # allocated whole before it is filled. Match patterns share the shape and
  # are refused with construction: this walk checks one node at a time and
  # does not track whether it is under a pattern.
  defp check_node({:<<>>, _, segments}, :strict) when is_list(segments) do
    unsized = Enum.count(segments, &unsized_binary_segment?/1)

    Enum.flat_map(segments, &check_segment_size/1) ++
      too_many_segments(unsized, "<<>> or interpolation")
  end

  # `a <> b <> ...` expands into a single `<<>>` after this check runs, so its
  # operands are counted here, at the top of the chain.
  defp check_node({:<>, _, [_left, _right]} = chain, :strict) do
    unsized = chain |> concat_operands() |> Enum.count(&(not is_binary(&1)))
    too_many_segments(unsized, "<> chain")
  end

  # `for x <- l, into: ""` collects through the same `IO.iodata_to_binary` as
  # `Enum.into(l, "")`.
  defp check_node({:for, _, args}, :strict) when is_list(args) do
    args
    |> Enum.filter(&Keyword.keyword?/1)
    |> Enum.flat_map(fn opts ->
      case Keyword.fetch(opts, :into) do
        {:ok, target} -> check_collect_target([target], "for ... into:")
        :error -> []
      end
    end)
  end

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
      {module, func} in @strict_flatteners ->
        [
          "#{inspect(module)}.#{func} is not allowed at :strict (it flattens " <>
            "its whole input in one allocation the heap cap only sees " <>
            "afterwards). Build text in chunks instead: " <>
            "`l |> Enum.map(&to_string/1) |> Enum.intersperse(sep) |> List.to_string()`, " <>
            "or `Jason.encode_to_iodata!/1` for JSON"
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
  # options list, in the direct form and the piped one alike.
  defp check_size_rule(:replace, name, args) when length(args) >= 2 do
    case args |> Enum.reject(&Keyword.keyword?/1) |> List.last() do
      replacement
      when is_binary(replacement) and
             byte_size(replacement) <= @max_strict_replacement_bytes ->
        []

      _other ->
        [
          "#{name} is not allowed at :strict unless its replacement is a " <>
            "string literal of at most #{@max_strict_replacement_bytes} bytes " <>
            "written in the call"
        ]
    end
  end

  defp check_size_rule(:replace, name, _args),
    do: needs_literals(name, "its replacement")

  defp check_size_rule(:into, name, args), do: check_collect_target(args, name)

  # The format is literal and directive-sized; what can grow is the output
  # of formatter functions passed as options, so only the two-argument form
  # (format last, direct or piped) is allowed.
  defp check_size_rule(:strftime, name, args) do
    if args != [] and is_binary(List.last(args)) do
      []
    else
      needs_literals(name, "its format (and no options)")
    end
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

  # Collecting into a binary flattens at the end; into a list or a map it
  # does not. Either the target is a literal list or map, or the literal
  # list or map is the (source-bounded) enumerable -- both are safe, and
  # piping cannot make a binary target look like either.
  defp check_collect_target(args, name) do
    if Enum.any?(args, &literal_collection?/1) do
      []
    else
      [
        "#{name} is not allowed at :strict unless it collects into a literal " <>
          "list or map (collecting into a string flattens in one allocation)"
      ]
    end
  end

  defp literal_collection?(list) when is_list(list), do: true
  defp literal_collection?({:%{}, _, _pairs}), do: true
  defp literal_collection?(_term), do: false

  defp too_many_segments(count, _what)
       when count <= @max_strict_unsized_segments,
       do: []

  defp too_many_segments(count, what) do
    [
      "#{what} with #{count} computed binary parts is not allowed at :strict " <>
        "(at most #{@max_strict_unsized_segments}; it is allocated whole before " <>
        "it is filled)"
    ]
  end

  defp unsized_binary_segment?({:"::", _, [value, spec]}) do
    not is_binary(value) and binary_spec?(spec) and
      match?({nil, _}, collect_segment_size(spec, {nil, nil}))
  end

  defp unsized_binary_segment?(_segment), do: false

  defp binary_spec?({:-, _, [left, right]}),
    do: binary_spec?(left) or binary_spec?(right)

  defp binary_spec?({type, _, ctx})
       when type in [:binary, :bytes, :bitstring, :bits] and is_atom(ctx),
       do: true

  defp binary_spec?(_spec), do: false

  defp concat_operands({:<>, _, [left, right]}),
    do: concat_operands(left) ++ concat_operands(right)

  defp concat_operands(operand), do: [operand]

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
