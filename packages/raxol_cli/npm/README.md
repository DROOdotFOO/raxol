# raxol

Interactive AI agent and TUI toolkit in your terminal, as a self-contained binary.

```bash
npm install -g raxol
raxol            # interactive AI agent
raxol playground # component catalog
raxol new my_app # scaffold an app
raxol help
```

Set `AI_API_KEY` (or a provider key like `ANTHROPIC_API_KEY`) for the agent;
without one it replies with mock output. Binaries live in `vendor/` (built by CI
per platform via `scripts/pack.sh`).
