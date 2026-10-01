# Changelog

## 0.1.0 - Unreleased

- Add the standalone package and its fail-closed policy workflow. Policy files are parsed as bounded data rather than evaluated as Elixir, initialization publishes a complete file atomically without replacing an existing destination, and prompting is available only in interactive terminals (with deterministic process-shell coverage). Decimal 3 avoids EEF-CVE-2026-32686.
