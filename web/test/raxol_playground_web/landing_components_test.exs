defmodule RaxolPlaygroundWeb.LandingComponentsTest do
  # Not async: the SSH-availability tests flip RAXOL_SSH_PLAYGROUND, which is
  # VM-global. Four component renders are cheap; a racy env read is not.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Raxol.Agent.Backend.Resolver
  alias Raxol.Payments.Assets
  alias RaxolPlayground.BrandMarks
  alias RaxolPlayground.Capabilities
  alias RaxolPlayground.NetworkMarks
  alias Raxol.Payments.Router
  alias RaxolPlayground.RecordedFrames
  alias RaxolPlayground.SurfaceSource
  alias RaxolPlaygroundWeb.LandingComponents
  alias RaxolPlaygroundWeb.PlaygroundComponents

  test "landing promotes live install and browser paths, not the suspended SSH host" do
    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    deep_dive = render_component(&LandingComponents.ssh_deep_dive/1, %{})

    # The one-screen hero carries ONE install path: the curl script this site
    # serves. The four-method install tabs are gone, along with every other
    # component that rendered on no route.
    assert hero =~ "curl -fsSL https://raxol.io/install | bash"
    assert deep_dive =~ "Hosted SSH is temporarily offline"
    assert deep_dive =~ ~s(href="/playground")

    refute Enum.join([hero, deep_dive]) =~ "playground@raxol.io"
  end

  # The landing is one screen. These are the two properties that keeps: it
  # carries no deep-dive section (those are their own pages now), and the hero
  # plays recorded frames rather than starting a live session.
  test "the landing screen carries no deep dive and no live session" do
    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    refute hero =~ "take over live"
    refute hero =~ "run it live"
    refute hero =~ ~s(phx-click="take_over")
    refute hero =~ "RaxolTerminal"

    # Recorded frames, and more than one, or the hero is a still image.
    assert hero =~ ~s(class="hero-frame")
    assert length(String.split(hero, ~s(class="hero-frame"))) - 1 > 1
  end

  test "every hero example has recorded frames and a readable module" do
    for name <- LandingComponents.hero_example_names() do
      frames = RaxolPlayground.RecordedFrames.hero_frames(name)

      assert length(frames) > 1,
             "#{name} has #{length(frames)} recorded frame(s)"

      assert Enum.uniq(frames) == frames, "#{name} recorded identical frames"

      hero = render_component(&LandingComponents.screen_hero/1, example: name)
      assert hero =~ "#{name}.ex"
    end
  end

  # The hero claims one module reaches four surfaces, each pane an encoding of
  # one recorded render. These tests stop a pane reverting to authored text.
  test "the listed hero pane is a recorded artifact, line for line" do
    for name <- LandingComponents.hero_example_names(),
        surface <- [:mcp] do
      artifact = RecordedFrames.hero_artifact(name, surface)
      pane = RecordedFrames.hero_surface(name, surface)

      assert artifact != "", "#{name}/#{surface} has no recorded artifact"
      assert pane != "", "#{name}/#{surface} renders no pane"

      lines = pane_lines(pane)
      marker? = List.last(lines) =~ ~r/^\.\.\. \d+ more lines, \d+ bytes total$/
      body = if marker?, do: Enum.drop(lines, -1), else: lines

      for line <- body do
        assert String.contains?(artifact, line),
               "#{name}/#{surface} shows a line that is not in the artifact:\n#{inspect(line)}"
      end

      # A pane either says what it cut, or it cut nothing.
      full = artifact |> break_lines(surface) |> SurfaceSource.wrap()

      if marker? do
        assert length(lines) == SurfaceSource.budget()
        assert length(full) > SurfaceSource.budget()
      else
        assert body == full,
               "#{name}/#{surface} shows #{length(body)} of #{length(full)} lines and says nothing"
      end
    end
  end

  # The browser pane renders the recording rather than listing the markup of
  # it, so it gets the same shape of invariant the SSH pane does.
  test "the browser pane renders the recording inside a page" do
    for name <- LandingComponents.hero_example_names() do
      hero = render_component(&LandingComponents.screen_hero/1, example: name)
      pane = surface_pane(hero, 1)
      frames = RecordedFrames.hero_frames(name)

      # The regression this pane exists to not have. Markup shown as text is
      # what made the surface that renders to a browser read as a library that
      # formats strings.
      refute pane =~ "&lt;span",
             "#{name}/browser is listing its markup as text again"

      refute pane =~ "more lines,",
             "#{name}/browser is clamping a listing instead of rendering a frame"

      # Every recorded frame, and only those: one element each, contents
      # verbatim, so the pane cannot drift from the recording beside it.
      assert count(pane, ~s(class="hero-frame")) == length(frames)

      for {frame, i} <- Enum.with_index(frames) do
        assert pane =~ ~s(data-frame="#{i}")

        assert String.contains?(pane, frame),
               "#{name}/browser dropped frame #{i}"
      end

      # The page around the frame is what distinguishes this tab from the
      # terminal tab, which shows the same recording bare.
      assert pane =~ "localhost:4000/#{name}"

      assert pane =~
               ~r/hero-browser__heading">\s*#{LandingComponents.example_module(name)}\s*</,
             "#{name}/browser does not head its page with the module the source defines"
    end
  end

  # The SSH pane is painted rather than listed, so it gets its own invariant:
  # the whole recording, in colour, with nothing authored and nothing dropped.
  test "the SSH pane paints the whole recording and invents nothing" do
    for name <- LandingComponents.hero_example_names() do
      artifact = RecordedFrames.hero_artifact(name, :ssh)
      pane = RecordedFrames.hero_surface(name, :ssh)

      assert artifact != "", "#{name}/ssh has no recorded artifact"

      # The regression this pane exists to not have: escape codes on screen
      # read as a terminal failing to render, on the one tab that claims a
      # terminal works.
      refute pane =~ "ESC[",
             "#{name}/ssh is showing escape codes as text again"

      # Painted, not merely stripped -- the colours are the frame.
      assert pane =~ ~s(class="ansi-),
             "#{name}/ssh dropped its colour instead of painting it"

      # Every character the artifact paints, and only those.
      assert pane |> pane_lines() |> Enum.join("\n") ==
               artifact |> strip_ansi() |> String.trim_trailing("\n"),
             "#{name}/ssh does not show exactly what the recording paints"

      # The grid the CSS fits type to describes the frame it is given.
      grid = RecordedFrames.hero_ssh_grid(name)

      rows =
        artifact
        |> strip_ansi()
        |> String.trim_trailing("\n")
        |> String.split("\n")

      assert grid.rows == length(rows)
      assert grid.cols == rows |> Enum.map(&String.length/1) |> Enum.max()
    end
  end

  # The SSH pane animates in lockstep with the terminal pane: same buffer, two
  # surfaces, same moment. Equal counts is the property that keeps them in step,
  # because the player indexes both by the same frame number.
  test "the SSH pane has one painted frame per terminal frame" do
    for name <- LandingComponents.hero_example_names() do
      terminal = RecordedFrames.hero_frames(name)
      ssh = RecordedFrames.hero_ssh_frames(name)

      assert length(ssh) == length(terminal),
             "#{name}: #{length(ssh)} ssh frames against #{length(terminal)} terminal frames"

      assert length(ssh) > 1, "#{name}/ssh is a still image"
      assert Enum.uniq(ssh) == ssh, "#{name}/ssh recorded identical frames"

      for frame <- ssh do
        refute frame =~ "ESC[",
               "#{name}/ssh is showing escape codes as text again"
      end
    end
  end

  # The recording plays back at the rate it was sampled at, and that rate ships
  # with it rather than living as a constant in the player.
  test "each recording declares the interval it was sampled at" do
    for name <- LandingComponents.hero_example_names() do
      interval = RecordedFrames.hero_frame_interval(name)

      assert interval > 0

      assert interval <= 200,
             "#{name} plays back at #{interval}ms, which is a slideshow"

      hero = render_component(&LandingComponents.screen_hero/1, example: name)
      assert hero =~ ~s(data-frame-ms="#{interval}")
    end
  end

  # A recording is a build input, so a code with no styling behind it has to
  # stop the build rather than reach the page as an unstyled run.
  test "an unpaintable escape sequence fails loudly, not silently" do
    assert_raise ArgumentError, ~r/no styling is mapped for SGR 7/, fn ->
      SurfaceSource.ansi_rows("\e[7mreversed\e[0m")
    end

    assert_raise ArgumentError, ~r/is not an SGR sequence/, fn ->
      SurfaceSource.ansi_rows("\e[2Jcleared")
    end
  end

  # Colour is terminal state, not per-row markup: a run left open at the end of
  # one row still colours the next, the way it does down a real channel.
  test "colour carries across rows until it is reset" do
    rows = SurfaceSource.ansi_rows("\e[36mone\ntwo\e[0m\nthree")

    assert rows == [
             [{["ansi-cyan"], "one"}],
             [{["ansi-cyan"], "two"}],
             [{[], "three"}]
           ]
  end

  # Intensity and emphasis are orthogonal to colour, so a run holds a SET of
  # classes. Holding one meant `bold cyan` had nowhere to go and the decoder
  # raised on SGR 1 -- which `text(..., style: [:bold])` emits, so promoting an
  # ordinary catalog demo to a hero example failed the build on a code its own
  # recording legitimately contained.
  describe "attributes compose with colour" do
    test "bold and colour are both carried" do
      assert [[{classes, "hi"}]] = SurfaceSource.ansi_rows("\e[36m\e[1mhi\e[0m")
      assert classes == ["ansi-cyan", "ansi-bold"]
    end

    test "a combined parameter list is applied in order" do
      assert [[{classes, "hi"}]] = SurfaceSource.ansi_rows("\e[1;33mhi\e[0m")
      assert classes == ["ansi-yellow", "ansi-bold"]
    end

    test "every attribute the demos use decodes" do
      for {seq, class} <- [
            {"1", "ansi-bold"},
            {"2", "ansi-dim"},
            {"3", "ansi-italic"},
            {"4", "ansi-underline"}
          ] do
        assert [[{[^class], "x"}]] = SurfaceSource.ansi_rows("\e[#{seq}mx\e[0m")
      end
    end

    test "bright colours decode" do
      assert [[{["ansi-bright-cyan"], "x"}]] =
               SurfaceSource.ansi_rows("\e[96mx\e[0m")
    end

    test "22 clears intensity but leaves colour" do
      assert [[_bold, {classes, "b"}]] =
               SurfaceSource.ansi_rows("\e[36;1ma\e[22mb\e[0m")

      assert classes == ["ansi-cyan"]
    end

    test "39 clears colour but leaves attributes" do
      assert [[_first, {classes, "b"}]] =
               SurfaceSource.ansi_rows("\e[36;1ma\e[39mb\e[0m")

      assert classes == ["ansi-bold"]
    end

    test "attributes carry across rows like colour does" do
      rows = SurfaceSource.ansi_rows("\e[1mone\ntwo\e[0m\nthree")

      assert rows == [
               [{["ansi-bold"], "one"}],
               [{["ansi-bold"], "two"}],
               [{[], "three"}]
             ]
    end

    test "the markup names every class the run carries" do
      html =
        "\e[36;1mhi\e[0m"
        |> SurfaceSource.ansi_rows()
        |> SurfaceSource.ansi_html()

      assert html == ~s(<span class="ansi-cyan ansi-bold">hi</span>)
    end

    # The decoder refuses a code it has no class for, which stops an unstyled
    # run reaching the page. It cannot tell whether the class it DOES emit is
    # painted by anything, so a mapping added without its CSS would render as
    # plain text and every test above would still pass.
    @app_css Path.expand("../../assets/css/app.css", __DIR__)
    @external_resource @app_css

    test "every class the decoder can emit is painted by the stylesheet" do
      css = File.read!(@app_css)

      codes =
        Enum.map(30..37, &to_string/1) ++
          Enum.map(90..97, &to_string/1) ++ ["1", "2", "3", "4"]

      for code <- codes do
        assert [[{classes, "x"}]] = SurfaceSource.ansi_rows("\e[#{code}mx\e[0m")

        for class <- classes do
          assert css =~ ".#{class} ",
                 "SGR #{code} decodes to .#{class}, which app.css does not paint"
        end
      end
    end
  end

  # The hero shows a program's source; the frames beside it are that program's
  # recorded output. They live in two files, and `gen_landing_frames.exs` asks
  # in a comment that the pair be kept byte-identical -- which nothing checked,
  # so the source could drift from the run that produced the frames and the
  # pane would still pass every test above. It is a comment no longer.
  @frames_script Path.expand("../../../scripts/gen_landing_frames.exs", __DIR__)

  test "each hero program is byte-identical to the one the frames were recorded from" do
    script = File.read!(@frames_script)

    landing =
      File.read!(
        Path.expand(
          "../../lib/raxol_playground_web/components/landing_components.ex",
          __DIR__
        )
      )

    for {name, module} <- [{"pulse", "Pulse"}, {"halo", "Halo"}] do
      assert [_, tail] =
               String.split(landing, "@#{name}_source ~S\"\"\"\n", parts: 2)

      assert [heredoc, _] = String.split(tail, "\n  \"\"\"", parts: 2)

      shown =
        heredoc
        |> String.split("\n")
        |> Enum.map_join("\n", &String.replace_prefix(&1, "  ", ""))
        |> String.trim()

      recorded =
        Regex.run(~r/^defmodule #{module} do\n.*?\nend$/ms, script)
        |> case do
          [source] -> String.trim(source)
          nil -> flunk("#{@frames_script} has no `defmodule #{module}`")
        end

      assert shown == recorded,
             "the #{name} pane shows a different program than the one its frames were " <>
               "recorded from; keep landing_components.ex and gen_landing_frames.exs in step"
    end
  end

  # The pane's claim is that you can read the whole program, and the pane is a
  # fixed slice of one screen. A longer example does not scroll, it clips --
  # which is how halo grew to 35 lines and started cutting off mid-function
  # without anything failing. The budget is what the pane holds at its type
  # floor on the shortest viewport the page still calls one screen.
  @max_example_lines 30

  # The same argument on the other axis, which had no test: `example_grid/1`
  # measures `cols` and the pane divides by it, so a wide-but-short example
  # would run off the right edge behind the hidden scrollbar with nothing
  # failing. Measured rather than assumed, at the narrowest viewport the page
  # still calls one screen (the query starts at 768px wide):
  #
  #   .hero-demo caps at 62rem, so it is min(992, 768 - 40) = 728 wide
  #   .hero-panes loses the 1px divider and splits in two   -> 363 per pane
  #   .hero-pane pads 0.9rem a side                         -> 334.2 of content
  #   Monaspace Argon advances 0.6201em, so at the 0.5rem type floor
  #   one character is 4.9609px, and 334.2 / 4.9609 = 67.4
  #
  # 67, then. Note the pane's own formula assumes a 0.63 advance, which is
  # deliberately ~2% conservative; the real advance is what decides whether
  # glyphs actually fit once the clamp has floored the type, so it is what
  # this ceiling is derived from. The margin at 67 is 1.8px -- tight on
  # purpose, because it is the widest the pane can honestly hold.
  @max_example_cols 67

  test "every hero example fits the pane it is displayed in" do
    for name <- LandingComponents.hero_example_names() do
      %{lines: lines, cols: cols} = LandingComponents.example_grid(name)

      assert lines <= @max_example_lines,
             "#{name}.ex is #{lines} lines; the pane holds #{@max_example_lines}"

      assert cols <= @max_example_cols,
             "#{name}.ex is #{cols} columns wide; the pane holds #{@max_example_cols} " <>
               "at 768px, the narrowest one-screen viewport"
    end
  end

  # The h1 names four things. Three of them used to be assertions with nothing
  # under them: the rotation was two rendering demos, so "agent, harness, and
  # payments included" was a sentence rather than a claim you could check by
  # clicking. Each noun now has a program, and this is what stops one being
  # deleted while the sentence that promises it stays.
  test "every noun in the headline has an example that runs it" do
    names = LandingComponents.hero_example_names()

    assert "harness" in names, "the h1 promises a harness and nothing demonstrates one"
    assert "settle" in names, "the h1 promises payments and nothing demonstrates them"

    for name <- names do
      blurb = LandingComponents.example_blurb(name)

      assert blurb != "", "#{name}.ex says nothing about what it demonstrates"

      hero = render_component(&LandingComponents.screen_hero/1, example: name)
      assert hero =~ blurb, "the #{name} title bar drops its blurb"
    end
  end

  # The page has got fees wrong once already: raxol.io rendered a hand-written
  # fee table until 2026-08-30 whose numbers no tier ever charged (see the note
  # in `Raxol.Payments.PrivacyTier`). The hero no longer prices anything at all
  # -- the ladder lives on /payments, held against the pinned schedule by
  # "payments section renders the ladder ..." below -- so what this guards now
  # is that no rate creeps back into a pane that has no schedule behind it.
  test "the settle pane quotes no fee at all" do
    quoted = ~r/\d+ bps/ |> Regex.scan(settle_pane()) |> List.flatten()

    assert quoted == [],
           "the settle pane quotes #{Enum.join(quoted, ", ")}; the hero does not price transfers"
  end

  # The row replaced the sentence, so it inherits the sentence's obligation:
  # every chain the asset registry carries a token on has a mark. Tron is the
  # seventh and is not in that table -- it is reached over the relay rail --
  # so it is asserted by name rather than derived.
  test "every chain the registry carries has a mark in the network row" do
    registry =
      Assets.evm_tokens()
      |> Enum.flat_map(fn {_symbol, chains} -> Map.keys(chains) end)
      |> Enum.uniq()

    marked = NetworkMarks.ids()

    for id <- registry do
      assert id in marked,
             "chain #{id} (#{Assets.chain_name(id)}) settles a token and has no mark"
    end

    assert 728_126_428 in marked, "the relay rail reaches Tron and the row omits it"

    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    for %{name: name} <- NetworkMarks.all() do
      assert hero =~ name, "the network row drops #{name}"
    end
  end

  # The sub-line used to name every chain USDC is deployed on. It does not any
  # more: the reach table on /payments carries them, derived from the solver's
  # own capability matrix, and a subset typed into the hero dates the sentence
  # every time a corridor is added. This holds the hero to the shorter claim.
  # Scoped to the paragraph, not the whole hero: the network row beneath it
  # names every chain in a `<title>` and an aria-label, which is how a mark is
  # reachable at all. It is the PROSE that stopped listing them.
  test "the hero sub-line names no chain and no asset" do
    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    [sub] = Regex.run(~r/<p class="screen-sub">(.*?)<\/p>/s, hero, capture: :all_but_first)

    for chain <- ["Ethereum", "Optimism", "Polygon", "Arbitrum One", "Robinhood Chain"] do
      refute sub =~ chain,
             "the sub-line names #{chain}; the network row and /payments carry chains"
    end

    for asset <- Map.keys(Assets.evm_tokens()) do
      refute sub =~ asset,
             "the sub-line names #{asset}; it settles more than one asset"
    end
  end

  defp settle_pane do
    "settle"
    |> RecordedFrames.hero_frames()
    |> List.first()
    |> String.replace(~r/<[^>]*>/, "")
    |> unescape()
  end

  test "the hero renders four surfaces and claims no ACP one" do
    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    for label <- ["Terminal", "Browser", "SSH", "Agent / MCP"] do
      assert hero =~ ">#{label}</button>"
    end

    assert length(String.split(hero, ~s(class="hero-tab"))) - 1 == 4
    assert hero =~ ~s(data-surface="3")
    refute hero =~ ~s(data-surface="4")

    # ACP is the coding agent's editor protocol, not a surface a TEA chart
    # renders to, so the hero may not caption an example module with it.
    refute hero =~ "ACP"
    refute hero =~ "session/prompt"
    refute hero =~ "agent_message_chunk"
  end

  # The row reinforces the claim with things that are true, so its entries have
  # to come from the tables the rest of the site serves rather than from a list
  # someone typed. A hand-kept copy is what put "Groq" on /api/capabilities and
  # left four real providers off it. This fails rather than drifting.
  test "the integrations row's models are the agent's own provider registry" do
    expected =
      Resolver.providers()
      |> Enum.reject(&(&1.harness == :mock))
      |> Enum.map(&(&1.label |> String.split(" (") |> hd()))

    assert Capabilities.connectable_backends() == expected

    # Mock answers canned text offline. It belongs in the manifest an agent
    # reads, and not in a list of providers a reader could connect to.
    assert "Mock" in Capabilities.backends()
    refute "Mock" in expected

    row = render_component(&LandingComponents.screen_integrations/1, %{})

    for name <- expected do
      assert row =~ name,
             "the integrations row omits #{name}, which the provider registry lists"
    end
  end

  # npm and the Homebrew tap are built but unpublished and human-gated, so the
  # row names channels that exist today. The install tabs that advertised both
  # while rendering on no route are gone.
  test "the integrations row names no unpublished install channel" do
    row = render_component(&LandingComponents.screen_integrations/1, %{})

    refute row =~ "npm"
    refute row =~ "brew"
    refute row =~ "Homebrew"
  end

  # Editors are third-party ACP clients, so the honest gate is our own ACP
  # surface: a build without it (a Hex install of raxol_agent compiles no
  # StdioAgent) names no editor rather than five that cannot reach it. Asserted
  # as a relationship, since a compile gate cannot be flipped from a test the
  # way RAXOL_SSH_PLAYGROUND can.
  test "editors appear only while raxol's own ACP surface is compiled in" do
    row = render_component(&LandingComponents.screen_integrations/1, %{})
    labels = Enum.map(LandingComponents.integration_groups(), &elem(&1, 0))

    editors_named? = "acp editors" in labels

    assert Capabilities.acp_available?() == (Capabilities.acp_editors() != [])
    assert editors_named? == Capabilities.acp_available?()

    for editor <- Capabilities.acp_editors() do
      assert row =~ editor, "the integrations row omits #{editor}"
    end
  end

  # The hero may not say "ACP" (above), and this row names ACP editors. Keeping
  # the row a sibling of the hero rather than part of it is what keeps both
  # true, so the separation is asserted instead of left to convention.
  test "the integrations row is a sibling of the hero, not part of it" do
    for name <- LandingComponents.hero_example_names() do
      hero = render_component(&LandingComponents.screen_hero/1, example: name)

      refute hero =~ "integrations-track",
             "#{name}'s hero carries the integrations row, which must stay a sibling"
    end
  end

  # A mark decorates a derived entry, it never replaces one. The row still
  # lists what the registry lists, and an entry whose brand has no mark shows
  # its name. Both directions are held: a mark left behind for something no
  # longer offered would otherwise rot in the directory unnoticed.
  test "marks decorate the derived entries without narrowing them" do
    entries =
      Enum.flat_map(LandingComponents.integration_groups(), &elem(&1, 1))

    row = render_component(&LandingComponents.screen_integrations/1, %{})
    names = Enum.map(entries, & &1.name)

    for entry <- entries do
      shown = if entry.mark, do: entry.label, else: entry.name

      assert row =~ ">#{shown}</span>",
             "the row drops #{entry.name}, which is derived"
    end

    for name <- BrandMarks.known() do
      assert name in names, "#{name} has a mark but is no longer an entry"
    end

    # A mark that needs `evenodd` and does not get it still renders, just with
    # its counters filled in, so nothing else here would catch the difference.
    # The Virtuals Protocol mark is the one that needs it, and their brand
    # guide is the reason it matters: a filled loop is a redrawn logo.
    assert BrandMarks.fill_rule("Virtuals Protocol") == "evenodd"
    assert row =~ ~s(fill-rule="evenodd")

    for name <- BrandMarks.known(), rule = BrandMarks.fill_rule(name) do
      assert rule in ["evenodd", "nonzero"],
             "#{name} declares fill-rule #{inspect(rule)}, which is not a rule"
    end

    # Two runs are rendered: the visible one and the aria-hidden copy the loop
    # needs, so every marked entry appears twice.
    marked = Enum.filter(entries, & &1.mark)

    assert length(String.split(row, "integrations-item--marked")) - 1 ==
             length(marked) * 2

    # The no-mark path has to be live, not theoretical. Were every entry to
    # gain a mark this test would still pass while the fallback rotted, so the
    # fallback is asserted to be exercised by something.
    assert Enum.any?(entries, &is_nil(&1.mark)),
           "no entry exercises the no-mark fallback"
  end

  # The reveal shows the registry's own label rather than the shortened head of
  # it. Two entries reach Claude, the CLI subscription and the API key, and the
  # head is the one part of the label that cannot say which is which: they
  # shorten to "Claude" and "Anthropic" and read as a duplicate.
  test "a marked entry reveals the full label, not the short head" do
    row = render_component(&LandingComponents.screen_integrations/1, %{})

    qualified =
      Capabilities.connectable_providers()
      |> Enum.filter(&(&1.label != &1.name and BrandMarks.path(&1.name)))

    assert qualified != [],
           "no marked provider carries a qualifier worth revealing"

    for %{label: label} <- qualified do
      assert row =~ ">#{label}</span>", "the row never reveals #{label} in full"
    end

    # The flow still carries the short name for entries with no mark, so the
    # row stays scannable and does not widen to fit every qualifier.
    for %{name: name, label: label} <- Capabilities.connectable_providers(),
        is_nil(BrandMarks.path(name)) and label != name do
      assert row =~ ">#{name}</span>",
             "#{name} should sit in the flow unqualified"

      refute row =~ ">#{label}</span>"
    end
  end

  # The marks are inlined, not fetched: a logo row that reaches out over the
  # network is a row that renders differently on a bad connection than in a
  # test, and it leaks who reads the page to whoever hosts the icons.
  test "every mark is a single inlined path, never a request" do
    row = render_component(&LandingComponents.screen_integrations/1, %{})

    assert row =~ ~s(viewBox="0 0 24 24")
    refute row =~ "<img"
    refute row =~ "http"

    for name <- BrandMarks.known() do
      d = BrandMarks.path(name)
      assert is_binary(d) and d != "", "#{name} has an empty mark"

      assert String.starts_with?(d, ["M", "m"]),
             "#{name}'s mark is not path data"
    end
  end

  # The name is markup, not something script swaps in on hover: it is what a
  # screen reader reads, what an unmarked entry shows outright, and what sets
  # the item's width so a cross-fade cannot reflow a moving row.
  test "the name is always in the markup, hover only reveals it" do
    row = render_component(&LandingComponents.screen_integrations/1, %{})

    assert row =~ ~s(class="integrations-name")
    refute row =~ "phx-hook"
    refute row =~ "onmouseover"
    refute row =~ ~s(title=")
  end

  defp break_lines(artifact, :mcp), do: SurfaceSource.json_lines(artifact)

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;?]*[A-Za-z]/, "")

  defp count(haystack, needle), do: length(String.split(haystack, needle)) - 1

  # A rendered hero carries every surface at once, so a pane is the run between
  # its own marker and the next one. The last pane has no next marker, which is
  # why the tail is taken rather than a second split asserted.
  defp surface_pane(hero, index) do
    [_, rest] = String.split(hero, ~s(data-surface="#{index}"), parts: 2)

    rest
    |> String.split(~r/data-surface="\d+"/, parts: 2)
    |> List.first()
  end

  # Undoes SurfaceSource's colour spans and escaping, leaving the lines as its
  # line-breaking produced them.
  defp pane_lines(pane) do
    pane
    |> String.replace(~r{</?span[^>]*>}, "")
    |> unescape()
    |> String.split("\n")
  end

  defp unescape(text) do
    # &amp; last, or an escaped &amp;lt; would come back as a literal <.
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  test "the hero halo exports the coding agent's real face frames" do
    hero =
      render_component(&LandingComponents.screen_hero/1,
        example: List.first(LandingComponents.hero_example_names())
      )

    assert hero =~ ~s(phx-hook="HaloField")
    assert hero =~ ~s(aria-hidden="true")
    # data-faces carries AxolFace.glyph/3 output: the branded gills and the
    # canonical state cycle, so the page and the TUI render the same face.
    assert hero =~ "≡··≡"
    assert hero =~ "idle"
    assert hero =~ "thinking"
    assert hero =~ "working"
    assert hero =~ "done"
  end

  test "surface chips group into the three places you already are" do
    surfaces = render_component(&LandingComponents.surfaces_deep_dive/1, %{})

    assert surfaces =~ "In your terminal"
    assert surfaces =~ "In your browser"
    assert surfaces =~ "Where your agents are"
    assert surfaces =~ "termbox2 NIF"
    assert surfaces =~ "Phoenix LiveView"
    assert surfaces =~ "JSON-RPC over stdio"
  end

  test "nav links the components entry on desktop and mobile" do
    closed =
      render_component(&LandingComponents.nav_bar/1, mobile_menu_open: false)

    open =
      render_component(&LandingComponents.nav_bar/1, mobile_menu_open: true)

    assert closed =~ ~s(href="/gallery")
    assert open =~ ~s(href="/gallery")
  end

  # The navigation is the thing this page kept getting wrong: six labels for
  # four destinations, three of them ("Playground", "Gallery", "Demos") naming
  # one job. The count is the property worth holding, because the failure mode
  # is adding "just one more" link until it is six again.
  test "the header offers two destinations and no more" do
    assert LandingComponents.nav_links() == [
             {"/gallery", "Components"},
             {"https://hexdocs.pm/raxol", "Docs"}
           ]
  end

  # Reference material moved to the footer rather than being deleted: every
  # destination the header dropped is still one click away.
  test "the footer keeps what the header stopped carrying" do
    footer = render_component(&LandingComponents.screen_footer/1, %{})

    assert footer =~ ~s(href="/skill.md")
    assert footer =~ ~s(href="https://hex.pm/packages/raxol")
    assert footer =~ "github.com/DROOdotFOO/raxol"
  end

  # The mark replaces a word, so it has to carry that word for a screen reader,
  # and it has to be an inlined path like every other mark on the page rather
  # than a request to someone else's CDN.
  test "the github mark is inlined and named" do
    mark = render_component(&LandingComponents.github_mark/1, %{})

    assert mark =~ ~s(aria-label="raxol on GitHub")
    assert mark =~ ~s(viewBox="0 0 24 24")
    assert mark =~ "<path"
    refute mark =~ "<img"
    assert is_binary(BrandMarks.site_path("GitHub"))

    # Site marks are not integration marks: a test holds `known/0` against the
    # provider registry, and GitHub is not a provider.
    refute "GitHub" in BrandMarks.known()
  end

  @live_matrix %{
    source: :live,
    chains: [
      %{chain_id: 8453, chain_name: "Base", vm_type: :evm},
      %{chain_id: 728_126_428, chain_name: "Tron", vm_type: :tvm}
    ],
    tokens: [
      %{
        symbol: "WETH",
        roles: [:origin, :destination],
        addresses: %{8453 => "0xweth"}
      },
      %{
        symbol: "USDC",
        roles: [:origin, :destination],
        addresses: %{8453 => "0xabc"}
      },
      %{
        symbol: "USDT",
        roles: [:origin, :destination],
        addresses: %{8453 => "0xdef", 728_126_428 => "Txyz"}
      }
    ],
    deposit_attestation_signer: nil
  }

  # The two tables under "How an agent pays" are the ones a reader would act
  # on, so neither may be typed. The rails are held against the router itself
  # and the tools against the Actions the package ships -- an Action added to
  # raxol_payments has to appear on the page without anyone editing it, and its
  # sensitivity has to be the flag the tool-call gate actually reads.
  test "the routing table is the router's own answer" do
    payments =
      render_component(&LandingComponents.payments_deep_dive/1,
        matrix: @live_matrix
      )

    for %{label: label, protocol: protocol} <- LandingComponents.routes() do
      assert payments =~ label
      assert payments =~ to_string(protocol)
    end

    # Not a fixture: this is the routing rule itself, so a page that drifted
    # from it would be advertising a rail the product would not pick.
    assert Router.select(cross_chain: false) == :x402
    assert Router.select(cross_chain: true) == :xochi
    assert Router.select(privacy: :stealth) == :xochi
    assert Router.select(to_chain_id: 728_126_428) == :relay
  end

  test "every payment Action is listed with the sensitivity the gate reads" do
    payments =
      render_component(&LandingComponents.payments_deep_dive/1,
        matrix: @live_matrix
      )

    actions = LandingComponents.payment_actions()

    assert length(actions) > 0, "no payment Actions were derived at all"

    for %{name: name, sensitive: sensitive} <- actions do
      assert payments =~ name, "the Action table omits #{name}"

      assert sensitive == Module.concat([
               "Raxol.Payments.Actions.Payments",
               Macro.camelize(String.replace(name, "payment_", ""))
             ]).__action_meta__().sensitive
    end

    assert payments =~ "moves funds"
    assert payments =~ "read only"
  end

  test "payments section renders the ladder, dated proof, and a live matrix honestly" do
    payments =
      render_component(&LandingComponents.payments_deep_dive/1,
        matrix: @live_matrix
      )

    # Dated proof leads; maturity is labeled.
    assert payments =~ "2026-06-28"
    assert payments =~ "2026-07-20"
    assert payments =~ "0.2"

    # Fees come from FeeSchedule, the pinned mirror of the solver's published
    # schedule -- every tier, both asset classes, at the rates it actually
    # charges.
    for {tier, band, stable, volatile} <- [
          {"standard", "0-24", "22 bps", "40 bps"},
          {"trusted", "25-49", "19 bps", "35 bps"},
          {"verified", "50-74", "15 bps", "29 bps"},
          {"premium", "75-99", "12 bps", "25 bps"},
          {"institutional", "100 and above", "10 bps", "22 bps"}
        ] do
      assert payments =~ tier
      assert payments =~ band
      assert payments =~ stable
      assert payments =~ volatile
    end

    # The never-discounted floor is stated, because it is what makes a
    # zero-fee tier impossible.
    assert payments =~ "8 bps stable"
    assert payments =~ "never discounted"
    # Whitespace-tolerant: HEEx wraps prose across lines.
    assert payments =~ ~r/no zero-fee\s+tier/

    # The retired privacy-priced model must not come back: it named tiers no
    # solver has, and advertised a free one.
    refute payments =~ "sovereign"
    refute payments =~ "no fee, full disclosure"
    refute payments =~ "-2 bps"
    refute payments =~ "rebate"
    refute payments =~ ">open<"
    refute payments =~ "30 bps"

    # Privacy is still described, as the settlement mode it is.
    assert payments =~ "shielded"
    assert payments =~ "Privacy is a settlement mode"

    # Matrix rows from the data, stables before WETH, authored rail notes.
    assert payments =~ "source: live"
    assert payments =~ "Base"
    assert payments =~ "8453"
    assert payments =~ "TVM"
    assert payments =~ "relay rail"
    assert payments =~ ~r/USDC.*USDT.*WETH/s

    # No SVM chain in the data -> the greyed future row appears.
    assert payments =~ "Solana"
    assert payments =~ "lights up when the solver ships it"
  end

  test "an unreachable solver renders the cached badge, never fake liveness" do
    fallback = Raxol.Payments.Xochi.Capabilities.fallback()

    payments =
      render_component(&LandingComponents.payments_deep_dive/1,
        matrix: fallback
      )

    assert payments =~ "source: cached"
    refute payments =~ "source: live"
    assert payments =~ "Robinhood Chain"
    assert payments =~ "Permit2 pull"
  end

  # Pinned: these are the only strings on the site meant to be pasted into a
  # chain explorer, and a wrong character looks identical to a right one.
  test "the token page prints the verified contract and no market numbers" do
    token = render_component(&LandingComponents.token_deep_dive/1, %{})

    assert token =~ "$RAXOL"
    assert token =~ "0xf44702b17d9abD53815F703e772F35E9c71A53af"
    assert token =~ "0xa20b68e2e1de71f1426b546ed5514bf253215a48"
    assert token =~ "Robinhood Chain"
    assert token =~ "4663"
    assert token =~ "VIRTUAL"
    assert token =~ "Uniswap"

    assert token =~
             "https://dexscreener.com/robinhood/0xa20b68e2e1de71f1426b546ed5514bf253215a48"

    # Whitespace-tolerant: HEEx wraps prose across lines.
    assert token =~ ~r/not a settlement\s+asset/

    # A market number would be stale by the next request.
    refute token =~ ~r/\$\d/
    refute token =~ ~r/\bFDV\b/i
    refute token =~ ~r/market cap/i
  end

  # The two subjects are separate pages now. A token under a heading about
  # settlement invited the reading its own copy then had to deny, so the
  # payments page must not carry it back.
  test "the payments page carries no token" do
    payments =
      render_component(&LandingComponents.payments_deep_dive/1,
        matrix: @live_matrix
      )

    refute payments =~ "$RAXOL"
    refute payments =~ "0xf44702b17d9abD53815F703e772F35E9c71A53af"
    refute payments =~ "dexscreener"
  end

  # `$RAXOL` reaches the footer through `TopicLive.links/0` like every other
  # deep dive, so the page and the link to it cannot drift apart.
  test "the token page is a topic the footer lists" do
    assert {"/token", "$RAXOL"} in RaxolPlaygroundWeb.TopicLive.links()

    footer = render_component(&LandingComponents.screen_footer/1, %{})
    assert footer =~ ~s(href="/token")
    assert footer =~ "$RAXOL"
  end

  test "coding agent section claims ACP membership and prints the four surfaces" do
    coding = render_component(&LandingComponents.coding_agent_deep_dive/1, %{})

    assert coding =~ "agentclientprotocol.com"
    assert coding =~ "Zed"
    assert coding =~ "mix raxol.code"
    assert coding =~ "raxol acp"
    assert coding =~ "raxol -p"
    assert coding =~ "mix mcp.server"
  end

  test "copy control and mobile menu use native accessible controls" do
    copy =
      render_component(&PlaygroundComponents.ssh_copy_block/1,
        id: "copy-install",
        cmd: "raxol doctor"
      )

    nav =
      render_component(&LandingComponents.nav_bar/1, mobile_menu_open: false)

    assert copy =~ "<button"
    assert copy =~ ~s(aria-label="Copy command: raxol doctor")
    assert copy =~ ~s(aria-live="polite")
    assert nav =~ ~s(aria-expanded="false")
    assert nav =~ ~s(aria-controls="mobile-navigation")
    assert nav =~ ~s(aria-label="Open menu")
  end

  describe "hosted SSH availability" do
    # The landing page has never advertised the suspended host (the test above
    # holds that line). These are the playground-side surfaces, which did: the
    # gallery/demo banner, the demo footer, and the no-terminal fallback. With
    # RAXOL_SSH_PLAYGROUND unset -- which is how it ships in fly.toml since the
    # 2026-08-26 suspension -- nothing may name a port that is not listening.
    test "callout and fallback offer only the local command while SSH is suspended" do
      refute Capabilities.ssh_available?()
      assert Capabilities.ssh_command() == nil

      banner =
        render_component(&PlaygroundComponents.ssh_callout/1, variant: :banner)

      footer =
        render_component(&PlaygroundComponents.ssh_callout/1, variant: :footer)

      fallback =
        render_component(&PlaygroundComponents.terminal_fallback/1, %{})

      rendered = Enum.join([banner, footer, fallback])

      refute rendered =~ "playground@raxol.io"
      refute rendered =~ "ssh -p"

      # The surface still has to be useful, not just silent.
      assert banner =~ "mix raxol.playground"
      assert footer =~ "mix raxol.playground"
      assert fallback =~ "mix raxol.playground"
    end

    test "the agent manifest omits the ssh link rather than publishing a dead one" do
      refute Map.has_key?(Capabilities.links(), :ssh)

      # The rest of the manifest is unaffected.
      assert Capabilities.links().playground == "https://raxol.io/playground"
    end

    test "re-enabling the env var restores every mention with no code change" do
      System.put_env("RAXOL_SSH_PLAYGROUND", "true")

      try do
        assert Capabilities.ssh_available?()
        assert Capabilities.ssh_command() == "ssh -p 2222 playground@raxol.io"
        assert Capabilities.links().ssh == "ssh -p 2222 playground@raxol.io"

        banner =
          render_component(&PlaygroundComponents.ssh_callout/1,
            variant: :banner
          )

        assert banner =~ "playground@raxol.io"
      after
        System.delete_env("RAXOL_SSH_PLAYGROUND")
      end
    end
  end
end
