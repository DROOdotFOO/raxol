%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      strict: true,
      checks: [
        # SECURITY GATE: never String.to_atom on wire input — atom-table
        # exhaustion DoS (atoms are never GC'd). Method dispatch goes through
        # the compile-time MethodTable whitelist instead. CI also greps for
        # this (see scripts note in README).
        {Credo.Check.Warning.UnsafeToAtom, []},
        {Credo.Check.Readability.ModuleDoc, []},
        {Credo.Check.Design.AliasUsage, false}
      ]
    }
  ]
}
