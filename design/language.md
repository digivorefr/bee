# Bee — design language

Founded with `/rocket:studio` (three intents: world, references, counterpoint; key images in `.roc/rocket/studio/intents/main-window/1/`). The operator delegated evaluation; the mix below is the lead's call.

## Intent

Bee is a quiet desk where a request reads as one document in wire order and its response is the facing page. Only what the request has is on the page; what is written is outlined, what is read is bare; honey is kept for Send; a secret is a sealed token whose value is never drawn.

## Composition

- **No tab rows, anywhere.** A request and a response are documents made of sections (disclosure rows). A closed section rests as one line summarising its content; an absent part is not on the page and waits in one quiet `Add` row.
- **Request line** at full width on top: Method, URL, Send. Under it, one line says where it goes: `Sends to <resolved address>`.
- **Two facing pages** under the request line, split by one hairline: request left, response right, same section order (Headers, Body, script ↔ Headers, Body, Tests, Variables set). Narrow window or `Response below` setting: the response stacks under the request.
- Request sections, wire order: Parameters, Authorization, Headers, Body, Pre-request script, Post-response script, Settings.
- Response: status line (Status · Time · Size) is its headline; then Headers, Body, Tests, Variables set, Console, Request sent.
- **Sidebar** (system glass): New request, Collections (tree), Environments (active one marked `Active`), History. Methods are quiet monochrome capitals.
- **Toolbar**: title + breadcrumb leading; the Environment capsule trailing. Nothing else.
- One request at a time; the sidebar is the navigation. Edits save themselves: no dirty state, no Save.

## Signature

- **Two voices.** SF Mono for everything that travels on the wire (URL, header lines, bodies, scripts, variable names); system font for everything Bee says.
- **Three sizes.** 11 (labels, captions), 13 (default), 15 (request line, status line). Hierarchy by weight and tone before size.
- **Two inks** on paper: primary and secondary label colors. **Honey `#F2B90C`** fills Send only (ink text on it); its deep step `#8A5A00` (light) / `#F2B90C` (dark) is the focus ring and caret.
- **Status colors** only on status and test marks, always with a glyph and words: positive `#1A7F37` / `#3FB950` dark, warning `#9A6700` / `#D29922`, negative `#C6372B` / `#F85149`.
- **Outline rule.** 1 px outline, radius 8, around what can be written or pressed (fields, editors, pop-ups, secondary buttons). Nothing around what is read. No separators on the paper except the hairline between the two pages; grouping by space.
- **Spacing** 4 · 8 · 12 · 16 · 24 · 32. 24 between sections, 8 from a heading to its content, page inset 24.
- **Variable token**: `{{name}}` keeps its braces on a neutral ground (radius 5). A secret adds a lock glyph; its value is never rendered, anywhere, unless the person reveals it.
- **Syntax**: ink, secondary, and two quiet hues (strings, numbers). No rainbow.
- Radii: window and sidebar by the system, fields 8, tokens 5, Send capsule.

## Motion

- Nothing moves on load, on selection, on hover, or when the environment switches.
- A section folds in 200 ms ease-out. The response fades in over 160 ms, opacity only.
- Send becomes Cancel at once; the Time fact counts elapsed time where it will be read.
- A revealed secret hides again when focus leaves. Reduce Motion: every animation is instant.

## Lexicon (interface copy, English)

Request · Method · URL · Parameter · Header · Authorization · Body · Response · Status · Time · Size · Collection · Folder · Environment · Active · Variable · Secret · Pre-request script · Post-response script · Test (Passed / Failed) · History · Send / Cancel · Reveal / Hide.

Sentence case everywhere. Verbs on buttons. Errors say what happened and what to do.

## Do / Avoid

- Do show secrets as sealed tokens or `••••••`; reveal is explicit, authenticated, and temporary.
- Do keep one primary action per page (Send).
- Avoid badges, counters beyond a quiet number after a section title, colored method pills, icon-only toolbars, grid lines, nested panels.

## Departures from default frame rules

- "Set body text between 15 and 25 pixels" · native macOS text is 13 pt; the window holds labels, data and code.
- "Follow the conventions users already know" · sections instead of tab strips, so a header using a secret and the script that sets it are read together.
- "Design the narrow screen first" · a Mac window is designed at working width; narrower, the response stacks, then the sidebar folds.
