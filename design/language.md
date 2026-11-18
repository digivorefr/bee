# Bee — design language

Founded with `/rocket:studio` (three intents: world, references, counterpoint; key images in `.roc/rocket/studio/intents/main-window/1/`). The operator delegated evaluation; the mix below is the lead's call.

## Intent

Bee is a quiet desk where a request reads as one document in wire order and its response is the facing page. Only what the request has is on the page; what is written is outlined, what is read is bare; honey marks what is live; a secret is a sealed token whose value is never drawn. The one flourish is the comb: it waits in the far corner of an empty page and honey flows through it while a request is in flight.

## Composition

- **No tab rows, anywhere.** A request and a response are documents made of sections (disclosure rows). A closed section rests as one line summarising its content; an absent part is not on the page and waits in one quiet `Add` row.
- **Request line** at full width on top: Method, URL, Send. Under it, one line says where it goes: `Sends to <resolved address>`.
- **Two facing pages** under the request line, split by one hairline: request left, response right, same section order (Headers, Body, script ↔ Headers, Body, Tests, Variables set). Narrow window or `Response below` setting: the response stacks under the request.
- Request sections, wire order: Path variables, Parameters, Authorization, Headers, Body, Pre-request script, Post-response script, Settings. Path variables follow the URL: the section is there when the URL has `:name` segments, and can be neither added nor removed.
- Response: status line (Status · Time · Size) is its headline; then Headers, Body, Tests, Variables set, Console, Request sent.
- **Sidebar** (system glass): New request, Collections (tree), Environments (active one marked `Active`), History. Methods are quiet monochrome capitals.
- **Forks** stand under their original in the sidebar. A fork's page has the request line, then one line that says whose fork it is and what it changes, with Merge and Discard.
- **Toolbar**: title + breadcrumb leading; the Environment capsule trailing. Nothing else.
- One request at a time; the sidebar is the navigation. Edits save themselves: no dirty state, no Save.

## Signature

- **Two voices.** SF Mono for everything that travels on the wire (URL, header lines, bodies, scripts, variable names); system font for everything Bee says.
- **Three sizes.** 11 (labels, captions), 13 (default), 15 (request line, status line). Hierarchy by weight and tone before size.
- **Two inks** on paper: primary and secondary label colors. **Honey `#F2B90C`** marks what is live: it fills Send (ink text on it), the cell of the active environment, and the comb while a request is in flight; its deep step `#8A5A00` (light) / `#F2B90C` (dark) is the focus ring and caret.
- **The cell.** Bee's one mark is a hexagon standing on a point. A capped cell (filled, a glyph cut in paper) says how a status or a test turned out; a collection is a cell in the sidebar; the comb is cells. No circles, badges or pills beside it.
- **The comb** is drawn only where there is nothing to read: the response page before the first send and while sending, and the page when nothing is selected. It grows from the bottom trailing corner and fades toward the text; a few cells hold honey. It never sits behind content.
- **Fork ground.** A fork is told from the request of the collection at a glance: its whole page is on blueprint paper (`#F1F5FB` / `#1A2029` dark) with a 3 pt rule down its leading edge, and its mark is an empty cell in blueprint ink (`#33568A` / `#8FB4E8`). The original that has forks keeps a full cell. Blueprint is used for nothing else.
- **Status colors** only on status and test marks, always with a glyph and words: positive `#1A7F37` / `#3FB950` dark, warning `#9A6700` / `#D29922`, negative `#C6372B` / `#F85149`. A 418 gets a cup.
- **Outline rule.** 1 px outline, radius 8, around what can be written or pressed (fields, editors, pop-ups, secondary buttons). Nothing around what is read. No separators on the paper except the hairline between the two pages; grouping by space.
- **Spacing** 4 · 8 · 12 · 16 · 24 · 32. 24 between sections, 8 from a heading to its content, page inset 24.
- **Variable token**: `{{name}}` keeps its braces on a neutral ground (radius 5); in the URL a path variable `:name` is a token too. A token without a value is drawn in the warning color. A secret adds a lock glyph; its value is never rendered, anywhere, unless the person reveals it.
- **Syntax**: ink, secondary, and two quiet hues (strings, numbers). No rainbow.
- Radii: window and sidebar by the system, fields 8, tokens 5, Send capsule.

## Motion

- Nothing moves on load, on selection, on hover, or when the environment switches.
- A section folds in 200 ms ease-out. The response fades in over 160 ms, opacity only.
- Send becomes Cancel at once; the Time fact counts elapsed time where it will be read. Meanwhile honey goes round a small cluster of cells beside "Sending…" and flows through the comb from its corner; both stop when the response arrives.
- A revealed secret hides again when focus leaves. Reduce Motion: every animation is instant.

## Lexicon (interface copy, English)

Request · Fork (Merge / Discard / Original) · Agent (Allow / Deny) · Method · URL · Path variable · Parameter · Header · Authorization · Body · Response · Status · Time · Size · Collection · Folder · Environment · Active · Variable · Secret · Pre-request script · Post-response script · Test (Passed / Failed) · History · Send / Cancel · Reveal / Hide.

Sentence case everywhere. Verbs on buttons. Errors say what happened and what to do.

## Do / Avoid

- Do show secrets as sealed tokens or `••••••`; reveal is explicit, authenticated, and temporary.
- Do keep one primary action per page (Send).
- Avoid badges, counters beyond a quiet number after a section title, colored method pills, icon-only toolbars, grid lines, nested panels, and any second ornament: the comb is the only one.

## Departures from default frame rules

- "Set body text between 15 and 25 pixels" · native macOS text is 13 pt; the window holds labels, data and code.
- "Follow the conventions users already know" · sections instead of tab strips, so a header using a secret and the script that sets it are read together.
- "Design the narrow screen first" · a Mac window is designed at working width; narrower, the response stacks, then the sidebar folds.
