# Capture OMP protocol fixtures (ADR-0042, TODO "Fixtures").
#
#   elixir scripts/omp_fixtures/capture.exs f1 [--with-model] [--write]
#
# Runs the pinned `omp` (`omp --version` must equal the pin in
# `Raxol.Agent.OMP.Version`) in a `mktemp -d` cwd with `--no-rules --no-skills
# --no-extensions`. No-model scenarios use the isolated `--profile
# raxol-fixtures`, which holds no credentials. `--with-model` adds the
# scenarios that call the pinned `@smol` model (`max_tokens` <= 64); those run
# on the default profile, because the fixture profile has no credentials and
# copying an OAuth credential into it would fork a rotating refresh token.
#
# Every transcript is scrubbed (scrub_version below), headed with
# `{omp_version, command, scrub_version}`, scanned with `gitleaks detect`
# (required) and diffed against the committed fixtures. `--write` replaces the
# committed files with the capture.
#
# Transcript format (JSONL): line 1 is the header; then `{"in": line}` for a
# line written to the gateway's stdin, `{"out": line}` for a line it printed
# (in the order printed), and a final `{"exit": status}` after stdin EOF. Lines
# are strings so a consumer decodes the same bytes the gateway sent.

defmodule OmpFixtures.Capture do
  @repo Path.expand("../..", __DIR__)
  @scrub_version 1
  @smol "anthropic/claude-haiku-5-5"
  @max_model_tokens 64
  @isolation ["--no-rules", "--no-skills", "--no-extensions"]
  @fixture_profile ["--profile", "raxol-fixtures"]
  @gateway ["auth-gateway", "stdio"]

  @targets %{
    "f1" => "packages/raxol_agent/test/fixtures/omp/gateway"
  }

  def main(argv) do
    {flags, targets} = Enum.split_with(argv, &String.starts_with?(&1, "--"))
    with_model? = "--with-model" in flags
    write? = "--write" in flags

    unknown = flags -- ["--with-model", "--write"]
    if unknown != [], do: fail("unknown flags: #{Enum.join(unknown, " ")}")
    if targets == [], do: fail("usage: capture.exs f1 [--with-model] [--write]")

    omp = System.find_executable("omp") || fail("omp is not on PATH")
    version = check_pin!(omp)
    tmp = mktemp!()

    try do
      Enum.each(targets, &capture(&1, omp, version, tmp, with_model?, write?))
    after
      File.rm_rf!(tmp)
    end
  end

  defp capture(target, omp, version, tmp, with_model?, write?) do
    dir = Map.get(@targets, target) || fail("unknown target #{target}")
    out = Path.join(tmp, "out/#{target}")
    File.mkdir_p!(out)

    for {name, profile, requests} <- scenarios(target, with_model?) do
      transcript = run(omp, version, tmp, profile, requests)
      if name == "out_of_order", do: check_out_of_order!(transcript)
      File.write!(Path.join(out, "#{name}.jsonl"), transcript)
      IO.puts("captured #{target}/#{name}")
    end

    gitleaks!(out)
    committed = Path.join(@repo, dir)
    diff(committed, out)

    if write? do
      File.mkdir_p!(committed)
      for file <- File.ls!(out), do: File.cp!(Path.join(out, file), Path.join(committed, file))
      IO.puts("wrote #{dir}")
    end
  end

  # F1: `omp auth-gateway stdio`.
  defp scenarios("f1", with_model?) do
    no_model = [
      {"no_model", @fixture_profile,
       [
         %{"id" => 1, "method" => "GET", "path" => "/v1/models"},
         "not json",
         %{"id" => 3, "method" => "GET"},
         %{
           "id" => 4,
           "method" => "POST",
           "path" => "/v1/messages",
           "body" => messages("nope/does-not-exist", 16, "hi")
         },
         %{"id" => 5, "method" => "GET", "path" => "/nope"}
       ]}
    ]

    model = [
      {"messages_text", [],
       [
         %{
           "id" => 1,
           "method" => "POST",
           "path" => "/v1/messages",
           "body" => messages(@smol, 16, "Reply with the single word pong.")
         }
       ]},
      {"messages_tool_use", [],
       [
         %{
           "id" => 1,
           "method" => "POST",
           "path" => "/v1/messages",
           "body" =>
             @smol
             |> messages(@max_model_tokens, "Call get_weather for Paris.")
             |> Map.put("tools", [weather_tool()])
         }
       ]},
      # A slow model call, then a request the gateway answers locally: the
      # replies come back in completion order, the second request first.
      {"out_of_order", [],
       [
         %{
           "id" => 1,
           "method" => "POST",
           "path" => "/v1/messages",
           "body" =>
             messages(@smol, @max_model_tokens, "Count from 1 to 30, separated by spaces.")
         },
         %{"id" => 2, "method" => "GET", "path" => "/nope"}
       ]}
    ]

    if with_model?, do: no_model ++ model, else: no_model
  end

  defp messages(model, max_tokens, text) do
    if model == @smol and max_tokens > @max_model_tokens,
      do: fail("max_tokens #{max_tokens} exceeds #{@max_model_tokens}")

    %{
      "model" => model,
      "max_tokens" => max_tokens,
      "messages" => [%{"role" => "user", "content" => text}],
      "stream" => false
    }
  end

  defp weather_tool do
    %{
      "name" => "get_weather",
      "description" => "Current weather for a city.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      }
    }
  end

  defp run(omp, version, tmp, profile, requests) do
    args = profile ++ @isolation ++ @gateway
    lines = Enum.map(requests, fn r -> if is_binary(r), do: r, else: JSON.encode!(r) end)
    input = Path.join(tmp, "requests")
    File.write!(input, Enum.map(lines, &[&1, ?\n]))

    {stdout, status} =
      System.cmd("/bin/sh", ["-c", ~s(exec "$0" "$@" < "#{input}"), omp | args], cd: tmp)

    outs = String.split(stdout, "\n", trim: true)
    if status != 0, do: fail("omp exited #{status}")

    header = %{
      "omp_version" => version,
      "command" => Enum.join(["omp" | args], " "),
      "scrub_version" => @scrub_version
    }

    # The gateway prints its ready line before it reads stdin, so it leads the
    # exchange; every later line answers a request.
    {[ready | replies], _seen} = Enum.map_reduce(outs, %{}, &scrub_line(&1, &2, tmp))

    [
      JSON.encode!(header),
      JSON.encode!(%{"out" => ready}),
      Enum.map(lines, &JSON.encode!(%{"in" => &1})),
      Enum.map(replies, &JSON.encode!(%{"out" => &1})),
      JSON.encode!(%{"exit" => status})
    ]
    |> List.flatten()
    |> Enum.map(&[&1, ?\n])
  end

  # -- scrub ------------------------------------------------------------------

  defp scrub_line(line, seen, tmp) do
    decoded = JSON.decode!(line)
    {scrubbed, seen} = scrub(decoded, seen, tmp)
    if scrubbed == decoded, do: {line, seen}, else: {JSON.encode!(scrubbed), seen}
  end

  defp scrub(map, seen, tmp) when is_map(map) do
    {pairs, seen} =
      Enum.map_reduce(map, seen, fn
        {"systemPrompt", _value}, seen -> {{"systemPrompt", "<systemPrompt>"}, seen}
        {key, value}, seen when is_integer(value) -> {{key, scrub_number(key, value)}, seen}
        {key, value}, seen -> scrub(value, seen, tmp) |> then(fn {v, s} -> {{key, v}, s} end)
      end)

    {Map.new(pairs), seen}
  end

  defp scrub(list, seen, tmp) when is_list(list),
    do: Enum.map_reduce(list, seen, &scrub(&1, &2, tmp))

  defp scrub(string, seen, tmp) when is_binary(string), do: scrub_string(string, seen, tmp)
  defp scrub(other, seen, _tmp), do: {other, seen}

  defp scrub_number(key, value) do
    if String.match?(key, ~r/time|created|updated/i), do: 0, else: value
  end

  @placeholders [
    {~r/msg_[A-Za-z0-9]+/, "msg_"},
    {~r/toolu_[A-Za-z0-9_]+/, "toolu_"},
    {~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i, "uuid-"}
  ]

  defp scrub_string(string, seen, tmp) do
    string =
      string
      |> String.replace(~r/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, "user@example.com")
      |> String.replace("/private" <> tmp, "/WORKSPACE")
      |> String.replace(tmp, "/WORKSPACE")
      |> String.replace(System.user_home!(), "/WORKSPACE")

    Enum.reduce(@placeholders, {string, seen}, fn {regex, prefix}, {string, seen} ->
      Regex.scan(regex, string)
      |> Enum.map(&hd/1)
      |> Enum.reduce({string, seen}, fn original, {string, seen} ->
        {stable, seen} = stable(original, prefix, seen)
        {String.replace(string, original, stable), seen}
      end)
    end)
  end

  # Numbered in order of first appearance, so a re-capture of the same
  # exchange scrubs to the same bytes.
  defp stable(original, prefix, seen) do
    case Map.fetch(seen, original) do
      {:ok, stable} ->
        {stable, seen}

      :error ->
        n = seen |> Map.values() |> Enum.count(&String.starts_with?(&1, prefix)) |> Kernel.+(1)
        stable = prefix <> "SCRUBBED" <> String.pad_leading(Integer.to_string(n), 4, "0")
        {stable, Map.put(seen, original, stable)}
    end
  end

  # -- checks -----------------------------------------------------------------

  defp check_pin!(omp) do
    source = File.read!(Path.join(@repo, "packages/raxol_agent/lib/raxol/agent/omp/version.ex"))
    [_, pin] = Regex.run(~r/@tested "([^"]+)"/, source)
    {out, 0} = System.cmd(omp, ["--version"])

    case String.trim(out) do
      "omp/" <> ^pin -> pin
      other -> fail("omp --version is #{other}, the pin is omp/#{pin}")
    end
  end

  defp check_out_of_order!(transcript) do
    ids =
      for line <- transcript,
          %{"out" => out} <- [line |> IO.iodata_to_binary() |> JSON.decode!()],
          %{"id" => id} <- [JSON.decode!(out)],
          is_integer(id),
          do: id

    if ids != [2, 1], do: fail("out_of_order replies came back as #{inspect(ids)}, not [2, 1]")
  end

  defp gitleaks!(dir) do
    gitleaks = System.find_executable("gitleaks") || fail("gitleaks is required")
    args = ["detect", "--no-git", "--source", dir, "--redact", "--no-banner", "--exit-code", "1"]

    case System.cmd(gitleaks, args, stderr_to_stdout: true) do
      {_out, 0} -> IO.puts("gitleaks: no leaks in #{dir}")
      {out, _} -> fail("gitleaks found leaks:\n#{out}")
    end
  end

  defp diff(committed, out) do
    for file <- out |> File.ls!() |> Enum.sort() do
      existing = Path.join(committed, file)

      if File.exists?(existing) do
        {text, status} = System.cmd("diff", ["-u", existing, Path.join(out, file)])
        IO.puts(if status == 0, do: "unchanged #{file}", else: text)
      else
        IO.puts("new #{file}")
      end
    end
  end

  defp mktemp! do
    {out, 0} = System.cmd("mktemp", ["-d"])
    out |> String.trim() |> Path.expand()
  end

  defp fail(message) do
    IO.puts(:stderr, "capture.exs: #{message}")
    System.halt(1)
  end
end

OmpFixtures.Capture.main(System.argv())
