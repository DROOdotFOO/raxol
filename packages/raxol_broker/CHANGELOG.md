# Changelog

## 0.1.0 - Unreleased

- Add the standalone package and its fail-closed policy workflow. Policy files are parsed as bounded data rather than evaluated as Elixir, initialization publishes a complete file atomically without replacing an existing destination, and prompting is available only in interactive terminals (with deterministic process-shell coverage). Decimal 3 avoids EEF-CVE-2026-32686.
- `Raxol.Broker.PolicyFile.new/2` builds the complete restrictive policy from the two required caps; `mix raxol.broker.init` uses it. Terminal prompts accept the trimmed entered line, and EOF raises `Mix.Error` without writing. The staging file is created with mode 0600 before it is written, so the published policy is mode 0600.
- `PolicyFile.load/1` rejects symlinks and files that `Raxol.Agent.OperatorFile.trusted?/1` refuses (owner, mode, or parent directory) with `{:error, {:untrusted_file, path, reason}}`, returns `{:error, {:parse_error, path, :invalid_utf8}}` for invalid UTF-8, and limits `ask_timeout` to 1..4_294_967_295 ms.
