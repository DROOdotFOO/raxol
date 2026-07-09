defmodule RaxolAgent do
  @moduledoc """
  AI agent framework for Elixir built on OTP.

  Agents follow The Elm Architecture (TEA): `init/1`, `update/2`, and
  optionally `view/1`. Each agent runs as a supervised OTP process with
  crash isolation, inter-agent messaging, and team coordination.

  ## Quick Start

      defmodule MyAgent do
        use Raxol.Agent

        def init(_ctx), do: %{findings: []}

        def update({:agent_message, _from, {:analyze, file}}, model) do
          {model, [shell("wc -l \#{file}")]}
        end

        def update({:command_result, {:shell_result, %{output: out}}}, model) do
          {%{model | findings: [out | model.findings]}, []}
        end
      end

      {:ok, _} = Raxol.Agent.Session.start_link(app_module: MyAgent, id: :my_agent)
      Raxol.Agent.Session.send_message(:my_agent, {:analyze, "lib/raxol.ex"})

  ## Features

  - **TEA-based agents** -- `init/update/view` with OTP supervision
  - **Agent teams** -- Supervisor-based coordinator/worker groups
  - **Inter-agent messaging** -- Registry-routed messages via `Agent.Comm`
  - **Real SSE streaming** -- Anthropic, OpenAI, Ollama, Kimi, LLM7, OpenRouter, Lumo
  - **Shell commands** -- Port-based execution with result callbacks
  - **Headless mode** -- `view/1` is optional; skip rendering entirely

  ## Documentation

  See the [Agent Framework guide](https://hexdocs.pm/raxol_agent/readme.html).
  """

  @doc """
  Returns the version of RaxolAgent.
  """
  def version, do: unquote(Mix.Project.config()[:version])
end
