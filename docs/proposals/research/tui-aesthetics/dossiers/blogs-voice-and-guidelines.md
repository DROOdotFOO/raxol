# Dossier: Voice, Copywriting, and the CLI/TUI Guideline Canon

> _Words are the facial expressions of a TUI._ When you strip away drop shadows,
> glossy buttons, custom fonts, and pixel indents, the two remaining channels for
> **character** are (1) how the tool arranges glyphs, color, and whitespace, and
> (2) **what it says and how it says it.** This dossier is about the second channel —
> the prose, the tone, the punctuation, the emoji, the banner — and the small
> canon of blog posts and guidelines that argue about it. Every entry below pairs a
> **concrete technique** with the **feeling it produces**.

Scope note: this is an *aesthetics* dossier, not a usability manual. Where a
guideline doubles as a mood device (e.g. "print something in <100ms" reads as
*aliveness*), it's in. Pure ergonomics with no felt-quality is out.

---

## 1. The thesis: output is a conversation, and conversation has a tone

The founding move of the modern CLI-aesthetics canon is reframing terminal output
from *machine log* to *dialogue between two parties*. Once it's a conversation, it
has manners, warmth or coldness, condescension or respect — i.e. a **personality**.

**Source: Command Line Interface Guidelines — clig.dev** (Aanand Prasad, Ben Firshman,
Carl Tashian, Eva Parish; 2020). The single most-cited aesthetic doctrine for CLIs.

Technique → feeling map from clig.dev:

- **Reframe every invocation as a turn in a conversation.**
  > "This mode of learning through repeated failure is like a conversation the user
  > is having with the program."
  > "At worst, it's a hostile conversation which makes them feel stupid and
  > resentful. At best, it's a pleasant exchange that speeds them on their way."
  Feeling: the tool has a *disposition toward you* — ally or gatekeeper. This is the
  root metaphor the whole genre inherits.

- **Break silence on success (against the UNIX "no news is good news" default).**
  > "Traditionally, when nothing is wrong, UNIX commands display no output... but can
  > make commands appear to be hanging or broken when used by humans."
  > "If you change state, tell the user."
  Feeling: *presence / aliveness.* Silence reads as death or a hang; a one-line
  acknowledgment reads as a nod from someone paying attention. The vibe of a tool
  that *narrates its own actions* is attentiveness.

- **Rewrite errors into human speech.**
  > "Catch errors and rewrite them for humans... Think of it like a conversation,
  > where the user has done something wrong and the program is guiding them in the
  > right direction."
  > "not printing scary-looking stack traces."
  Feeling: a stack trace feels like *the machine breaking in front of you* (panic,
  exposure of guts, blame); a rewritten error feels like *a colleague catching you*.

- **Errors-as-documentation.**
  > "If you can make errors into documentation, then this will save the user loads of
  > time."
  Feeling: the error stops being a wall and becomes a *doorway* — the emotional shift
  from dread to momentum.

- **Empathy stated as an explicit aesthetic goal.**
  > "Command-line tools are a programmer's creative toolkit, so they should be
  > enjoyable to use."
  > "Delighting the user means exceeding their expectations at every turn, and that
  > starts with empathy."
  > "You want your software to feel like you are on their side, that you want them to
  > succeed."
  Feeling: *warmth, partisanship, being rooted for.* Note the word **feel** —
  clig.dev is explicit that robustness is partly a *subjective, felt* quality:
  > "Subjective robustness requires attention to detail... It's lots of little things:
  > keeping the user informed... not printing scary-looking stack traces."

- **Signal-to-noise as a mood control.**
  > "The more irrelevant output you produce, the longer it'll take the user to figure
  > out what they did wrong."
  > "Don't treat stderr like a log file... Don't print log level labels or extraneous
  > contextual information, unless in verbose mode."
  Feeling: terseness reads as *confidence and respect*; log-vomit reads as *anxiety
  and self-absorption* (the tool talking to itself, not to you).

- **Responsiveness as the texture of aliveness.**
  > "Responsive is more important than fast. Print something to the user in <100ms."
  > "A good spinner or progress indicator can make a program appear to be faster than
  > it is."
  Feeling: sub-100ms feedback is the terminal equivalent of a face that *reacts* —
  it's the difference between a person who nods when you speak and one who stares
  blankly. Motion (spinner) is literally the tool's *breathing*.

- **Color with intention, or it means nothing.**
  > "Use color with intention... Don't overuse it — if everything is a different
  > color, then the color means nothing."
  Feeling: restraint = taste. A disciplined 2–3 color palette reads as *designed*;
  a rainbow reads as *a child's toy* (unless rainbow is the point — see lolcat, §6).

---

## 2. The Charm school: "make the command line glamorous"

Where clig.dev is about *manners*, Charmbracelet (Charm) is about *glamour* — the
overt, unapologetic claim that the terminal deserves to be **beautiful and fun**,
not merely usable. This is the aesthetic-maximalist pole of the genre.

**Source: charm.land — "The Next Generation of the Command Line" and the Charm ethos.**

- **Mission stated as vibe, not function.**
  > "We started Charm four years ago with the goal of making the command line
  > glamourous, powerful, fun and modern."
  > "We wanted to bring that modern product thinking to the command line."
  Feeling: the terminal as a *designed consumer product*, not a sysadmin's utility
  belt. The word "glamorous" (with the 🎀 and 👄 emoji in their repos) is a
  deliberate tonal provocation against terminal-as-serious-business.

- **Separation of structure and style (Lip Gloss).**
  > "One thing we felt was lacking when building command line apps was the separation
  > of concerns between structure and style."
  Lip Gloss "takes an expressive, declarative approach... users familiar with CSS
  feeling at home." Technique: CSS-like styling primitives — borders, padding,
  margins, foreground/background — applied declaratively.
  Feeling: bringing *web-design fluency* into the grid means TUIs can have the
  considered spacing and framing of a web card. The vibe is *modern product UI*.

- **Mascots and personality as brand.**
  > "Our studies show devs who build terminal stuff like weird mascots."
  Feeling: a mascot (Charm's is a literal cartoon) gives a toolchain a *face* — the
  clearest possible identity device in a faceless medium.

**Source: gum README (charmbracelet/gum) — "A tool for glamorous shell scripts 🎀".**

`gum` is the argument that glamour should be available to *shell scripters* with no
Go code. Concrete style flags and their felt effect:

| Flag | Visual move | Feeling produced |
| --- | --- | --- |
| `--border double` / `rounded` | box-drawing frame around content | *containment, care* — content is "framed", presented like a picture |
| `--border-foreground 212` | hot-pink border | *playfulness, brand signature* — Charm's 212 pink is a house color |
| `--padding "1 2"` | interior breathing room | *calm, premium* — cramped text reads cheap; padding reads luxurious |
| `--margin "1 2"` | exterior whitespace | *isolation, importance* — the element gets its own space on the stage |
| `--foreground <hex>` | truecolor text | *precision of mood* — exact hue instead of the 16-color "default" look |
| `spin` | animated spinner over a running command | *aliveness*, the script "thinking" |
| `choose` / `filter` | interactive selection UI | *responsiveness* — the script becomes a dialog, not a monologue |
| `style` with `--align center` | centered text in a width box | *poise, deliberateness* — centering is a strong compositional claim |

The gum thesis (paraphrased from its docs and reception): **glamour is functional.**
Bordered, padded, colored components make scripts feel like *finished products*
rather than duct-taped one-offs. The felt shift is amateur → crafted.

---

## 3. The compiler-as-assistant tradition: tone under maximum stress

Error messages are where a tool's voice is tested hardest, because the user is
already frustrated. The compiler-diagnostics discourse is the richest vein of
technique→feeling mapping in the whole canon, because compilers are *pure text
output* — no widgets, only words and layout.

### 3a. Elm — the empathy standard

**Sources: elm-lang.org "Compiler Errors for Humans" (2015) and "Compilers as
Assistants" (Evan Czaplicki).** (Site is a client-rendered SPA; quotes below are
sourced via the essays and secondary discussion.)

- **The reframe.** "Compilers should be assistants, not adversaries." Feeling: the
  tool is *on your team*, not judging you at a gate.
  > "Nobody wants a confusing and rude gatekeeper." (Compiler Errors for Humans)

- **Naming the enemy.**
  > "A lot of compiler error messages actually do suck."
  > "With many compilers, you get a bunch of poorly formatted gobbledygook."
  Feeling being fought: the *gobbledygook* — dense, unformatted, blaming text that
  makes you feel stupid.

- **The lever is UX, not cleverness.**
  > "You can make a shockingly huge difference just by thinking about the user
  > experience."

Concrete techniques Elm pioneered (later copied by Rust, Reason, ELM-likes in F#):
- **Show the user's actual code**, reprinted, with the problem spot **underlined/
  caret-marked in color** → feeling: *"it's looking at exactly what I wrote"*,
  orientation instead of abstraction.
- **Generous whitespace / blank lines** around the message → feeling: *calm*, room
  to breathe, the opposite of a wall of red.
- **Hints in plain prose** ("Hint: ...") that suggest a fix → feeling: *guidance*,
  a hand on the shoulder.
- **Concede when the type is ugly:** Elm literally says
  > "Staring at this type is usually not so helpful"
  Feeling: *self-aware humility* — the tool admitting its own output is hard, which
  paradoxically builds trust.

### 3b. The counter-take: empathy can curdle into condescension

Crucial for an *aesthetics* dossier, because it shows voice is a **dose**, not a
monotonic good.

**Source: jamalambda.com — "Elm: Amazing, Informative, Paternalistic Error Messages"
(2021).** Same techniques, opposite feeling, depending on the reader's expertise.

- The praise:
  > "I smiled in joy as the compiler helpfully explained exactly what I had done
  > wrong."
  > "The language designer wanted the compiler errors to act as a user guide."

- The curdle:
  > "I increasingly began to think of it as a condescending, paternalistic nag that
  > just could not wait to lord over me with its knowledge."
  > "Its communication style doesn't take experience into consideration. It treats
  > _everyone_ like they are a novice."
  Example: an error explaining what `Int` and `Float` are draws the sarcasm
  > "thanks Elm, didn't occur to me that `Int` and `Float` were examples of valid
  > types."

Design lesson (aesthetic): **verbosity that reads as warmth to a beginner reads as
insult to an expert.** The proposed fix — a verbosity flag letting the user "tell
the compiler how much help I need" — is itself a *tone knob*. The takeaway for TUI
voice: personality has a dose-response curve, and the same words can land as
cheerleading or nagging depending on audience.

### 3c. Clang — precision as its own kind of kindness

**Source: clang.llvm.org/diagnostics.html — "Expressive Diagnostics".** Clang's
aesthetic is *surgical clarity* rather than warmth; the feeling it produces is
*trust through exactness*.

- **The caret.**
  > "The point (the green '^' character) exactly shows where the problem is, even
  > inside of a string."
  Feeling: *a finger pointing at the exact spot* — pinpoint accuracy reads as
  competence.

- **Range highlighting with tildes.**
  ```
  return y + func(y ? ((SomeA.X + 40) + SomeA) / 42 + SomeA.X : SomeA.X);
                   ~~~~~~~~~~~~~~ ^ ~~~~~
  ```
  Feeling: the `~~~~` "underline of the guilty region" + `^` "here specifically" is a
  tiny piece of **ASCII typography** that turns a flat line into a diagram.

- **Color by default** "making it easier to distinguish from nearby text" → feeling:
  the message *separates itself from your code* rather than blending into noise.

- **Fix-it hints** — show the exact code transformation:
  ```
  struct point origin = { x: 0.0, y: 0.0 };
                          ~~ ^
                          .x =
  ```
  Feeling: *the tool does the thinking for you* — beyond diagnosis into remedy.

- **Say only what isn't obvious.** Diagnostics contain "exactly the pertinent
  information," avoiding repeating "what is obvious from the point." Feeling:
  *respect for your intelligence* (the anti-jamalambda move).

### 3d. Rust — confidence levels and suggestion strings

**Source: rustc-dev-guide diagnostics chapter.** rustc attaches a **suggestion string
+ confidence level** to help messages, sometimes machine-applicable (`cargo fix`).
Feeling: *a collaborator who not only spots the bug but offers to fix it and tells
you how sure they are.* The confidence gradation is a subtle honesty signal — the
tool distinguishes "I'm certain" from "maybe try this."

### 3e. Caleb Meredith — the dosage engineer

**Source: calebmer.com — "Writing Good Compiler Error Messages" (2019).** The most
technically specific essay on *diction* in error prose.

- **The 80/20 argument against over-explaining.**
  > "80% of the time, the developer will immediately know what the fix is."
  Feeling engineered: don't smother the common case in a paragraph — brevity is
  kindness when the reader already knows.

- **Grammar and person choose the voice:**
  - First-person plural present tense: "we see" not "we found" → feeling: *live,
    present, in-the-moment* (the tool reacting *now*, with you).
  - Proper articles: "a `String` is not an `Int`" → feeling: *literate, human*, not
    telegraphic robot-speak.
  - **6th-grade reading level** (Hemingway Editor), avoid jargon ("identifier",
    "token") → feeling: *plain-spoken*, not gatekeeping-via-vocabulary.
  - **Curly quotes** (U+201C/U+201D), Markdown structure → feeling: *typographic
    care*, the message was written, not dumped.
- **Smallest possible error location** → the red squiggle lands where you're working
  → feeling: *the tool knows where your attention already is.*

Cross-cutting compiler-voice principle: **the message's job is to move the reader
from dread to momentum.** Every technique (caret, hint, plain prose, fix-it) is a
lever on that emotional transition.

---

## 4. The 12-Factor CLI: "CLIs that users will love"

**Source: Jeff Dickey (jdxcode), "12 Factor CLI Apps" (Heroku/oclif; 2018).** The
bridge between clig.dev's manners and Charm's glamour, from the maker of the Heroku
CLI — a tool famous for *feeling nice*.

- **Permission to show off.**
  > "Modern CLIs shouldn't be afraid to show off. Use colors/dimming to highlight
  > important information."
  Feeling: *confidence.* Dimming secondary text (not just coloring primary) creates
  **visual hierarchy in monochrome-ish space** — the eye is guided, which reads as
  thoughtfulness. Dim = "this is here if you need it, but relax."

- **Spinners/progress as perceived-speed illusion.**
  > "Use spinners and progress bars to show long-running tasks to tell the user
  > you're still working."
  > "Even just a spinner will give the impression the CLI is much faster than it is."
  Feeling: *the tool is alive and trying.* Same lever as clig's <100ms rule — motion
  as reassurance.

- **Structured, humane errors.** Errors should carry: error code, title, description,
  how-to-fix, and a docs URL. Feeling: *an error that takes responsibility* — it
  doesn't just fail, it hands you the next step.

- **The aspirational sentence** (the emotional thesis of the whole genre):
  > "Just think if every CLI was this helpful how incredible it would be to be a
  > programmer."
  Feeling: help as *delight*, a better world made of nicer tools.

- **Respect the pipe / the `tty` check** — no color when piped, honor `NO_COLOR`,
  `TERM=dumb`, `--no-color`. This is ergonomic, but it *doubles as aesthetic
  integrity*: a tool that knows when it's being watched by a human vs a machine is a
  tool with *situational grace*.

---

## 5. NO_COLOR / FORCE_COLOR — who owns the aesthetic?

**Sources: no-color.org (jcs / Joshua Stein) and force-color.org.** The debate under
the debate: **when the tool has a look, who gets to override it — author or user?**

- The NO_COLOR manifesto's core:
  > "An increasing number of command-line software programs output text with ANSI
  > color escape codes by default. While some developers and users obviously prefer
  > seeing these colors, some users don't."
  > "`NO_COLOR` is a hint to the software... to suppress addition of color, not to the
  > terminal to prevent any color from being shown."
  Tone: *pragmatic resignation* — "the futility of trying to reverse this trend." It
  concedes color has won and asks only for an off switch.

- Aesthetic meaning: color is treated as **an imposition** by some users — an
  unsolicited opinion the software forces on their terminal. The whole movement is a
  political statement that *the user's terminal is the user's canvas.*

- **FORCE_COLOR** is the mirror: keep the palette even through pipes/logs. The two
  standards together define the **contract of aesthetic consent** in the terminal:
  the tool may have a look, but the user holds the master switch. This is the closest
  the TUI world has to a "prefers-color-scheme" / accessibility-of-taste layer.

Related: jvns.ca (Julia Evans), "Terminal colours are tricky" (2024) — documents how
the *same* color codes render as wildly different actual hues across terminals and
themes, meaning a TUI's color-vibe is only *partly* under the author's control. The
felt lesson: never rely on an exact hue for meaning; the grid is a shared, contested
canvas.

---

## 6. Emoji in output: the sharpest vibe-war in the terminal

Emoji are the purest test case of "words/glyphs as facial expression," and the
community is genuinely split. This is where the aesthetic stakes are most explicit.

### 6a. Pro-emoji: symbols as perceptual anchors

**Source: baker.is — "In Defense of Emojis in Logs".**

- > "When you're scanning hundreds of lines of output, the brain locks onto shapes
  > faster than words."
- > "Emojis act as anchors — errors 'pop' with ❌, warnings stand out with ⚠️, and
  > successes are easy to spot with ✅."
- > "Emojis are not 'cute.' They're _very_ useful."
- > "Sometimes, the fastest way to say **'this failed'** isn't text, isn't color…
  > It's just ❌."

Technique → feeling: a single colorful glyph at line-start is a **pre-attentive
landmark** — the eye finds it before reading. The vibe is *scannability + friendly
punctuation of status*. Also survives ANSI-stripping: emoji stay meaningful when
color is gone (unlike a bare colored word).

### 6b. Anti-emoji: clutter, childishness, and the broken grid

**Source: HN thread #25311114 ("no emojis please, ever") and the Yarn `--no-emoji`
saga (yarnpkg/yarn issues #960, #3660, #4457).**

The anti case (paraphrased from the thread and issues, which reached 429 on direct
fetch): emoji are attacked as (1) **unprofessional/childish**, undermining a tool's
seriousness; (2) **width-breaking** — many emoji are ambiguous- or double-width and
**shift the monospace grid**, misaligning columns and box-drawing; (3)
**inconsistently rendered** across terminals/fonts (tofu boxes, wrong glyph, missing
color); (4) **encoding hazards** — redirected/Windows output garbles non-ASCII. Yarn
shipping emoji-by-default then having to add `--no-emoji` and env toggles is the
canonical "we went too cute" retreat.

Technique → feeling: a double-width ✅ that pushes a table column one cell right
produces *sloppiness* — the exact opposite of the intended polish. In a medium whose
entire dignity rests on **grid alignment**, a glyph that breaks the grid is an
aesthetic betrayal, however friendly its intent.

### 6c. The synthesis

The mature position across clig.dev and 12-factor: **use symbols/emoji where they
clarify, gate them behind a tty/`--no-emoji`/env check, and never let them break
alignment.** clig.dev:
> "Use symbols and emoji where it makes things clearer... Be careful — it can be easy
> to overdo it and make your program look cluttered."
The felt principle: emoji are *seasoning*, not the meal. One ✓ per line is warmth;
a confetti of glyphs is noise.

---

## 7. Figlet & the terminal-toy tradition: identity by banner

**Sources: FIGlet history (Sheeran/Chai/Chappell, 1991); "Terminal Joy" (Smyekh,
Medium); lolcat (busyloop, 2011); cowsay; toilet; fortune.**

This is the oldest and most unabashedly *identity-first* layer of terminal
aesthetics — decorative, ritual, personal. Not usability at all; pure vibe.

- **FIGlet ASCII banners** — turn a word into giant multi-line block letters.
  > "figlet turns words into giant ASCII banners... makes your terminal feel like a
  > rock concert for text." (Terminal Joy)
  Technique → feeling: the **splash-screen banner** is the single strongest identity
  device a TUI has. It's the terminal equivalent of a logo — a moment of scale and
  drama in a flat grid. Startup banners say *this app has a name and a face* before
  it does anything. (This is why nearly every serious TUI/CLI — from `neofetch` to
  build tools — opens with an ASCII wordmark.)

- **Celebration framing.**
  > "Because sometimes I want to celebrate. A build passed... And I want those moments
  > to _look_ like something."
  Feeling: banners mark *events* — the grid's way of throwing confetti.

- **cowsay** — wraps text in an ASCII speech bubble from a cow.
  > "It's absurd — and completely wonderful."
  > "when your tests fail for the fifth time, sometimes all you need is a cow telling
  > you, 'You tried.'"
  Technique → feeling: **a mascot character delivering the message** injects
  warmth/absurdity; the tool acquires a persona (see also Charm's mascots).

- **lolcat** — rainbow-gradient every line.
  > "prints it out in full rainbow glory... Because sometimes you just need colour.
  > Especially in an environment where most things are greyscale."
  Technique → feeling: a **per-character hue gradient** is the maximalist opposite of
  clig's "color with intention" — it's *joy for joy's sake*, deliberately useless,
  and that uselessness is the point (play, ownership, whimsy).

- **The ritual / ownership thesis** (the emotional core of terminal customization):
  > "So I decided to make my terminal a little more _me_ — more colour, more
  > character, more joy."
  > "It's still serious when I need it to be, but it's also _mine_. It cheers me on."
  > "development doesn't have to be sterile. It can be playful. Colourful. Weird."
  Feeling: the terminal as **personal territory**, a face you give your own tools. The
  banner/mascot/gradient triad is how a faceless grid gets a personality.

---

## 8. Synthesis: the axes of TUI voice

Pulling every source together, the "facial expressions of a TUI" resolve onto a few
tension-axes. Each end is a legitimate aesthetic with a distinct feeling:

| Axis | One pole (technique → feeling) | Other pole (technique → feeling) |
| --- | --- | --- |
| **Silence vs narration** | UNIX quiet-on-success → *terse, professional, trusts you* | clig "tell the user" → *present, attentive, alive* |
| **Warmth vs precision** | Elm hints & prose → *kind, hand-held* | Clang caret & terseness → *exact, respectful, competent* |
| **Restraint vs glamour** | clig "color with intention" → *tasteful, designed* | Charm/gum borders+pink → *fun, modern, product-grade* |
| **Plain vs decorated** | grep-clean ASCII → *serious, scriptable* | figlet/lolcat/cowsay → *playful, owned, joyful* |
| **Author's look vs user's canvas** | default color/emoji → *opinionated, branded* | NO_COLOR/`--no-emoji` → *deferential, situationally graceful* |
| **Help dose: high vs low** | Elm verbose → *welcoming to novices* / *paternalistic to experts* | calebmer 80/20 brevity → *efficient* / *cold to novices* |

The unifying insight from the canon: **tone is a dose, not a virtue.** The same
technique (a hint, an emoji, a color, a banner) reads as warmth or as condescension,
polish or clutter, depending on audience and restraint. A TUI expresses *who it is*
precisely by *where it sits on these axes* — and the most-loved tools (Heroku CLI,
Elm, Charm's suite, Rust) are the ones that chose a coherent point on each axis and
committed to it.

The three load-bearing metaphors to carry forward into Raxol's own voice:
1. **Conversation** (clig) — output has a disposition toward the user.
2. **Assistant, not adversary** (Elm) — even failure is delivered as help.
3. **The terminal is the user's canvas** (NO_COLOR) — have a look, but hold the off switch.

---

## Sources

- Command Line Interface Guidelines — https://clig.dev/
- clig.dev on GitHub — https://github.com/cli-guidelines/cli-guidelines
- Charm — https://charm.land/ and "The Next Generation of the Command Line" — https://charm.land/blog/the-next-generation/
- gum (charmbracelet/gum) — https://github.com/charmbracelet/gum
- Lip Gloss (charmbracelet/lipgloss) — https://github.com/charmbracelet/lipgloss
- Elm, "Compiler Errors for Humans" — https://elm-lang.org/news/compiler-errors-for-humans
- Elm, "Compilers as Assistants" — https://elm-lang.org/news/compilers-as-assistants
- jamalambda, "Elm — Amazing, Informative, Paternalistic Error Messages" — https://jamalambda.com/posts/2021-06-13-elm-errors.html
- Clang, "Expressive Diagnostics" — https://clang.llvm.org/diagnostics.html
- Rust compiler diagnostics guide — https://rustc-dev-guide.rust-lang.org/diagnostics.html
- Caleb Meredith, "Writing Good Compiler Error Messages" — https://calebmer.com/2019/07/01/writing-good-compiler-error-messages.html
- Jeff Dickey, "12 Factor CLI Apps" — https://jdxcode.medium.com/12-factor-cli-apps-dd3c227a0e46
- NO_COLOR standard — https://no-color.org/ (source: https://github.com/jcs/no_color)
- FORCE_COLOR standard — https://force-color.org/
- Julia Evans, "Terminal colours are tricky" — https://jvns.ca/blog/2024/10/01/terminal-colours/
- baker.is, "In Defense of Emojis in Logs" — https://baker.is/posts/in-defense-of-emojis-in-logs/
- HN, "no emojis please, ever" — https://news.ycombinator.com/item?id=25311114
- Yarn `--no-emoji` discussion — https://github.com/yarnpkg/yarn/issues/960
- Smyekh, "Terminal Joy: Fortune, Cowsay, Figlet, Lolcat" — https://medium.com/@Smyekh/terminal-joy-how-fortune-cowsay-figlet-and-lolcat-add-life-to-my-developer-workflow-b5b1c6b10474
- FIGlet — https://ezascii.com/blog/what-is-figlet-and-what-can-you-do-with-it
