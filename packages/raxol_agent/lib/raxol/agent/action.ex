defmodule Raxol.Agent.Action do
  @moduledoc """
  Behaviour for reusable, composable agent operations.

  Actions are the unit of work in the agent framework. Each Action module
  declares its input/output schemas, implements a `run/2` callback, and
  can be composed into pipelines or converted to LLM tool definitions.

  ## Example

      defmodule ReadFile do
        use Raxol.Agent.Action,
          name: "read_file",
          description: "Read a file from disk",
          schema: [
            input: [
              path: [type: :string, required: true, description: "File path"]
            ],
            output: [
              content: [type: :string],
              line_count: [type: :integer]
            ]
          ]

        @impl true
        def run(%{path: path}, _context) do
          case File.read(path) do
            {:ok, content} ->
              {:ok, %{content: content, line_count: length(String.split(content, "\\n"))}}
            {:error, reason} ->
              {:error, {:file_read_failed, reason}}
          end
        end
      end

  Actions integrate with TEA agents via `run_action/3` and
  `run_action_async/3` helpers injected by `use Raxol.Agent`.
  """

  alias Raxol.Agent.Action.Schema

  @type params :: map()
  @type context :: map()
  @type effect :: Raxol.Core.Runtime.Command.t() | Raxol.Agent.Directive.t()
  @type result ::
          {:ok, map()}
          | {:ok, map(), [effect()]}
          | {:error, term()}

  @doc "Execute the action with validated params and context."
  @callback run(params(), context()) :: result()

  @doc "Optional: transform params before validation."
  @callback before_validate(params()) :: params()

  @doc "Optional: transform result after successful run."
  @callback after_run(map(), context()) :: map()

  @optional_callbacks [before_validate: 1, after_run: 2]

  @doc false
  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, "")
    schema = Keyword.get(opts, :schema, [])
    input_schema = Keyword.get(schema, :input, [])
    output_schema = Keyword.get(schema, :output, [])

    quote do
      @behaviour Raxol.Agent.Action

      @__action_name__ unquote(name)
      @__action_description__ unquote(description)
      @__action_input_schema__ unquote(Macro.escape(input_schema))
      @__action_output_schema__ unquote(Macro.escape(output_schema))

      @doc false
      def __action_meta__ do
        %{
          name: @__action_name__,
          description: @__action_description__,
          input_schema: @__action_input_schema__,
          output_schema: @__action_output_schema__
        }
      end

      @doc """
      Validate input, run the action, validate output.

      Returns `{:ok, result}`, `{:ok, result, commands}`, or `{:error, reason}`.
      """
      def call(params, context \\ %{}) do
        Raxol.Agent.Action.__call__(__MODULE__, params, context)
      end

      @doc "Generate an LLM tool definition for this action."
      def to_tool_definition do
        Raxol.Agent.Action.Schema.to_json_schema(
          @__action_input_schema__,
          @__action_name__,
          @__action_description__
        )
      end
    end
  end

  @doc false
  @spec __call__(module(), params(), context()) :: result()
  def __call__(module, params, context) do
    meta = module.__action_meta__()

    params =
      if function_exported?(module, :before_validate, 1),
        do: module.before_validate(params),
        else: params

    with {:ok, validated} <- Schema.validate(params, meta.input_schema) do
      case module.run(validated, context) do
        {:ok, output} ->
          output = maybe_after_run(module, output, context)
          validate_output(output, meta.output_schema)

        {:ok, output, commands} ->
          output = maybe_after_run(module, output, context)

          case validate_output(output, meta.output_schema) do
            {:ok, validated_output} -> {:ok, validated_output, commands}
            error -> error
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp maybe_after_run(module, output, context) do
    if function_exported?(module, :after_run, 2),
      do: module.after_run(output, context),
      else: output
  end

  defp validate_output(output, []), do: {:ok, output}

  defp validate_output(output, schema) do
    Schema.validate(output, schema)
  end
end
