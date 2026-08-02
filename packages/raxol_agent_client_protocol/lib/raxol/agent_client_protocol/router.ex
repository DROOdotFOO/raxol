defmodule Raxol.AgentClientProtocol.Router.Codegen do
  @moduledoc false
  # Compile-time codegen for Raxol.AgentClientProtocol.Router: builds
  # decode/4, dispatch/4, and result_marker/1 function clauses directly from
  # Raxol.AgentClientProtocol.MethodTable.rows/0 -- the *only* wire-string
  # association in this module is these compile-time-generated clauses on
  # literal binaries (no `String.to_atom/1` on wire input, ever).
  #
  # Per the design doc (scratchpad/specs/acp-methodtable-design.md §2.1),
  # this builds a list of quoted expressions from the rows and splices them
  # with `unquote_splicing/1` -- no `Module.eval_quoted`.
  #
  # Each of the three artifacts is its own macro so its clauses land
  # contiguously in Router's source (Elixir warns -- an error under
  # `--warnings-as-errors` -- if clauses of the same name/arity are not
  # grouped together): `defdecode/1` emits ALL of `decode/4` for one side,
  # `defdispatch_clauses/1` emits ALL of `dispatch/4` for one side,
  # `defresult_markers/0` emits ALL of `result_marker/1` (shared across both
  # sides -- see its own doc below for why one function suffices).

  alias Raxol.AgentClientProtocol.MethodTable

  @doc """
  Emits `decode/4` clauses for `side` (`:agent` | `:client`), covering every
  `layer: :app` row `side` handles (`MethodTable.rows_for_side/1`), in the
  fixed order the design doc §4 pins:

    1. Core rows (literal wire binaries).
    2. Registered `_raxol/*` rows (literal binaries; none exist yet, so this
       tier currently contributes zero clauses -- see `MethodTable` row
       table).
    3. `"_" <> _rest` passthrough -- binary preserved, no atom created.
    4. Catch-all -- `{:error, :method_not_found}`.

  `layer: :protocol` and `layer: :session_control` rows are excluded from
  this side's clauses entirely (D1-2 fix / §6.0 G2 delta): `Connection`
  pre-filters their wire method strings before ever calling `decode/4`, so
  neither `$/cancel_request` nor `session/cancel` ever reaches here.
  """
  defmacro defdecode(side) do
    rows =
      side
      |> MethodTable.rows_for_side()
      |> Enum.filter(&(&1.layer == :app))

    # Tier 1 (core rows) and tier 2 (registered `_raxol/*` rows) are both
    # literal-binary clauses generated the same way; tier 2 is simply the
    # subset with `ext == :raxol`. Splitting them keeps tier-2 rows (more
    # specific) emitted right after tier-1 core rows and strictly before
    # the tier-3 `"_"` prefix clause, matching §4's ordering even though
    # today's table has no tier-2 rows.
    {core_rows, raxol_rows} = Enum.split_with(rows, &(&1.ext == nil))

    literal_clauses = Enum.map(core_rows ++ raxol_rows, &decode_clause(side, &1))
    ext_clauses = ext_passthrough_decode_clauses(side)
    catchall = catchall_decode_clause(side)

    quote do
      (unquote_splicing(literal_clauses ++ ext_clauses ++ [catchall]))
    end
  end

  @doc """
  Emits `dispatch/4` clauses for `side`, one pair-tag per `layer: :app` row
  `side` handles. `MethodTable` invariant 3 (unique callback per handling
  side) guarantees these tags never collide within one side's clauses, so
  no ordering beyond "literal rows only" is required here (unlike
  `decode/4`, there is no catch-all: `dispatch/4` is only ever called with a
  tagged tuple that `decode/4` itself produced, and the `:ext_request` /
  `:ext_notification` tags from the passthrough tier are routed to
  `handle_ext_request/3` / `handle_ext_notification/3` directly by the
  caller, not through this table-driven dispatch).
  """
  defmacro defdispatch_clauses(side) do
    rows =
      side
      |> MethodTable.rows_for_side()
      |> Enum.filter(&(&1.layer == :app))

    clauses = Enum.map(rows, &dispatch_clause(side, &1))

    quote do
      (unquote_splicing(clauses))
    end
  end

  @doc """
  Emits `result_marker/1` clauses: one literal-binary clause per
  `kind: :request, layer: :app` row in the WHOLE table (not split by side).

  D1-4 fix (design doc §2.3): a wire method string is globally unique
  across the table (`MethodTable` invariant 1 keys on `{direction, wire}`,
  and no two rows share a wire string across directions in practice), so a
  single shared `result_marker/1` serves whichever side is sending -- there
  is no ambiguity in combining both sides' outbound rows into one function.
  `Connection` calls this ONCE at send time and stores the resulting marker
  in the pending map, never re-deriving it when the response arrives.

  Returns `{:decode, ResultModule}` for a core/registered row, or `:ext` for
  an `"_"`-prefixed outbound ext request. A final `:unknown` clause exists
  only as a defensive total-function fallback (self-sent wire strings
  should always be one of the two real markers above); it is not part of
  the two-marker taxonomy the design doc describes.
  """
  defmacro defresult_markers do
    rows =
      MethodTable.rows()
      |> Enum.filter(&(&1.kind == :request and &1.layer == :app))

    literal_clauses =
      Enum.map(rows, fn row ->
        quote do
          def result_marker(unquote(row.wire)), do: {:decode, unquote(row.result)}
        end
      end)

    ext_clause =
      quote do
        def result_marker("_" <> _), do: :ext
      end

    fallback_clause =
      quote do
        def result_marker(_wire), do: :unknown
      end

    quote do
      (unquote_splicing(literal_clauses ++ [ext_clause, fallback_clause]))
    end
  end

  # -- decode/4 clause builders -------------------------------------------------

  defp decode_clause(side, %{kind: :request, params: nil} = row) do
    quote do
      def decode(unquote(side), :request, unquote(row.wire), _params) do
        {:ok, {unquote(row.callback), nil}}
      end
    end
  end

  defp decode_clause(side, %{kind: :request} = row) do
    quote do
      def decode(unquote(side), :request, unquote(row.wire), params) do
        with {:ok, req} <- unquote(row.params).from_json(params) do
          {:ok, {unquote(row.callback), req}}
        end
      end
    end
  end

  defp decode_clause(side, %{kind: :notification, params: nil} = row) do
    quote do
      def decode(unquote(side), :notification, unquote(row.wire), _params) do
        {:ok, {unquote(row.callback), nil}}
      end
    end
  end

  defp decode_clause(side, %{kind: :notification} = row) do
    quote do
      def decode(unquote(side), :notification, unquote(row.wire), params) do
        with {:ok, n} <- unquote(row.params).from_json(params) do
          {:ok, {unquote(row.callback), n}}
        end
      end
    end
  end

  defp ext_passthrough_decode_clauses(side) do
    [
      quote do
        def decode(unquote(side), :request, "_" <> _ = wire, params) do
          {:ok, {:ext_request, wire, params}}
        end
      end,
      quote do
        def decode(unquote(side), :notification, "_" <> _ = wire, params) do
          {:ok, {:ext_notification, wire, params}}
        end
      end
    ]
  end

  defp catchall_decode_clause(side) do
    quote do
      def decode(unquote(side), _kind, _wire, _params) do
        {:error, :method_not_found}
      end
    end
  end

  # -- dispatch/4 clause builders ------------------------------------------------

  # D1-6: params: nil rows drop the callback to arity 1 (ctx only).
  defp dispatch_clause(side, %{params: nil, kind: :request} = row) do
    quote do
      def dispatch(unquote(side), handler, {unquote(row.callback), nil}, ctx) do
        apply(handler, unquote(row.callback), [ctx])
      end
    end
  end

  defp dispatch_clause(side, %{kind: :request} = row) do
    quote do
      def dispatch(unquote(side), handler, {unquote(row.callback), req}, ctx) do
        apply(handler, unquote(row.callback), [req, ctx])
      end
    end
  end

  # Notification dispatch always returns :ok, regardless of what the
  # handler callback itself returns (design doc §2.2/§7: "Notification
  # callback returns non-:ok -- ignored; nothing is ever written to the
  # wire for a notification").
  defp dispatch_clause(side, %{kind: :notification} = row) do
    quote do
      def dispatch(unquote(side), handler, {unquote(row.callback), params}, ctx) do
        _ = apply(handler, unquote(row.callback), [params, ctx])
        :ok
      end
    end
  end
end

defmodule Raxol.AgentClientProtocol.Router do
  @moduledoc """
  Table-driven JSON-RPC method routing for ACP: `decode/4` classifies and
  type-decodes an inbound wire method + params into a tagged tuple,
  `dispatch/4` calls the matching handler callback, and `result_marker/1`
  tells the sending side how to decode a pending outbound request's
  response.

  Every function clause here is generated at compile time from
  `Raxol.AgentClientProtocol.MethodTable.rows/0` by the internal
  `Router.Codegen` module (not part of the public docs; `@moduledoc
  false`) -- editing the table is the only way to change routing behavior;
  there is no hand-maintained parallel list of method strings anywhere in
  this module. See
  `scratchpad/specs/acp-methodtable-design.md` for the full design and its
  G1/G2 gate-review fix log.

  ## What this module does NOT do (by design)

  * **No capability gating.** `Connection` consults `MethodTable`'s
    `capability` field and must reject a gated-and-unnegotiated method with
    -32601 BEFORE ever calling `decode/4` (D1-3 fix) -- `Router` has no
    capability awareness at all.
  * **No `$/cancel_request` or `session/cancel` clauses.** Both are
    `Connection`-routed session-control paths pre-filtered on the wire
    method string before `decode/4` is called (D1-2 fix; §6.0 G2 delta for
    `session/cancel`). Calling `decode(side, :notification,
    "$/cancel_request", _)` or `decode(side, :notification,
    "session/cancel", _)` falls through to the catch-all like any other
    unrecognized method -- callers must pre-filter, not rely on `Router` to
    special-case them.
  * **No pending-map bookkeeping.** `result_marker/1` is a pure lookup;
    storing `pending[id] = %{marker: ..., from: ...}` and reading it back on
    response arrival (D1-4/D1-5 fixes: markers computed once at send time,
    ids include `nil`) is `Connection`'s job.

  ## Decoding

      iex> Raxol.AgentClientProtocol.Router.decode(:agent, :request, "session/prompt", %{"sessionId" => "s1", "prompt" => []})
      {:ok, {:prompt, %Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest{session_id: "s1", prompt: []}}}

      iex> Raxol.AgentClientProtocol.Router.decode(:agent, :request, "_vendor/thing", %{"x" => 1})
      {:ok, {:ext_request, "_vendor/thing", %{"x" => 1}}}

      iex> Raxol.AgentClientProtocol.Router.decode(:agent, :request, "no/such/method", %{})
      {:error, :method_not_found}
  """

  require Raxol.AgentClientProtocol.Router.Codegen
  require Raxol.AgentClientProtocol.MethodTable
  alias Raxol.AgentClientProtocol.MethodTable
  alias Raxol.AgentClientProtocol.Router.Codegen

  # This module bakes `MethodTable.rows/0` data into its decode/dispatch/
  # result_marker clauses, so it MUST recompile when the table source changes
  # (a `rows/0` call alone is only an exports dependency). See
  # `MethodTable.depend_on_source/0`.
  MethodTable.depend_on_source()

  @typedoc "Which side is decoding/dispatching: the side that HANDLES the row (see `MethodTable.rows_for_side/1`)."
  @type side :: :agent | :client

  @typedoc "A decoded, dispatchable inbound message: `{callback_tag, decoded_params_or_nil}`."
  @type decoded ::
          {atom(), struct() | nil}
          | {:ext_request, String.t(), map()}
          | {:ext_notification, String.t(), map()}

  @typedoc "What `Connection` should do with a pending outbound request's response, per D1-4."
  @type result_marker :: {:decode, module()} | :ext | :unknown

  @doc """
  Classify and decode an inbound JSON-RPC method + params for `side`.

  Returns `{:ok, decoded}` for a recognized core/registered row or an
  `"_"`-prefixed ext passthrough, `{:error, :method_not_found}` for an
  unrecognized method (⇒ -32601 at the caller), or `{:error, reason}` when a
  recognized row's `params` fail to decode (⇒ -32602 at the caller).

  Never creates an atom from `wire` -- unknown and ext methods stay
  binaries end-to-end.
  """
  @spec decode(side(), MethodTable.kind(), String.t(), term()) ::
          {:ok, decoded()} | {:error, term()}
  Codegen.defdecode(:agent)
  Codegen.defdecode(:client)

  @doc """
  Dispatch a decoded message (as produced by `decode/4`) to `handler`'s
  matching callback. Request callbacks are called with `(params, ctx)` (or
  `(ctx)` alone for `params: nil` rows, per D1-6); notification callbacks
  are called with `(params, ctx)` and this function always returns `:ok`
  regardless of what the callback itself returns.
  """
  @spec dispatch(side(), module(), decoded(), term()) :: term()
  Codegen.defdispatch_clauses(:agent)
  Codegen.defdispatch_clauses(:client)

  @doc """
  Look up how the sending side should decode the response to an outbound
  request for `wire`, computed once at send time (D1-4) -- never re-derive
  this from the wire string when the response actually arrives; store the
  returned marker in the pending-request entry instead.
  """
  @spec result_marker(String.t()) :: result_marker()
  Codegen.defresult_markers()
end
