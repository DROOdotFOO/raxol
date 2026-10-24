# Capture OMP protocol fixtures (ADR-0042, TODO "Fixtures").
#
#   elixir scripts/omp_fixtures/capture.exs f1|f3 [--with-model] [--write]
#   elixir scripts/omp_fixtures/capture.exs f1|f3 --rescrub [--write]
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
# committed files with the capture. `--rescrub` runs no `omp` at all: it
# applies the current scrub to the committed transcripts (both `in` and `out`
# lines) and stamps them with the current scrub_version, so a scrub rule added
# later reaches fixtures that cost a model call without recapturing them.
#
# Transcript format (JSONL): line 1 is the header; then `{"in": line}` for a
# line written to omp's stdin, `{"out": line}` for a line it printed (in the
# order printed), and a final `{"exit": status}` after stdin EOF. Lines are
# strings so a consumer decodes the same bytes omp sent.
#
# F3 (`omp --mode rpc`) is driven interactively, as `Raxol.Agent.OMP.RPC`
# drives it: `negotiate_protocol` v2 (id `negotiate`) right after the ready
# frame, then commands with ids "1", "2", ... in order, every approval select
# answered `Deny` and every other dialog cancelled. stdin is a FIFO, so it can
# be closed while stdout is still read. The no-model scenarios pass `--model
# @smol` to the credential-less fixture profile (a profile with no model exits
# 1 before its ready frame), with every credential-looking variable removed
# from omp's environment, so a prompt fails before it reaches a model.

defmodule OmpFixtures.Capture do
  @repo Path.expand("../..", __DIR__)
  # 2: also zeroes `completedAt`, `duration`, `ttft` and `credentialId`, and
  # numbers `extension_ui_request`/`extension_ui_response` ids.
  @scrub_version 2
  @smol "anthropic/claude-haiku-5-5"
  @max_model_tokens 64
  @isolation ["--no-rules", "--no-skills", "--no-extensions"]
  @fixture_profile ["--profile", "raxol-fixtures"]
  @gateway ["auth-gateway", "stdio"]
  @rpc ["--mode", "rpc", "--approval-mode", "write"]
  @rpc_line_bytes 2_097_152
  @rpc_step_ms 120_000
  @frame_bytes 1_048_576
  @ui_frames ["extension_ui_request", "extension_ui_response"]

  @targets %{
    "f1" => "packages/raxol_agent/test/fixtures/omp/gateway",
    "f3" => "packages/raxol_agent/test/fixtures/omp/rpc"
  }

  def main(argv) do
    {flags, targets} = Enum.split_with(argv, &String.starts_with?(&1, "--"))
    with_model? = "--with-model" in flags
    write? = "--write" in flags

    unknown = flags -- ["--with-model", "--write", "--rescrub"]
    if unknown != [], do: fail("unknown flags: #{Enum.join(unknown, " ")}")

    if targets == [],
      do: fail("usage: capture.exs f1|f3 [--with-model | --rescrub] [--write]")

    if "--rescrub" in flags do
      if with_model?, do: fail("--rescrub makes no capture, with or without a model")
      tmp = mktemp!()

      try do
        Enum.each(targets, &rescrub(&1, tmp, write?))
      after
        File.rm_rf!(tmp)
      end
    else
      capture_all(targets, with_model?, write?)
    end
  end

  defp capture_all(targets, with_model?, write?) do
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
      transcript =
        case requests do
          {:rpc, steps} -> run_rpc(omp, version, tmp, profile, steps)
          requests -> run(omp, version, tmp, profile, requests)
        end

      if name == "out_of_order", do: check_out_of_order!(transcript)
      File.write!(Path.join(out, "#{name}.jsonl"), transcript)
      IO.puts("captured #{target}/#{name}")
    end

    publish(out, dir, write?)
  end

  defp publish(out, dir, write?) do
    gitleaks!(out)
    committed = Path.join(@repo, dir)
    diff(committed, out)

    if write? do
      File.mkdir_p!(committed)
      for file <- File.ls!(out), do: File.cp!(Path.join(out, file), Path.join(committed, file))
      IO.puts("wrote #{dir}")
    end
  end

  # The committed transcripts, scrubbed again with the current rules.
  defp rescrub(target, tmp, write?) do
    dir = Map.get(@targets, target) || fail("unknown target #{target}")
    committed = Path.join(@repo, dir)
    out = Path.join(tmp, "out/#{target}")
    File.mkdir_p!(out)

    for file <- committed |> File.ls!() |> Enum.sort(), Path.extname(file) == ".jsonl" do
      [header | events] =
        committed |> Path.join(file) |> File.read!() |> String.split("\n", trim: true)

      header = header |> JSON.decode!() |> Map.put("scrub_version", @scrub_version)

      {events, _seen} =
        Enum.map_reduce(events, %{}, fn line, seen ->
          case JSON.decode!(line) do
            %{"out" => out} -> scrub_event("out", out, seen, tmp)
            # F1 records deliberately malformed requests; they stay as sent.
            %{"in" => "{" <> _ = line} -> scrub_event("in", line, seen, tmp)
            event -> {event, seen}
          end
        end)

      File.write!(Path.join(out, file), Enum.map([header | events], &[JSON.encode!(&1), ?\n]))
    end

    publish(out, dir, write?)
  end

  defp scrub_event(key, line, seen, tmp) do
    {line, seen} = scrub_line(line, seen, tmp)
    {%{key => line}, seen}
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

  # F3: `omp --mode rpc`. The no-model scenarios run on the fixture profile,
  # whose prompt fails before it reaches a model ("No API key").
  defp scenarios("f3", with_model?) do
    no_model_args = @fixture_profile ++ ["--model", @smol, "--no-session"]

    no_model = [
      {"handshake", no_model_args,
       {:rpc,
        for type <- ~w(get_state get_available_models get_available_commands
                      get_available_thinking_levels) do
          {:request, %{"type" => type}}
        end}},
      # `bash` answers when its command finishes, after a later command, and
      # the `set_todos` reply (its phases echoed back) is just over OMP's
      # 1 MiB frame limit, so it arrives as `rpc_chunk` lines.
      {"chunked_out_of_order", no_model_args,
       {:rpc,
        [
          {:send, [%{"type" => "bash", "command" => "sleep 1; echo done"}, big_todos("2")]},
          {:await_responses, ["2", "1"]}
        ]}},
      # Admitted, then refused before the agent ran: OMP sends a second,
      # failed response with the same id and a `prompt_result` with
      # `agentInvoked: false`, and no `session_settled`.
      {"unreached_prompt", no_model_args,
       {:rpc,
        [
          {:send, [%{"type" => "prompt", "message" => "hi"}]},
          {:await, &match?(%{"type" => "prompt_result", "id" => "1"}, &1)}
        ]}}
    ]

    model = [
      # One turn: the model calls `bash`, an exec-tier tool under
      # `--approval-mode write`, OMP asks over the wire, the answer is Deny,
      # and the model replies to the refusal. `cap.ts` caps every request at
      # @max_model_tokens output tokens; the overlay turns intent tracing off
      # so the tool call fits.
      {"approval",
       [
         "--model",
         @smol,
         "--thinking",
         "off",
         "--tools",
         "bash",
         "--no-session",
         "-e",
         "cap.ts",
         "--config",
         "overlay.yml"
       ],
       {:rpc,
        [
          {:send,
           [
             %{
               "type" => "prompt",
               "message" => "Use the bash tool to run `echo raxol`. Do not write any text."
             }
           ]},
          {:await, &match?(%{"type" => "session_settled"}, &1)},
          {:expect_approvals, 1}
        ]}}
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

  # A `set_todos` command whose line, with id `id`, is exactly OMP's 1 MiB
  # frame limit, newline included; the response echoing it is larger.
  defp big_todos(id) do
    command = fn content ->
      %{
        "type" => "set_todos",
        "phases" => [
          %{"name" => "Todos", "tasks" => [%{"content" => content, "status" => "pending"}]}
        ]
      }
    end

    overhead = byte_size(JSON.encode!(Map.put(command.(""), "id", id))) + 1
    command.(String.duplicate("x", @frame_bytes - overhead))
  end

  @cap_ts """
  export default function (pi) {
    pi.on("before_provider_request", (event) => {
      const { thinking, ...payload } = event.payload;
      return { ...payload, max_tokens: Math.min(payload.max_tokens ?? #{@max_model_tokens}, #{@max_model_tokens}) };
    });
  }
  """

  @overlay_yml """
  tools:
    intentTracing: false
  """

  defp run_rpc(omp, version, tmp, profile, steps) do
    File.write!(Path.join(tmp, "cap.ts"), @cap_ts)
    File.write!(Path.join(tmp, "overlay.yml"), @overlay_yml)
    fifo = Path.join(tmp, "rpc-stdin")
    File.rm(fifo)
    {_, 0} = System.cmd("mkfifo", [fifo])

    args = profile ++ @isolation ++ @rpc
    no_model? = "raxol-fixtures" in profile

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        {:line, @rpc_line_bytes},
        {:cd, tmp},
        {:env, if(no_model?, do: credential_env(), else: [])},
        # omp never sees EOF on a FIFO stdin (observed), but `cat` does, and
        # then closes the pipe omp reads.
        {:args, ["-c", ~s(cat < "#{fifo}" | "$0" "$@"), omp | args]}
      ])

    # Blocks until `cat` opens the FIFO for reading.
    {:ok, writer} = File.open(fifo, [:write, :raw, :binary])

    rec = %{port: port, writer: writer, log: [], buffer: [], chunks: [], next: 1, approvals: 0}
    rec = await(rec, &match?(%{"type" => "ready"}, &1))

    rec =
      write(rec, %{"id" => "negotiate", "type" => "negotiate_protocol", "protocolVersion" => 2})

    rec = await(rec, &match?(%{"type" => "response", "id" => "negotiate", "success" => true}, &1))
    rec = Enum.reduce(steps, rec, &step/2)

    :ok = File.close(writer)
    {rec, status} = await_exit(rec)
    if status != 0, do: fail("omp exited #{status}")

    header = %{
      "omp_version" => version,
      "command" => Enum.join(["omp" | args], " "),
      "scrub_version" => @scrub_version
    }

    {events, _seen} =
      rec.log
      |> Enum.reverse()
      |> Enum.map_reduce(%{}, fn
        {:in, line}, seen -> scrub_event("in", line, seen, tmp)
        {:out, line}, seen -> scrub_event("out", line, seen, tmp)
      end)

    [header | events]
    |> Kernel.++([%{"exit" => status}])
    |> Enum.map(&[JSON.encode!(&1), ?\n])
  end

  # Unset in omp's environment for the no-model scenarios: nothing there may
  # give the fixture profile a credential.
  defp credential_env do
    for {name, _value} <- System.get_env(),
        String.match?(name, ~r/KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|BROKER/i),
        do: {String.to_charlist(name), false}
  end

  defp step({:request, command}, rec) do
    id = Integer.to_string(rec.next)
    rec = step({:send, [command]}, rec)
    await(rec, &match?(%{"type" => "response", "id" => ^id}, &1))
  end

  defp step({:send, commands}, rec) do
    Enum.reduce(commands, rec, fn command, rec ->
      id = Integer.to_string(rec.next)
      write(%{rec | next: rec.next + 1}, Map.put(command, "id", id))
    end)
  end

  defp step({:await, match}, rec), do: await(rec, match)

  defp step({:await_responses, ids}, rec) do
    {rec, seen} =
      Enum.reduce(ids, {rec, []}, fn _id, {rec, seen} ->
        rec = await(rec, &(&1["type"] == "response" and &1["id"] in ids and &1["id"] not in seen))
        {rec, seen ++ [rec.last["id"]]}
      end)

    if seen != ids, do: fail("responses came back as #{inspect(seen)}, not #{inspect(ids)}")
    rec
  end

  defp step({:expect_approvals, n}, rec) do
    if rec.approvals != n, do: fail("#{rec.approvals} approval(s) asked, expected #{n}")
    rec
  end

  defp write(rec, map) do
    line = JSON.encode!(map)
    :ok = :file.write(rec.writer, [line, ?\n])
    %{rec | log: [{:in, line} | rec.log]}
  end

  # Reads lines until a frame (chunk runs reassembled) satisfies `match`,
  # answering dialogs as `Raxol.Agent.OMP.RPC` would on the way.
  defp await(rec, match) do
    port = rec.port

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        await(%{rec | buffer: [rec.buffer | chunk]}, match)

      {^port, {:data, {:eol, chunk}}} ->
        line = IO.iodata_to_binary([rec.buffer | chunk])
        rec = %{rec | buffer: [], log: [{:out, line} | rec.log]}

        case frame(rec, JSON.decode!(line)) do
          {:more, rec} ->
            await(rec, match)

          {:frame, rec, frame} ->
            rec = rec |> Map.put(:last, frame) |> dialog(frame)
            if match.(frame), do: rec, else: await(rec, match)
        end

      {^port, {:exit_status, status}} ->
        fail("omp exited #{status} mid-scenario")
    after
      @rpc_step_ms -> fail("no matching frame within #{@rpc_step_ms} ms")
    end
  end

  defp frame(rec, %{"type" => "rpc_chunk", "index" => index, "count" => count, "data" => data}) do
    chunks = [rec.chunks | Base.decode64!(data)]

    if index == count - 1,
      do: {:frame, %{rec | chunks: []}, chunks |> IO.iodata_to_binary() |> JSON.decode!()},
      else: {:more, %{rec | chunks: chunks}}
  end

  defp frame(rec, frame), do: {:frame, rec, frame}

  defp dialog(rec, %{"type" => "extension_ui_request", "id" => id, "method" => method} = frame) do
    options = frame["options"] || []

    cond do
      method == "select" and List.last(options) == "Deny" and
          Enum.any?(options, &(&1 in ["Approve", "Approve Once"])) ->
        rec = write(rec, %{"type" => "extension_ui_response", "id" => id, "value" => "Deny"})
        %{rec | approvals: rec.approvals + 1}

      method in ~w(select confirm input editor ask) ->
        write(rec, %{"type" => "extension_ui_response", "id" => id, "cancelled" => true})

      true ->
        rec
    end
  end

  defp dialog(rec, _frame), do: rec

  # stdin is closed: OMP drains, prints what is left and exits.
  defp await_exit(rec) do
    port = rec.port

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        await_exit(%{rec | buffer: [rec.buffer | chunk]})

      {^port, {:data, {:eol, chunk}}} ->
        line = IO.iodata_to_binary([rec.buffer | chunk])
        await_exit(%{rec | buffer: [], log: [{:out, line} | rec.log]})

      {^port, {:exit_status, status}} ->
        {rec, status}
    after
      @rpc_step_ms -> fail("omp did not exit within #{@rpc_step_ms} ms of stdin EOF")
    end
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

  # A dialog's id, and a `cancel`'s `targetId`, numbered in order of first
  # appearance, so a request and its response keep matching.
  defp scrub(%{"type" => type} = map, seen, tmp) when type in @ui_frames do
    {map, seen} =
      Enum.reduce(["id", "targetId"], {map, seen}, fn key, {map, seen} ->
        case map do
          %{^key => id} when is_binary(id) ->
            {stable, seen} = stable(id, "ui-", seen)
            {%{map | key => stable}, seen}

          _ ->
            {map, seen}
        end
      end)

    scrub_pairs(map, seen, tmp)
  end

  defp scrub(map, seen, tmp) when is_map(map), do: scrub_pairs(map, seen, tmp)

  defp scrub(list, seen, tmp) when is_list(list),
    do: Enum.map_reduce(list, seen, &scrub(&1, &2, tmp))

  defp scrub(string, seen, tmp) when is_binary(string), do: scrub_string(string, seen, tmp)
  defp scrub(other, seen, _tmp), do: {other, seen}

  defp scrub_pairs(map, seen, tmp) do
    {pairs, seen} =
      Enum.map_reduce(map, seen, fn
        {"systemPrompt", _value}, seen -> {{"systemPrompt", "<systemPrompt>"}, seen}
        {key, value}, seen when is_number(value) -> {{key, scrub_number(key, value)}, seen}
        {key, value}, seen -> scrub(value, seen, tmp) |> then(fn {v, s} -> {{key, v}, s} end)
      end)

    {Map.new(pairs), seen}
  end

  # Timestamps, timings and the account's credential slot.
  defp scrub_number(key, value) do
    if String.match?(key, ~r/time|created|updated|completed|duration|ttft|credentialId/i),
      do: 0,
      else: value
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
