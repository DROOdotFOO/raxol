# AI Cockpit
#
# Multi-pane terminal dashboard with real AI agents analyzing your codebase.
# Streams LLM responses in real time, supports pilot takeover to ask
# follow-up questions, and demonstrates the full agent + cockpit stack.
#
# What you'll learn:
#   - Tiered backend detection: checks env vars in priority order
#     (Lumo > Anthropic > Kimi > OpenAI > Ollama > LLM7 > Mock)
#   - Agent + Dashboard pattern: headless agents do work, a TEA app
#     polls their models for display (analyst + summarizer + dashboard)
#   - Streaming via Directive.async: sender callback delivers {:chunk, text}
#     incrementally, then {:done, response} when complete
#   - Pilot takeover: dashboard captures keyboard input and forwards
#     user questions to the analyst agent for follow-up
#
# Default: mock streaming (no API key needed, runs instantly)
# Lumo:    PROTON_UID=... PROTON_ACCESS_TOKEN=... mix run ...
# Kimi:    KIMI_API_KEY=... mix run ...
# Free AI: FREE_AI=true mix run examples/agents/ai_cockpit.exs
# Ollama:  OLLAMA_MODEL=llama3 mix run examples/agents/ai_cockpit.exs
# Groq:    AI_API_KEY=gsk_... AI_BASE_URL=https://api.groq.com/openai AI_MODEL=llama-3.3-70b-versatile mix run ...
# OpenAI:  AI_API_KEY=sk-... AI_MODEL=gpt-4o-mini mix run ...
# Claude:  ANTHROPIC_API_KEY=sk-ant-... mix run ...
#
# Controls:
#   n         analyze next file
#   t         takeover (type a question for the AI)
#   Enter     send question (during takeover)
#   Esc / r   release takeover
#   Tab       switch panel focus
#   q         quit

Logger.configure(level: :warning)

# -- Backend Configuration ---------------------------------------------------
# Tiered detection: first env var match wins. This lets the same example
# work with any provider or fall back to mock mode with zero config.

defmodule AICockpit.Config do
  @moduledoc false

  def detect_backend do
    cond do
      System.get_env("PROTON_UID") && System.get_env("PROTON_ACCESS_TOKEN") ->
        {:lumo, []}

      System.get_env("LUMO_TAMER_URL") ->
        {:lumo, []}

      key = System.get_env("ANTHROPIC_API_KEY") ->
        {:http,
         provider: :anthropic,
         api_key: key,
         base_url: "https://api.anthropic.com",
         model: System.get_env("ANTHROPIC_MODEL") || "claude-haiku-3-5-20241022",
         max_tokens: 512}

      key = System.get_env("KIMI_API_KEY") ->
        {:http,
         provider: :kimi,
         api_key: key,
         base_url: "https://api.moonshot.ai",
         model: System.get_env("KIMI_MODEL") || "kimi-k2.5",
         max_tokens: 512}

      key = System.get_env("AI_API_KEY") ->
        {:http,
         provider: :openai,
         api_key: key,
         base_url: System.get_env("AI_BASE_URL") || "https://api.openai.com",
         model: System.get_env("AI_MODEL") || "gpt-4o-mini",
         max_tokens: 512}

      model = System.get_env("OLLAMA_MODEL") ->
        {:http,
         provider: :ollama,
         base_url: System.get_env("OLLAMA_URL") || "http://localhost:11434",
         model: model,
         max_tokens: 512}

      System.get_env("FREE_AI") ->
        {:http,
         provider: :openai,
         api_key: "unused",
         base_url: "https://api.llm7.io/v1",
         model: System.get_env("AI_MODEL") || "gpt-4o-mini",
         max_tokens: 512}

      true ->
        {:mock, []}
    end
  end

  def backend_label({:lumo, _}), do: "lumo:proton"
  def backend_label({:http, opts}), do: "#{opts[:provider]}:#{opts[:model]}"
  def backend_label({:mock, _}), do: "mock (set API key for real AI)"
end

# -- Mock Streaming -----------------------------------------------------------

defmodule AICockpit.MockStream do
  @moduledoc false

  @analyses %{
    "agent.ex" => """
    Purpose: Provides `use Raxol.Agent` macro that wires TEA callbacks \
    and agent-specific command helpers for AI agent development.

    Patterns: Macro-based module injection, behaviour delegation to \
    Runtime.Application, convenience wrappers (async/1, shell/1, \
    send_agent/2) over the Command module.

    Strength: Clean separation -- agents get the full TEA lifecycle \
    without agent-specific complexity leaking into the core runtime. \
    The macro is thin (no magic), just callback defaults + helpers.

    Improvement: A declarative `backend:` option in `use Raxol.Agent, \
    backend: HTTP` could auto-wire AI backend config, reducing the \
    boilerplate of manual Directive.async calls for LLM integration.\
    """,
    "session.ex" => """
    Purpose: GenServer wrapper that hosts a TEA agent within the \
    Lifecycle runtime using `environment: :agent` to skip terminal \
    and plugin initialization.

    Patterns: Registry-based discovery via Agent.Registry, Lifecycle \
    delegation with anonymous Dispatcher to prevent singleton \
    conflicts when multiple agents run concurrently.

    Strength: Excellent OTP integration -- each agent gets full \
    supervision, crash isolation, and state management with zero \
    custom GenServer boilerplate. Start/stop is clean.

    Improvement: Missing a `subscribe/2` API for external observers \
    to receive model change notifications. The cockpit dashboard \
    currently polls via get_model/1 on a timer.\
    """,
    "command.ex" => """
    Purpose: Side-effect system for TEA applications -- all impure \
    operations (async tasks, shell commands, inter-agent messages) \
    are data returned from update/2.

    Patterns: Command-as-data (functional core / imperative shell), \
    sender callback closure for streaming async results, \
    Registry-routed agent messaging with error feedback.

    Strength: The sender callback in async commands enables \
    incremental updates -- each sender call delivers a new message \
    to the agent's update/2, enabling real-time streaming without \
    any framework changes.

    Improvement: A dedicated `Directive.stream/2` convenience wrapping \
    the async+sender pattern for AI backends would reduce agent \
    boilerplate from ~10 lines to 1.\
    """,
    "component.ex" => """
    Purpose: Base behaviour for all Raxol UI widgets, defining the \
    canonical lifecycle (init/1, handle_event/3, render/2) with \
    sensible defaults.

    Patterns: Behaviour with optional callbacks, context-based \
    rendering where focus state, theme, and dimensions flow through \
    a context map rather than global state.

    Strength: The context parameter in render/2 decouples widgets \
    from global state -- each widget receives only what it needs, \
    making components independently testable and reusable across \
    terminal, web, and SSH surfaces.

    Improvement: handle_event/3 takes (event, state, context) but \
    most widgets ignore context. A two-arity default with optional \
    three-arity override would reduce noise in simple widgets.\
    """
  }

  @followup """
  Based on the codebase analysis so far, the architecture follows \
  clean OTP patterns throughout. The TEA model provides predictable \
  state management, the Command system isolates side effects, and \
  the agent framework builds naturally on top of both.

  The key insight is that agents are just TEA apps with extra message \
  types -- {:agent_message, from, payload} for inter-agent comms and \
  {:command_result, data} for async operations. This means any TEA \
  pattern (subscriptions, view rendering, time-travel debugging) \
  works with agents out of the box.

  The streaming capability through Directive.async sender callbacks \
  is particularly elegant -- the same mechanism that handles shell \
  command output also handles LLM token streaming.\
  """

  def stream_response(prompt, sender) do
    text =
      Enum.find_value(@analyses, @followup, fn {key, val} ->
        if String.contains?(prompt, key), do: val
      end)

    text
    |> String.split(~r/(?<=\s)/)
    |> Enum.each(fn word ->
      sender.({:chunk, word})
      Process.sleep(15 + :rand.uniform(35))
    end)

    token_count = text |> String.split() |> length()

    sender.(
      {:done,
       %{
         content: text,
         usage: %{"input_tokens" => 150, "output_tokens" => token_count},
         metadata: %{provider: :mock}
       }}
    )
  end
end

# -- Analyst Agent ------------------------------------------------------------

defmodule AICockpit.Analyst do
  @moduledoc false
  use Raxol.Agent

  @files [
    "lib/raxol/agent.ex",
    "lib/raxol/agent/session.ex",
    "lib/raxol/core/runtime/command.ex",
    "lib/raxol/ui/components/base/component.ex"
  ]

  @impl true
  def init(_ctx) do
    %{
      files: @files,
      current_file: nil,
      output: "",
      findings: [],
      status: :idle,
      history: [],
      error: nil
    }
  end

  @impl true
  def update({:agent_message, _from, :start}, model) do
    analyze_next(%{model | status: :starting})
  end

  def update({:agent_message, _from, :next}, model) do
    analyze_next(%{model | output: ""})
  end

  def update({:agent_message, _from, {:user_question, question}}, model) do
    messages = model.history ++ [%{role: :user, content: question}]

    {%{model | status: :thinking, output: "", history: messages},
     [call_backend(messages)]}
  end

  # Streaming: each {:chunk, text} appends to the output buffer.
  # The dashboard polls this model to show incremental rendering.
  def update({:command_result, {:chunk, text}}, model) do
    {%{model | output: model.output <> text, status: :streaming}, []}
  end

  # {:done, response} signals the stream is complete. response contains
  # the full content, usage stats, and provider metadata.
  def update({:command_result, {:done, response}}, model) do
    finding = %{
      file: model.current_file || "question",
      analysis: model.output,
      usage: response.usage
    }

    history = model.history ++ [%{role: :assistant, content: model.output}]

    {%{
       model
       | findings: [finding | model.findings],
         status: :done,
         history: history
     }, [Directive.send_agent(:summarizer, {:finding, finding})]}
  end

  def update({:command_result, {:error, reason}}, model) do
    {%{model | status: :error, error: inspect(reason)}, []}
  end

  def update(_msg, model), do: {model, []}

  defp analyze_next(%{files: []} = model) do
    {%{model | status: :all_done, current_file: nil}, []}
  end

  defp analyze_next(%{files: [file | rest]} = model) do
    case File.read(file) do
      {:ok, content} ->
        prompt = """
        Analyze this Elixir source file concisely:
        1. Purpose (1 sentence)
        2. Key patterns used
        3. One strength
        4. One improvement suggestion

        File: #{file}
        ```elixir
        #{String.slice(content, 0, 3000)}
        ```
        """

        messages = [
          %{
            role: :system,
            content:
              "Expert Elixir developer. Be concise, specific, plain text."
          },
          %{role: :user, content: prompt}
        ]

        {%{
           model
           | files: rest,
             current_file: file,
             status: :analyzing,
             output: "",
             history: messages
         }, [call_backend(messages)]}

      {:error, reason} ->
        analyze_next(%{
          model
          | files: rest,
            current_file: file,
            error: "Can't read: #{reason}"
        })
    end
  end

  defp stream_with_backend(backend, messages, opts, sender) do
    case backend.stream(messages, opts) do
      {:ok, stream} ->
        Enum.each(stream, fn event -> sender.(event) end)

      {:error, _} ->
        case backend.complete(messages, opts) do
          {:ok, resp} ->
            sender.({:chunk, resp.content})
            sender.({:done, resp})

          {:error, reason} ->
            sender.({:error, reason})
        end
    end
  end

  defp call_backend(messages) do
    Directive.async(fn sender ->
      case AICockpit.Config.detect_backend() do
        {:http, opts} ->
          stream_with_backend(Raxol.Agent.Backend.HTTP, messages, opts, sender)

        {:lumo, opts} ->
          stream_with_backend(Raxol.Agent.Backend.Lumo, messages, opts, sender)

        {:mock, _} ->
          AICockpit.MockStream.stream_response(
            List.last(messages).content,
            sender
          )
      end
    end)
  end
end

# -- Summarizer Agent ---------------------------------------------------------

defmodule AICockpit.Summarizer do
  @moduledoc false
  use Raxol.Agent

  @impl true
  def init(_ctx) do
    %{findings: [], summary: "Waiting for analyst...", status: :idle}
  end

  @impl true
  def update({:agent_message, _from, {:finding, finding}}, model) do
    findings = [finding | model.findings]

    summary =
      findings
      |> Enum.reverse()
      |> Enum.map_join("\n\n", fn f ->
        header = String.pad_trailing("-- #{Path.basename(f.file)} ", 35, "-")
        "#{header}\n#{String.slice(f.analysis, 0, 300)}"
      end)

    {%{model | findings: findings, summary: summary, status: :updated}, []}
  end

  def update(_msg, model), do: {model, []}
end

# -- Dashboard ----------------------------------------------------------------

defmodule AICockpit.Dashboard do
  @moduledoc false
  use Raxol.Core.Runtime.Application

  @impl true
  def init(_ctx) do
    backend = AICockpit.Config.detect_backend()

    %{
      tick: 0,
      analyst: nil,
      summarizer: nil,
      events: [
        {0, :boot,
         "Cockpit online (#{AICockpit.Config.backend_label(backend)})"}
      ],
      takeover: false,
      input_buffer: "",
      start_time: System.monotonic_time(:second),
      panel: :analyst,
      backend: backend
    }
  end

  @impl true
  def subscribe(_model), do: [subscribe_interval(200, :tick)]

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        {poll_agents(%{model | tick: model.tick + 1}), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}}
      when not model.takeover ->
        {model, [command(:quit)]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [command(:quit)]}

      # Next file
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "n"}}
      when not model.takeover ->
        Raxol.Agent.Session.send_message(:analyst, :next)
        {add_event(model, :pilot, "Requested next file"), []}

      # Takeover
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "t"}}
      when not model.takeover ->
        {add_event(
           %{model | takeover: true, input_buffer: ""},
           :pilot,
           "Takeover: type question, Enter to send"
         ), []}

      # Release
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "r"}}
      when model.takeover ->
        {add_event(
           %{model | takeover: false, input_buffer: ""},
           :pilot,
           "Released"
         ), []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :escape}}
      when model.takeover ->
        {add_event(
           %{model | takeover: false, input_buffer: ""},
           :pilot,
           "Released"
         ), []}

      # Send question
      %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}}
      when model.takeover and model.input_buffer != "" ->
        Raxol.Agent.Session.send_message(
          :analyst,
          {:user_question, model.input_buffer}
        )

        q = String.slice(model.input_buffer, 0, 50)

        {add_event(
           %{model | takeover: false, input_buffer: ""},
           :pilot,
           "Asked: #{q}"
         ), []}

      # Typing in takeover
      %Raxol.Core.Events.Event{type: :key, data: %{key: :backspace}}
      when model.takeover ->
        {%{model | input_buffer: String.slice(model.input_buffer, 0..-2//1)},
         []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: ch}}
      when model.takeover and is_binary(ch) ->
        if String.printable?(ch) do
          {%{model | input_buffer: model.input_buffer <> ch}, []}
        else
          {model, []}
        end

      # Panel switch
      %Raxol.Core.Events.Event{type: :key, data: %{key: :tab}} ->
        next = if model.panel == :analyst, do: :summary, else: :analyst
        {%{model | panel: next}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 0, gap: 0} do
      [
        header_bar(model),
        spacer(size: 1),
        row style: %{gap: 1} do
          [analyst_panel(model), summary_panel(model)]
        end,
        spacer(size: 1),
        event_log(model),
        key_bar(model)
      ]
    end
  end

  # -- Header -----------------------------------------------------------------

  defp header_bar(model) do
    elapsed = System.monotonic_time(:second) - model.start_time
    status = if model.takeover, do: "TAKEOVER", else: "#{elapsed}s"
    status_fg = if model.takeover, do: :yellow, else: :cyan

    box style: %{border: :double, width: :fill, padding: 0} do
      row style: %{gap: 1, justify_content: :space_between} do
        [
          text("  AI COCKPIT", style: [:bold], fg: :cyan),
          text(AICockpit.Config.backend_label(model.backend), style: [:dim]),
          text(status, style: [:bold], fg: status_fg)
        ]
      end
    end
  end

  # -- Analyst Panel ----------------------------------------------------------

  defp analyst_panel(model) do
    m = model.analyst
    active = model.panel == :analyst

    {title, title_fg, rows} =
      if m do
        file_label =
          case m.current_file do
            nil -> "idle"
            f -> Path.basename(f)
          end

        status_fg =
          case m.status do
            s when s in [:streaming, :analyzing] -> :green
            :done -> :cyan
            :all_done -> :cyan
            :error -> :red
            _ -> :white
          end

        lines =
          m.output
          |> String.split("\n")
          |> Enum.take(16)
          |> Enum.map(fn line ->
            text(String.slice(line, 0, 46))
          end)

        cursor =
          if m.status == :streaming, do: [text("_", fg: :green)], else: []

        content =
          case lines do
            [] -> [text("  Waiting...", style: [:dim])]
            _ -> lines ++ cursor
          end

        {"Analyst: #{file_label} (#{m.status})", status_fg, content}
      else
        {"Analyst", :white, [text("  Starting...", style: [:dim])]}
      end

    box style: %{
          border: if(active, do: :double, else: :single),
          width: 50,
          padding: 1
        } do
      column style: %{gap: 0} do
        [text(title, style: [:bold], fg: title_fg), divider(char: "-") | rows]
      end
    end
  end

  # -- Summary Panel ----------------------------------------------------------

  defp summary_panel(model) do
    m = model.summarizer
    active = model.panel == :summary

    count = if m, do: length(m.findings), else: 0

    rows =
      if m && m.summary != "" do
        m.summary
        |> String.split("\n")
        |> Enum.take(16)
        |> Enum.map(fn line ->
          text(String.slice(line, 0, 40))
        end)
      else
        [text("  Waiting for findings...", style: [:dim])]
      end

    box style: %{
          border: if(active, do: :double, else: :single),
          width: 44,
          padding: 1
        } do
      column style: %{gap: 0} do
        [
          text("Summary (#{count} files)", style: [:bold], fg: :cyan),
          divider(char: "-")
          | rows
        ]
      end
    end
  end

  # -- Event Log --------------------------------------------------------------

  defp event_log(model) do
    input_row =
      if model.takeover do
        [text("> #{model.input_buffer}_", fg: :yellow, style: [:bold])]
      else
        []
      end

    entries =
      model.events
      |> Enum.take(6)
      |> Enum.map(fn {elapsed, tag, msg} ->
        {tag_str, tag_fg} =
          case tag do
            :boot -> {"boot", :cyan}
            :agent -> {"agent", :green}
            :pilot -> {"pilot", :yellow}
            :ai -> {"ai", :magenta}
            :error -> {"err", :red}
          end

        row style: %{gap: 1} do
          [
            text(String.pad_leading("#{elapsed}s", 4), style: [:dim]),
            text("[#{tag_str}]", fg: tag_fg),
            text(String.slice(msg, 0, 70))
          ]
        end
      end)

    box style: %{border: :single, width: :fill, padding: 1} do
      column style: %{gap: 0} do
        [text("Event Log", style: [:bold], fg: :cyan), divider(char: "-")] ++
          input_row ++ entries
      end
    end
  end

  # -- Key Bar ----------------------------------------------------------------

  defp key_bar(model) do
    if model.takeover do
      row style: %{gap: 2} do
        [
          text(" Type question", style: [:bold], fg: :yellow),
          text("Enter", style: [:bold], fg: :magenta),
          text("send", style: [:dim]),
          text("Esc", style: [:bold], fg: :magenta),
          text("cancel", style: [:dim])
        ]
      end
    else
      row style: %{gap: 2} do
        [
          text(" n", style: [:bold], fg: :magenta),
          text("next", style: [:dim]),
          text("t", style: [:bold], fg: :magenta),
          text("takeover", style: [:dim]),
          text("Tab", style: [:bold], fg: :magenta),
          text("panel", style: [:dim]),
          text("q", style: [:bold], fg: :magenta),
          text("quit", style: [:dim])
        ]
      end
    end
  end

  # -- Helpers ----------------------------------------------------------------

  defp poll_agents(model) do
    analyst =
      case Raxol.Agent.Session.get_model(:analyst) do
        {:ok, m} -> m
        _ -> nil
      end

    summarizer =
      case Raxol.Agent.Session.get_model(:summarizer) do
        {:ok, m} -> m
        _ -> nil
      end

    model = %{model | analyst: analyst, summarizer: summarizer}

    # Detect status transitions for event log
    cond do
      analyst && analyst.status == :analyzing &&
          (model.analyst == nil ||
             get_in_safe(model, :analyst, :status) != :analyzing) ->
        add_event(
          model,
          :agent,
          "Analyzing #{Path.basename(analyst.current_file || "")}"
        )

      analyst && analyst.status == :streaming &&
          get_in_safe(model, :analyst, :status) != :streaming ->
        add_event(model, :ai, "Streaming response...")

      analyst && analyst.status == :done &&
          get_in_safe(model, :analyst, :status) != :done ->
        tokens = get_in(analyst, [:findings, Access.at(0), :usage]) || %{}
        out = tokens["output_tokens"] || "?"
        add_event(model, :agent, "Complete (#{out} tokens)")

      analyst && analyst.status == :all_done &&
          get_in_safe(model, :analyst, :status) != :all_done ->
        add_event(model, :agent, "All files analyzed")

      analyst && analyst.status == :error &&
          get_in_safe(model, :analyst, :status) != :error ->
        add_event(model, :error, analyst.error || "unknown error")

      true ->
        model
    end
  end

  defp get_in_safe(model, key, field) do
    case Map.get(model, key) do
      nil -> nil
      m -> Map.get(m, field)
    end
  end

  defp add_event(model, tag, msg) do
    elapsed = System.monotonic_time(:second) - model.start_time
    %{model | events: Enum.take([{elapsed, tag, msg} | model.events], 20)}
  end
end

# -- Boot ---------------------------------------------------------------------
# Architecture: two headless agents (analyst, summarizer) + one TEA dashboard.
# The dashboard polls agent models every 200ms for display. Agents communicate
# via Directive.send_agent -- when the analyst finishes a file, it sends the
# finding to the summarizer.

# Ensure agent registry
case Registry.start_link(keys: :unique, name: Raxol.Agent.Registry) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

# Start agents (headless TEA apps)
{:ok, _} =
  Raxol.Agent.Session.start_link(app_module: AICockpit.Analyst, id: :analyst)

{:ok, _} =
  Raxol.Agent.Session.start_link(
    app_module: AICockpit.Summarizer,
    id: :summarizer
  )

# Give agents time to initialize
Process.sleep(200)

# Kick off the first analysis
Raxol.Agent.Session.send_message(:analyst, :start)

# Start the dashboard (renders to terminal)
{:ok, pid} = Raxol.start_link(AICockpit.Dashboard, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
