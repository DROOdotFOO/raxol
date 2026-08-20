# Used by "mix format"
[
  inputs: [
    "*.{ex,exs}",
    "{config,lib,examples}/**/*.{ex,exs}",
    "test/*.exs",
    "test/support/**/*.ex",
    "priv/*/seeds.exs"
  ],
  exclude: [
    "test/fixtures"
  ],
  line_length: 80,
  # Each package carries its own .formatter.exs and formats at the 98-column
  # default. Without delegation, a root-cwd `mix format packages/...` -- what an
  # editor save does in a monorepo workspace -- rewraps those files at 80 and
  # reverts exactly what the per-package CI gate blessed.
  #
  # This list tracks the `package-tests` matrix in .github/workflows/ci-unified.yml,
  # which is the only place a package is format-gated. Widening it to `packages/*`
  # pulls the ungated packages (169 files of pre-existing drift) into the root
  # check, so a package joins here when it joins that matrix.
  subdirectories: [
    "packages/raxol_agent_client_protocol",
    "packages/raxol_cli",
    "packages/raxol_earn",
    "packages/raxol_gateway",
    "packages/raxol_payments",
    "packages/raxol_telegram"
  ],
  locals_without_parens: [
    # Phoenix
    action_fallback: 1,
    allow_upload: 2,
    attr: 3,
    before_send: 1,
    plug: 1,
    plug: 2,
    render: 2,
    render: 3,
    render: 4,
    render_layout: 2,
    render_layout: 3,
    render_layout: 4,
    socket: 2,
    transport: 2,

    # Ecto
    belongs_to: 2,
    belongs_to: 3,
    embeds_many: 2,
    embeds_many: 3,
    embeds_one: 2,
    embeds_one: 3,
    field: 2,
    field: 3,
    has_many: 2,
    has_many: 3,
    has_one: 2,
    has_one: 3,
    many_to_many: 2,
    many_to_many: 3,
    timestamps: 1,

    # Phoenix LiveView
    live_component: 1,
    live_component: 2,
    live_component: 3,
    live_view: 1,
    live_view: 2,
    live_view: 3,

    # Raxol
    terminal: 1,
    terminal: 2,
    web: 1,
    web: 2,
    component: 1,
    component: 2,
    style: 1,
    style: 2
  ]
]
