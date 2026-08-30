# Brand marks

Single-path SVG marks for the integrations row on the landing page. Read at
compile time by `RaxolPlayground.BrandMarks`, which extracts the `d` attribute
and inlines it, so the page makes no external request for them.

## Source

[Simple Icons](https://simpleicons.org) version 16.29.0, fetched unmodified.
The collection is licensed CC0-1.0. The trademarks themselves remain the
property of their owners; they appear here as nominative use, to say what
raxol works with, and imply no endorsement.

Every file is a 24 by 24 viewBox with exactly one `path`. A test holds that
shape, because the renderer inlines the path and nothing else.

## Which entry each mark serves

The row's entries are derived from `Raxol.Agent.Backend.Resolver.providers/0`
and from the ACP client list, so this directory is keyed by the display name
those produce:

| Entry       | File                  | Note                                  |
| ----------- | --------------------- | ------------------------------------- |
| Claude      | `claude.svg`          |                                       |
| Anthropic   | `anthropic.svg`       |                                       |
| Kimi        | `kimi.svg`            |                                       |
| OpenRouter  | `openrouter.svg`      |                                       |
| Proton Lumo | `proton.svg`          | Lumo has no mark of its own; this is Proton's, the vendor's |
| Ollama      | `ollama.svg`          |                                       |
| LM Studio   | `lmstudio.svg`        |                                       |
| Zed         | `zedindustries.svg`   |                                       |
| JetBrains   | `jetbrains.svg`       |                                       |
| neovim      | `neovim.svg`          |                                       |
| Emacs       | `gnuemacs.svg`        |                                       |

## Entries with no mark, deliberately

OpenAI, VS Code, Grok, LongCat, and LLM7 are absent from the Simple Icons set.
Checked against the full 3457 icon index for version 16.29.0, not inferred from
a failed download. Simple Icons removes marks at a trademark holder's request,
so the absence is a decision by the owner rather than a gap to route around.

Nothing is substituted for them. `OpenAI Gym` and `VSCodium` exist in the set
and are different products, so using either would name the wrong thing. Those
five entries render their name instead, which is what every entry did before
this directory existed, and a new backend with no mark does the same rather
than disappearing from the row.
