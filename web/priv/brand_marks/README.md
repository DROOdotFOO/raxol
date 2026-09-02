# Brand marks

Single-path SVG marks for the integrations row on the landing page. Read at
compile time by `RaxolPlayground.BrandMarks`, which extracts the `d` attribute
and inlines it, so the page makes no external request for them.

Every file is a 24 by 24 viewBox with exactly one `path`. A test holds that
shape, because the renderer inlines the path and nothing else. The trademarks
remain the property of their owners; they appear here as nominative use, to
say what raxol works with, and imply no endorsement.

## Source: Simple Icons

Most marks come from [Simple Icons](https://simpleicons.org) version 16.29.0,
fetched unmodified. The collection is licensed CC0-1.0.

## Source: vendor-published assets

Four marks are absent from Simple Icons because the trademark holders asked
for their removal there. Each was instead taken from an asset the vendor
itself publishes, then normalized to this directory's shape: subpaths merged
into one path, evenodd fills rewritten as nonzero winding (the renderer emits
no `fill-rule`), overlay marks unioned in, background tiles dropped, and the
result scaled to fit a 24 by 24 viewBox with the shorter axis centred, the
same convention Simple Icons uses.

| File          | Source                                                       | Note |
| ------------- | ------------------------------------------------------------ | ---- |
| `vscode.svg`  | `visual-studio-code-icons.zip` from [code.visualstudio.com/brand](https://code.visualstudio.com/brand), icon dated 2021-06-21 | The silhouette is the official icon's own alpha-mask path. Trademark Microsoft; the brand page carries the usage guidelines. |
| `xai.svg`     | The inline header mark [docs.x.ai](https://docs.x.ai) renders (`@xai/icons` namespace, viewBox 0 0 834 318), fetched 2026-09-02 | Four subpaths unioned. Trademark xAI. |
| `openai.svg`  | `public/openai_logo.svg` in OpenAI's own [openai-responses-starter-app](https://github.com/openai/openai-responses-starter-app) | The black blossom path alone; the file's two white backing plates are dropped. Trademark OpenAI. |
| `longcat.svg` | `yeqian-logo.svg`, the logo [longcat.chat](https://longcat.chat) links as its own favicon (Meituan CDN), fetched 2026-09-02 | Green silhouette plus the two eye marks that float in the negative-space face, unioned; the white tile is dropped. Trademark Meituan. |

## Marks the site wears

`github.svg` is not an integration. It is the repository link in the footer,
reached through `BrandMarks.site_path/1` rather than `path/1` and absent from
`known/0`, because that list answers to the provider registry and a mark for
something that is not a provider would read there as one that outlived its
entry. Simple Icons source, same version, same licence as the rest.

## Which entry each mark serves

The row's entries are derived from `Raxol.Agent.Backend.Resolver.providers/0`
and from the ACP client list, so this directory is keyed by the display name
those produce:

| Entry       | File                  | Note                                  |
| ----------- | --------------------- | ------------------------------------- |
| Claude      | `claude.svg`          |                                       |
| Anthropic   | `anthropic.svg`       |                                       |
| OpenAI      | `openai.svg`          |                                       |
| Grok        | `xai.svg`             | Grok has no separate mark; this is xAI's, the vendor's |
| Kimi        | `kimi.svg`            |                                       |
| OpenRouter  | `openrouter.svg`      |                                       |
| LongCat     | `longcat.svg`         |                                       |
| Proton Lumo | `proton.svg`          | Lumo has no mark of its own; this is Proton's, the vendor's |
| Ollama      | `ollama.svg`          |                                       |
| LM Studio   | `lmstudio.svg`        |                                       |
| Zed         | `zedindustries.svg`   |                                       |
| JetBrains   | `jetbrains.svg`       |                                       |
| neovim      | `neovim.svg`          |                                       |
| Emacs       | `gnuemacs.svg`        |                                       |
| VS Code     | `vscode.svg`          |                                       |

## The entry with no mark, deliberately

LLM7 has no mark in Simple Icons and publishes no vector mark of its own.
Nothing is substituted for it: the entry renders its name instead, which is
what every entry did before this directory existed, and a new backend with no
mark does the same rather than disappearing from the row. It also keeps the
no-mark fallback exercised, which a test insists on.
