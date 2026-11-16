# SipAI

A native Swift / SwiftUI desktop app for macOS that does two things:
chatting with any of 20 built-in AI providers (plus anything
OpenAI-compatible), and living inside your Claude Code, Codex and Kimi
Code sessions. Chats, notes, roles, agent transcripts that stream as they
happen, inline permission approvals, and scheduled agent tasks the app
fires itself.

Everything is local: your keys, your chats, your notes. Chat requests go
straight from your Mac to the provider you picked. The only calls SipAI
makes on its own are update checks — once a day for SipAI itself, and
every eight hours for the agent command-line tools it finds installed —
which send nothing about you and can each be turned off in Settings (and,
if you switch on automatic tool updates, a check that finds a newer
version runs that tool's own update). Agent turns, sign-ins, the
plan-usage window and SipAI's questions about a tool's models and login
all run that tool's own command-line program, which talks to its own
service with its own login; installing a tool from **Settings → Agent
Initialization** downloads the vendor's own installer (for Codex,
OpenAI's release package from GitHub).

Created by Yizhan Huang (黄一展). MIT licensed.

---

## Download

### [**Download SipAI for macOS →**](https://github.com/YZCODE01/SipAI/releases/latest)

Open the `.dmg` and drag **SipAI** into your Applications folder. The
build on that page is signed with a Developer ID certificate and
notarized by Apple, so it opens on the first double-click — no Gatekeeper
detour.

Requires **macOS 15 (Sequoia) or later**. Bring an API key from any
supported provider, an agent CLI, or both — [First
launch](#first-launch) says where each is set up.

Once installed, SipAI keeps itself up to date: it asks
`updates.sipai.dev` once a day, shows you the release notes, and installs
nothing until you say so. Turn it off in **Settings → Updates**.

Rather build it yourself? See [Build and run](#build-and-run) — a copy
you compile to run locally never offers itself updates, on purpose.

---

## Contents

- [Requirements](#requirements)
- [Build and run](#build-and-run)
- [First launch](#first-launch)
- [The window](#the-window)
- [Search](#search)
- [Chats](#chats)
- [Notes](#notes)
- [Agent sessions](#agent-sessions)
- [Codex](#codex)
- [Kimi Code](#kimi-code)
- [Skills](#skills)
- [Scheduled tasks](#scheduled-tasks)
- [Settings](#settings)
- [Data and storage](#data-and-storage)
- [Project structure](#project-structure)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Requirements

| What | Which |
|---|---|
| **macOS** | 15 (Sequoia) or later — the transcript relies on `ScrollPosition` and `onScrollGeometryChange` |
| **Xcode** | 16 or later (Swift 5 language mode), to build from source |
| **For chats** | An API key from any supported provider. A local server (Ollama, LM Studio, vLLM, …) works too — add it through **Custom (name & URL)** with its base URL |
| **For agent sessions** | [Claude Code](https://docs.anthropic.com/claude/docs/claude-code), [Codex](https://developers.openai.com/codex/cli) and / or [Kimi Code](https://github.com/MoonshotAI/kimi-code). **Settings → Agent Initialization** installs each with its vendor's own installer (for Codex, OpenAI's release package) and signs it in — no npm, node or Homebrew needed — or install one in Terminal (`curl -fsSL https://claude.ai/install.sh \| bash`, `npm install -g @openai/codex`, `curl -fsSL https://code.kimi.com/kimi-code/install.sh \| bash`). Any one of them, signed in, is driven fully from inside the app |

You need at least one of the last two.

---

## Build and run

From the repository root:

```bash
open SipAI-macOS/SipAI.xcodeproj
```

⌘R builds and launches. From the command line:

```bash
xcodebuild -project SipAI-macOS/SipAI.xcodeproj -scheme SipAI \
    -configuration Debug build
```

The built app lands in
`~/Library/Developer/Xcode/DerivedData/SipAI-*/Build/Products/Debug/SipAI.app`.

### Signing a build of your own

Nothing to set up: the project signs **to run locally** (ad hoc) out of
the box, so a fresh clone builds with no Apple account and no edits to
the project.

That costs one thing. macOS identifies an ad-hoc build by the exact bytes
of its binary, so every rebuild looks like a different app and asks again
for access to Desktop, Documents and Downloads — which agent sessions
need. If you're going to *run* the app rather than just build it, sign it
as yourself. Create `SipAI-macOS/Local.xcconfig` — it's gitignored, so it
stays on your machine — in one of two shapes.

**With an Apple developer account**, one line is enough:

```
SIPAI_TEAM = ABCDE12345
```

That is your ten-character Team ID, from Xcode ▸ Settings ▸ Accounts or
from developer.apple.com. The signing identity follows from it.

**Without one**, make a self-signed certificate — Keychain Access ▸
Certificate Assistant ▸ Create a Certificate, any name, type **Code
Signing** — and name it:

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Your Identity Name
```

Either shape replaces the per-build hash with a stable requirement, so
the folder grants survive rebuilds. Expect one prompt per folder after
the first build under the new identity, then none. And unlike picking a
team in **Signing & Capabilities**, neither writes anything into
`project.pbxproj`, where it would break the build for everyone else.

One trap if you smoke-test a **Release** build locally: Release enables
the hardened runtime, which enables library validation, which requires
the app and the Sparkle framework it embeds to share a Team ID. Ad-hoc
and self-signed certificates have no Team ID, so such a build signs
cleanly, passes `codesign --verify`, and then dies at launch with
`Library not loaded: @rpath/Sparkle.framework/…`. Build it with
`ENABLE_HARDENED_RUNTIME=NO` instead of weakening the setting in the
project — a distribution build needs both the hardened runtime and
library validation.

---

## First launch

On a fresh install the app opens a one-page welcome — the logo, three
bullets, **Get Started** — and nothing after it, in a window sized to the
screen (about 70 % of it, at most 1200 × 800). Get Started lands in the
main window, which explains itself from there:

- The chat page, while no chat model is configured, says what a chat is
  (a message sent straight to a model provider's API on your own key)
  and how to add a model: the model chip at the lower right of the chat
  box, or **Settings → Chat Settings** — where a short explanation above
  the model list says the same and points anyone who would rather use a
  subscription at an agent session's **Chat only** mode. The line
  disappears the moment a model exists.
- The sidebar lists an agent (Claude Code, Codex, Kimi Code) only when
  its command-line tool is **installed and signed in**. Until every
  supported agent is, an **ADD AGENTS** row (or **ADD MORE AGENTS** once
  some are) at the bottom of the sidebar opens **Settings → Agent
  Initialization**, where each agent can be installed, signed in, hidden or
  deleted — see [Settings](#settings).

Chat models are added from **Add Model** — in the composer's model
picker, or in **Settings → Chat Settings**.

---

## The window

```
┌──────────────────┬─────────────────────────────────────────────┐
│  Left sidebar    │  Centre pane                                │
│                  │                                             │
│  Notes           │   • a chat, or                              │
│  <your folder>   │   • an agent session transcript, or         │
│  Chats           │   • a scheduled task's page, or             │
│  Chat groups     │   • a note, or                              │
│  Claude Code     │   • a Settings section                      │
│  Codex           │                                             │
│  Kimi Code       │   with its composer pinned to the bottom    │
│  ⚙ Settings      │                                             │
└──────────────────┴─────────────────────────────────────────────┘
```

- **Sections collapse** independently and **drag into the order you
  want** — grab a section header and move it; the order persists.
  **Notes**, **Chats** and **Chat groups** also have a … menu on their
  header whose **Hide** takes the section off the sidebar (nothing in it
  is deleted); **Settings → Display → Show sections** brings it back,
  in the place it had.
  ⚙ Settings is pinned at the bottom, and is a button rather than a
  section: it opens a menu of Settings' sections, and picking one turns
  the window into Settings — the sidebar lists the sections, the chosen
  one fills the centre pane, and **Back to app**, in the Settings row's
  place, returns to whatever you had open. A blue download icon beside
  **Settings** means an update is on offer.
- **Drag the divider** to resize the sidebar. ⌃⌘S, or the toolbar button
  next to the traffic lights, hides it entirely. Beside it in the toolbar:
  the magnifier (search), the agent session view — Compact view's switch,
  shown once an agent is set up — and the T for plan usage.
- **Every row has a … menu** on hover or right-click: chats rename / move
  / delete, notes rename / save as Markdown or PDF / delete, agent
  sessions rename / delete / file into a group, and scheduled tasks
  **Mark all as read** (for their runs) / rename / file into a group /
  **Delete definition** / **Delete all**
  (filing into a group is offered while the list is grouped by Custom). An agent session's
  menu also has **Copy session ID** — the tool's own id for it, the one
  `claude --resume`, `codex resume` and `kimi --session` take, copied as
  plain text; pasted into an agent session's message box it shows on a
  grey background.
- **Sections appear when they're relevant.** The local-files section
  exists only once a dedicated folder is configured, and takes that
  folder's own name; an agent's section — **Claude Code**, **Codex**,
  **Kimi Code** — appears only while its command-line tool is installed
  and signed in, and not hidden in **Settings → Agent Initialization**.

The centre pane shows exactly one thing at a time, and switching never
costs you a half-written message — unsent composer text is stashed per
conversation and restored when you come back. A new session you haven't
sent yet waits the same way under the **+** you started it from, with its
schedule, its skills and the chips you changed on it, so each group's
**+** — and **+ New session** — keeps its own. Every other chip follows
that **+**: a group's **+** starts on the chips of that group's newest
session run from SipAI (its mode, model, effort and speed), the one you
sent a moment ago included, and **+ New session** on your latest choices
for that agent. Skills and a schedule are never carried over there: a new
session started from a **+** begins with no schedule and with only the
skills pinned with **Start New Sessions With It**, whatever an earlier
session or task used.

**Plan usage, one click away.** When any agent tool on the Mac is
signed in to a plan — a Claude subscription, a ChatGPT plan for Codex,
a Kimi Code membership — a T icon appears beside the toolbar magnifier.
Click it and each plan reports itself: the current 5-hour session and
weekly windows for Claude Code (plus the usage-credits budget, once
that has ever been switched on), the weekly and per-model limits and
any free limit resets for Codex, and the 5-hour and monthly limits for
Kimi Code (a weekly one too on older plans; the monthly one split between
Kimi and Kimi Code), plus any Extra Usage wallet — each with a bar, how
much is used and when it resets; the Kimi Code card names the membership
as Kimi does. The
figures are fetched when the window opens — by the tool itself, as its
own process, with its own login; SipAI never sees a login token — and the
footer says how old they are; the arrow beside it asks again. **Learn
more**, beside the window's title, opens **Settings → Usage**: the same
figures with more of what each tool reports — Claude Code's own account of
what is using your limits on this Mac, laid out as a table; Codex's
credits, workspace spend cap, limit resets, its lifetime, peak-day and
streak figures and a year of token activity, a square a day (point at one
for its exact token count) — and a link to each tool's own usage page.
A free Codex limit reset can be used there, through Codex's app server,
once you confirm it in Codex's own words; using one cannot be undone.
Agents running on an API key are not listed in the window, because no
tool reports an account figure for one;
Settings → Usage gives each a line saying where it is billed instead,
with a link to the provider's page where there is one (none for a key
billed through a cloud provider or sent to another vendor's endpoint).
If every agent is on an API key, the icon stays hidden.

**Closing the window parks the app rather than quitting it.** Agent
runners, session tailers and the scheduled-task timer keep working, and
the Dock icon reopens the window with everything where you left it.
Quitting is what stops work: ⌘Q interrupts any turn in flight the way the
Stop button does, rather than orphaning a `claude` process mid-edit.

---

## Search

Two finders, one wider than the other:

- **⇧⌘F searches everything** (the toolbar magnifier does the same) —
  every chat's messages, every note's body, and every agent session's
  transcript for each agent listed in the sidebar, tool calls and tool
  results included.
  Results stream in newest-first under **Chats** / **Notes** / one
  section per agent, each row with a two-line snippet around the match;
  ↑/↓ chooses, Return opens. Opening a chat or session lands on the first
  match with the find bar already filled in; opening a note just opens
  it. Long lists cap with "Showing the first N — narrow the search for
  more."
- **⌘F finds inside the open conversation** — a bar at the top of a chat
  or agent transcript with a match counter, previous / next (⇧⌘G / ⌘G),
  and every match highlighted in place. Matching ignores case and
  accents. A session whose history is only partly loaded says so and
  offers to **search the whole session**. Chats also get a magnifier in
  the input card; agent sessions get one in the composer strip.

---

## Chats

A chat talks directly to a model over your API key.

- **Rich rendering.** Fenced code blocks (```` ``` ```` or `~~~`) with a
  dim language label, long lines wrapped, and **Copy** and **Save** in
  the corner when you point at one — Save asks where to put the file and
  suggests an extension from the block's language. Also headings,
  horizontal rules, ordered / unordered / nested lists, block
  quotes, tables (with per-column alignment), bold / italic / inline
  code, auto-linked URLs, and mathematics: a displayed equation
  (`$$…$$`, `\[…\]`) is typeset — fraction bars, limits, matrices,
  growing brackets — with **Copy LaTeX** on right-click, and inline math
  is translated to symbols (`\pi` → π, `x^2` → x², `H_2O` → H₂O,
  `\mathbb{R}`, …). Inline code is shielded from the LaTeX pass, so
  `snake_case` survives intact. Paragraphs, list items, quotes, table
  cells and code can be selected and copied, one block at a time, and
  hovering one of your own messages reveals a copy button in its
  corner. Of the addresses a link can carry, only `http`, `https` and
  `mailto` are opened — a model's reply, a note or an agent's tool result
  can put any address behind any words, and the rest of what macOS would
  accept there opens applications rather than pages. A link to a file on
  your Mac (Codex writes one for every file it mentions) is SipAI's own:
  it shows the file's path after its words — relative to the session's
  folder when it is inside it — and a click opens a document in its
  usual app, shows anything that would run (an app, a script, an
  installer) in Finder instead, and opens a folder in Finder; a file
  that isn't there is greyed out.
- **The input card** holds everything: the text box (Enter sends,
  Shift+Enter newlines), **+** to attach files, a **notebook** button
  that turns the conversation into a note, a find magnifier, chat-group
  and role chips (each appears once enabled in Settings → Display), the
  **model picker**, and a send button that becomes a stop button while a
  reply is in flight.
- **Attachments** travel one of two ways. Text files — source, Markdown,
  CSV — are inlined into your message and stay in the chat, so a later
  question about the file still has the file; a long one is cut at
  200,000 characters and says so. Images and PDFs go as content blocks
  on the one request that carries them, to models that can read them,
  and are never stored. Each staged file shows as a chip above the text
  box — its name, its size and how it will travel, with ✕ to remove it —
  and a file that can't be used is refused with an explanation when you
  attach it, not when you send.
- **Replies arrive complete**, not streamed — the app shows a "Sipping…"
  indicator with a running clock while it waits, and Stop cancels. A
  reply cut short by the model's output limit is flagged ("Response may
  be incomplete") rather than left looking whole.
- **Assistant messages are headed by the model id and how long the reply
  took**; your own messages name their attachments.
- **Long chats open on the newest messages** — 40 at a time, with a
  **Show earlier** button above.
- **Edit any of your messages.** Hover a message you sent, click the
  pencil and edit the text (with VoiceOver, choose **Edit this message**
  from the message's actions; **Copy this message** is there too).
  **Send** replaces that message and the replies after it, in the same
  chat. **Create Branch** copies everything above it into a new chat —
  titled "X (branch)" — and sends your edit there, leaving the original
  untouched.
- **Chat groups** are folders for related chats. Create one from the
  section's **+ New group** row, or move a chat in from its … menu or the
  composer's chat-group chip. Groups drag into whatever order you want;
  deleting one removes its chats too, after a warning that says so.
- **Titles** start as the first few words of your first message; rename
  anytime from the row's … menu.
- **Switching chats mid-reply is safe.** The answer is delivered to the
  chat that asked, even if you've moved on, and errors never surface on
  the wrong conversation. A chat waiting on its reply shows a pulsing dot
  in the sidebar — and if its group is folded, or the whole Chats or
  Chat groups section is collapsed, the dot sits after that name
  instead. A reply that arrives while you are elsewhere leaves a steady
  blue dot on its chat until you open it, and is said beside the logo
  for five seconds (“OpenAI chat · Research finished”) — click it to
  open the chat. Chats waiting on a reply, then chats with a reply you
  have not read, are listed first.
- **The empty state** is editable: click the tagline next to the logo and
  write your own.

Nothing you type is intercepted as a command — every message goes to the
model as written. The actions live on controls instead: the composer
buttons, a row's … menu, or Settings.

---

## Notes

The notebook button (in a chat composer or an agent composer) asks the
model to turn the conversation into a structured Markdown note —
headings, key points, decisions, action items — in the language the
conversation used. With **Show note prompt** on (Settings → Display) the
button first offers *Direct note* or *Add prompt…* so you can steer it.

Notes appear in the sidebar's **Notes** section and open in the centre
pane, rendered, with the writing model and date in the title bar. The
pencil in the title bar switches to **editing** — a monospaced Markdown
source view that autosaves as you type, and again when you switch away or
quit, so there is no Save button to forget. Edits touch the body only:
the note's metadata header is preserved byte for byte, and retitling the
body's top heading renames the note everywhere. If a write fails, an
orange *Couldn't save* badge says so and your text stays put.

From a note's … menu you can rename it, save it as Markdown or as PDF,
or delete it. Which model writes notes is set in **Settings → Files &
Notes → Note generating model** — useful if you want a thinking-heavy
model for notes and a fast one for chat. A note is always written by one
of your chat models, so the notebook button needs one configured.

---

## Agent sessions

An agent session is the Claude Code, Codex or Kimi Code CLI running on
your Mac, driven from a SwiftUI window instead of a terminal.

With `claude` on your `PATH` **and signed in**, the **Claude Code**
sidebar section lists every session under `~/.claude/projects/` plus the
scheduled tasks under `~/.claude/scheduled-tasks/`, and **+ New session**
starts a fresh one (grouped by Custom, that row is **+ New group**, and a
session starts from its group's **+**). `codex` and `kimi` get their own sections on the same
terms. An agent that is not installed, not signed in, or unticked in
**Settings → Agent Initialization** lists nothing at all — no section, no search
results, no usage figures, and its scheduled tasks pause; the sessions
stay in the CLI's own store and come back the moment the agent is listed
again — installed, signed in and ticked.

SipAI reads those files in place — it keeps no copy of them, so a session
created in Terminal shows up here, and one created here shows up there.

No CLI's interactive TUI is embedded. Each is driven through its print
mode or its own protocol server — `claude -p --output-format
stream-json`; `codex app-server`, the front end Codex's own apps use (and
`codex exec --json` for Chat only and an older Codex); `kimi acp` and
`kimi --prompt --output-format stream-json` — and SipAI renders the event
stream itself, which is what makes inline approvals, live transcripts and
in-app scheduling possible.

### The transcript

Sessions render as a conversation, not as a terminal log:

- **User and assistant turns** as message bubbles with full Markdown.
- **Tool activity as collapsible chips** — chevron, icon, tool name, and
  a dim one-line summary (`Bash(npm test)`, `Update src/main.swift`).
  Click one to expand its full input and the result folded in beneath —
  for a Codex edit, each file with its diff. A row with nothing more to
  show — a Codex web search with its terms beside its name, or *Viewed
  image* with the file Codex looked at — does not open. A row reads the
  same while the agent works and after the session is reopened.
- **Errors** stand out in their own row.
- **Compact view**, for anyone who would rather read the answers than the
  work: the icon between the toolbar magnifier and the T opens a small
  window with its switch (also in Settings → Display, and View → Agent
  Session Compact View, ⌃⌘O). With it on, each of the agent's answers is
  **one line** with its final message under it. The line holds everything
  between your message and that final message — the agent's thinking, its
  tool calls, the messages it wrote along the way, its questions with your
  answers, a plan you reviewed, notices such as a compacted conversation,
  and a background task reporting back with the agent's reply to it — and
  shows the newest of them while the agent works (*Running npm test*,
  *Editing main.swift*, the first line of a message), then what it did
  (*Edited 2 files · Ran 3 commands · Read 4 files · 2 messages*, an
  orange mark if a step failed). A click opens it into each step, a
  thought, a tool call or a message, and a step opens again into its
  details. A question, a plan or an approval still shows its card while it
  waits for you, and joins the line once you answer. Your own messages
  stay as they are, including one you send while the agent works; the
  error or stop that ends an answer shows with its final message; the
  agent's name shows once, at the top of each answer; only the drawing
  changes. How much thinking a line holds is
  each tool's own setting: Claude Code saves short progress notes by
  default and fuller summaries with its `showThinkingSummaries` setting
  (which SipAI then asks for, as Claude Code's terminal does), Codex
  saves summaries only when its config sets `model_reasoning_summary`,
  and Kimi Code saves its model's thinking whenever the model thinks.
- **Session plumbing stays out of the way** — the turn's duration and the
  session's context usage live on the composer, not between your
  messages.

Long sessions open on the newest turn with a capped window of history and
a **Show earlier** button above it — always at the top, however long a
turn runs. Scroll up while a turn streams and the page holds still while
you read, instead of shifting with every new row. Opening a session you've
already visited is instant, because parsed transcripts are cached.

### Live streaming, wherever the turn came from

- **Turns you start here** stream in line by line, for all three agents,
  because SipAI runs the agent behind a pty and reads it on a background
  queue.
- **Turns started elsewhere** — a `claude`, `codex` or `kimi` in
  Terminal, another app, a Claude Desktop scheduled run — stream in too,
  for any session you have opened in SipAI since launching it. SipAI
  follows the session's own file (Claude Code's JSONL, a Codex rollout, a
  Kimi wire), batching and coalescing updates so a fast external turn
  can't wedge the window, and the sidebar row shows the session as live
  while it works.
- **A dropped connection is retried, not abandoned**: Codex and Kimi
  Code retry by themselves, behind a single notice row in their own
  words that the next attempt replaces (Kimi Code 2.6.1 no longer says
  when it retries, so its turn shows no such row). When the agent gives
  up, the turn ends on its own error — and a Kimi Code session shows it
  again when you reopen it. After five minutes of total
  silence, a "No output from \<agent\> yet" row appears with the agent's
  own error output and says what to check if the silence lasts: your
  network connection and settings, and whether the provider is down — a
  blocked route looks exactly the same as a slow turn.

### Reading a session's state

In the sidebar, a session that is doing something shows a signal — a
dot in place of its icon, or a badge after its name:

| Signal | Meaning |
|---|---|
| pulsing orange dot | a turn is running — started here, or by another terminal |
| steady blue dot | the run finished while you were elsewhere, and you have not opened the session since |
| yellow badge | waiting for you — a tool call to approve, a plan to review, or a question to answer |
| both | mid-turn *and* waiting on you |

A group you have folded shows the dots after its name for the sessions
it hides — the pulsing orange dot while one is running, the steady blue
dot while one has an unopened finished run, both side by side when both
are true — and so does an agent's section header while the whole
section is collapsed. A scheduled task's row shows them after its name
for its runs, folded or not. The steady dot goes when you open the
session, and survives quitting SipAI. A session you are looking at when
its run ends gets none, and neither does a run you stopped yourself.
A scheduled task's runs are read one by one, as each is opened — its
row keeps the steady dot while any of them is unopened. A turn run in a
terminal lights the dot for Claude Code, Codex and Kimi Code alike,
for any session you have opened in SipAI since launching it.

The same moments are said beside the logo at the top of the sidebar,
in a sky-blue bubble in place of the SipAI name: a session waiting for
you (✋ “Claude Code · SipAI needs you”) for ten seconds, a finished run
(“Claude Code · SipAI finished”, or “failed”) for five. The group is
the one the session's row sits under — its custom group when you group
by Custom, its folder otherwise. A long one wraps onto a second line,
the bubble growing from the logo's middle up to the logo's height.
Click the bubble to open the session; point at it for the whole
sentence. It goes early once the card is answered or the session
opened, and is never shown for the session you are looking at or a run
you stopped. Several take turns, each its full time, in place of an
update waiting beside the logo (see Updates). One
that comes while SipAI is behind another app, or while a sheet covers
the logo, waits and shows once you can see it — unless it has stopped
being true by then, or is a run that finished more than two minutes
before (its steady dot already says so). Settings → Display → **Show notifications beside
the logo** turns them all off.

In the transcript, a **“Sipping…”** spinner fills the gap between your
message and the agent's first output, and an unresolved tool row keeps
its own spinner until the result arrives. Nothing in the transcript
ticks: the clock lives on the composer, on purpose.

**Background tasks.** An agent can start a long command — a build, a
test run — in the background and keep working, so its answer may land
before the command finishes. With Claude Code (2.1.309 or newer) and
Kimi Code the turn then stays open until the task ends and the agent has
reported on it: the composer's clock keeps counting, Stop stays, and a
message you send meanwhile waits above the message box for the turn to
end. Under the answer a line names the task the agent is waiting for, and
a short notice in the agent's own words says when a task finished or was
stopped — the same notice a reopened session shows. A Claude Code Monitor
watch reports every line the watched command prints; a reopened session
shows each as Claude Code's terminal does (*Monitor event: Build exit=0 12s
· sweep results*), and with Compact view on, those notices and the
agent's replies to them sit inside the answer's line. With Claude Code
2.1.310 or newer each task on that line has a Stop of its own, which stops
that task alone (Claude Code keeps no record of that stop, so no notice is
drawn for it). Stop under the message box, or quitting SipAI, stops the
task with the turn. An older Claude Code stops a background task a few seconds after
its answer and says nothing about it, so SipAI has it run every command
in the foreground instead (Claude Code's own
`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`). Codex calls such a command a
background terminal and does not report on it: the turn stays open
until the command ends, with the same line naming it and a Stop beside
it for that command alone, and its result shows in the command's own
row. On a Codex older than 0.159.3, where
Read Only, Workspace Write and Full Access run as a one-shot
`codex exec`, Codex stops the command when its turn ends, and a notice
under the answer says so.

**Messages while a turn runs.** Send stays available while an agent
works: the message waits above the message box. **Steer**, beside it,
hands it to the running turn — the agent reads it at its next step, and
the message is drawn in the transcript where the agent's own record puts
it, the moment the agent takes it. Left alone, it goes as the next
message when the turn ends; × puts it back in the message box, with any
files it carries, so you can change it; and after Stop nothing is sent
by itself. Claude Code (2.1.310 or newer, through its stream-json input)
and Codex (its app-server's `turn/steer`, every mode but Chat only) take
a steered message; a message that opens with a command or loads a skill
waits for the turn's end, as does every message to Kimi Code, which
takes none mid-turn.

**`!` commands, and the tools' cloud sessions.** A line that starts
with `!` is your own shell command, run as each tool's terminal runs one:
directly — no model, no approval, no sandbox — with its output joining
the conversation. That is how each tool's cloud commands work here, as
in its own terminal: `!claude -p "…" --cloud <session id>` messages a
Claude Code cloud session, and `!codex cloud list` and `!codex cloud
exec --env <environment> "…"` reach Codex Cloud. SipAI builds no cloud
features of its own. A new Claude Code cloud session (`claude --cloud
"…"`) needs a terminal window, which no tool's `!` gives it; start it in
Terminal, the Claude app or claude.ai/code. Claude Code's screen commands
(`/teleport`, `/ultraplan`, …) answer "isn't available in this
environment", and `/ultrareview` skips the confirmation Claude Code's
terminal shows before a review starts. A `!` command in a Claude Code
session runs as in Claude Code's terminal — in your own shell with your
aliases and functions, with no input, and in the folder the last one
ended in while that stays inside the session's folder — except that the
folder doesn't carry over to Claude Code's own commands, and a long
command runs until it ends or Stop, where Claude Code's terminal stops it
or moves it to the background once its Bash timeout (2 minutes by
default) runs out. Codex runs a `!` command here exactly as in its
terminal. Kimi Code has no cloud sessions and
offers apps no way to run a `!` command, so a Kimi session sends the line
as an ordinary message, and the composer says so.

A Claude Code turn that was killed — Stop, quit, a crash, a rebuild — is
marked where it stopped with an **Interrupted** row the next time the
session loads. That marker is derived rather than stored, so a session
that turns out to still be alive quietly loses it again. On Codex and
Kimi Code the row appears when you press Stop, and is not rebuilt on
reopen.

### The composer

Under the input box sits a quiet control strip. Everything on the left
says *where and what* this session is; everything on the right says *how
this send will run*, then reports on it:

| Left | Right |
|---|---|
| working folder · schedule · add files · skills · note · find | model · effort · permission mode · turn clock · context usage |

- **Skills** — the little robot — preloads skills into the session; it
  turns orange once one is chosen. See [Skills](#skills).
- **Permission mode, model and effort** apply per send, and each agent
  gets its own vocabulary in those chips — see [the table
  below](#how-the-three-agents-differ). Leave model or effort at
  *default* and no flag is sent at all. The mode chip's **Default** is
  each tool's own default setting: Claude Code's from its settings,
  Codex's own default for the folder (asked of Codex on every turn, so it
  stops for approval on cards where Codex's own app would), and the
  default mode in Kimi Code's config. For Claude Code, the model menu
  lists one row per model alias, named by the model the installed CLI
  runs it as — read from the CLI's own model table, so updating Claude
  Code renames the rows at once — and an **Other models** section
  beneath them with the previous version of each family this Mac has
  run, while the installed CLI still offers it — pick one to pin a
  session to it. The Default row names what a send with no
  model flag actually runs: claude's own configuration (`ANTHROPIC_MODEL`
  or the `model` key in its settings files) when that sets one.
- **Chat only** is the first override in the mode chip, on every
  agent: a turn sent under it carries none of the agent's file or
  command tools and no MCP servers (Codex keeps any you added to its own
  config), so the agent can't read, search or change files or run
  commands — but, like a chat app, it can still look things up on the
  web when a question needs current information. It answers in the
  *same* session, for far less than an agent turn, and the next send in
  any other row continues the conversation with the tools back. Use it to
  talk a plan through, then switch the chip and ask for the
  implementation in the same window. It draws on whatever the tool is
  signed in to, and the chip's hover says which: your Claude plan, your
  Codex limits, your Kimi Code membership — or the API key, billed per
  token. While it is on, a file you attach travels inside the message,
  since the agent has no tool to open it with — text files and PDF text
  in the message itself, an image through the tool's own image input (a
  Kimi Code session that already exists takes none); a folder can't be
  attached — and the placeholder reads *Chat with …*. A Chat only turn
  draws everything before its final message — the model's thinking, its
  web lookups and what it says between them — as **one line** under the
  agent's name, shown once per answer, whether Compact view is on or off:
  while it works, the line names the newest step (*Searching the web for
  “…”*, *Reading python.org*, a thought's first line); once the answer is
  done, it settles into a summary — *Thought · Searched the web 2 times ·
  Read 1 page*, one rule for every agent — that opens on a click into the
  steps, with the final message under it. The look belongs to the turn: switching the chip never restyles turns
  already on screen, and SipAI remembers which turns were Chat only so a
  reopened session looks the same (on this Mac — the agents record no
  such thing). The folder stays what it was: CLAUDE.md / AGENTS.md from it still
  load, and the next agent turn edits there. The row is offered only
  where the installed CLI is recent enough to honour it (Claude Code
  with `--tools`, Codex 0.155.1+, Kimi Code 2.0.1+); in the moments
  before SipAI has read that, Send waits rather than sending a Chat only
  message as an agent turn. A scheduled task can run Chat only too,
  picked on its card; such a run loads no skills.
- **Non-stop** is a switch at the bottom of the mode menu, for an agent
  that can ask: Claude Code, Kimi Code on Default and in its asking
  modes (not where Kimi's own default is Never Ask, in which Kimi asks
  nothing), and Codex on Default and in Plan (on Default an MCP server's
  form can stop a Codex turn — see [When an MCP server
  asks](#when-an-mcp-server-asks)). Off —
  the default — a question the agent asks in the middle of a turn is
  shown to you and the turn waits for your answer (see
  [Questions](#questions)). On, the agent chooses what it judges best
  and the run keeps going to its end even when it has questions. It is
  about questions only: in a mode that asks before it acts, an approval
  card still waits for you, Non-stop or not. With it on, Claude
  Code is told "choose what you judge best, say what you chose, and
  carry on"; Kimi Code's question is dismissed, and Kimi decides for
  itself; Codex's goes unanswered, and Codex goes on with the option it
  recommends; an MCP server's form, yes-or-no or link is declined. A small forward mark on the chip shows it is on, and
  turning it on while a question is on screen answers that one too. In a
  mode that cannot ask, the switch is shown greyed with a line saying
  so. Nothing turns it on but you: a scheduled task runs Non-stop only
  when its card's **Non-stop** box is ticked.
- **Fast mode** is a switch at the bottom of the model menu, for the
  agents that have one. Claude Code's is offered on the models the
  installed CLI gives it to. On a Claude plan it is paid only from usage
  credits — never from the plan's 5-hour and weekly limits, so those
  resetting does not bring it back — and the switch says so in both of
  its states, with a second line when something is in the way (credits
  used up, a rate-limit pause, turned off by your organization). A bolt
  on the chip shows it is requested, struck through when the replies are
  running at standard speed anyway. The usage window's *Usage credits*
  line says whether credits are on.
  Codex has a switch for each of its speeds, as its own terminal has a
  command for each (`/fast`, `/ultrafast`): **Fast mode**, and
  **Ultrafast** when Codex offers it to your account. Which speeds your
  account has comes from the list Codex last downloaded for it, so a
  moment when Codex can't download its list doesn't hide one. Each is
  described in Codex's own words ("2x speed, increased usage"); turning
  one on turns the other off, and off runs standard speed, even where your
  Codex config turns a faster one on. A speed the selected model does
  not have is greyed out, as is one turned off in your Codex config
  (`features.fast_mode`, `features.ultrafast_mode`) or by your
  organization. Until you flip one, the switches show what Codex itself
  would run there — the speed in your Codex config, else the one the
  model starts on in Codex — and say so. Any message can change the
  speed, except in Chat only, where Codex keeps the speed a session
  starts at: a line under the switches says so before the first message,
  and after it the switches are greyed out and show the speed the
  session runs at. A branch keeps its parent's speed. When Codex can't
  use the speed for a message — it couldn't load your account's list in
  time, and runs that message at standard speed — the bolt on the chip is
  struck through and the switch says why. Kimi Code has no
  fast mode:
  its faster option is a separate high-speed model, which appears in the
  model menu when your Kimi config lists it. A scheduled task has its
  own copy of the switches (see [Scheduled tasks](#scheduled-tasks)).
- **The folder** is editable while a session is still a draft, and fixed
  afterwards. A new session resolves its folder from the best evidence
  available — the last folder used, then the newest session on record;
  only a machine with no history at all starts at your home folder.
- **The schedule button** appears on drafts only: a session that already
  exists can't retroactively become a scheduled task. See [Scheduled
  tasks](#scheduled-tasks).
- **Attach files** with **+** (files or folders) or by dropping them on
  the box. Each shows as a chip above the text, as on the chat page —
  its name and size, ✕ to remove it — and your sent message names it
  with a paperclip beside your label. The file stays where it is: only
  its location goes with your message, and the agent opens it itself.
  Under **Chat only** the agent has no tool to open a file with, so the
  file's content travels inside the message instead: the chat page's
  limits apply, plus a ceiling of 200,000 characters of attached text per
  message, because the message travels as one command-line argument, and
  a folder can't go. Files you attached before switching to Chat only are
  read at the switch, and any that can't go come off with the reason.
- **The turn clock** counts up while a turn runs, holds still while a
  card waits for you (a permission, a plan, a question — the turn is
  waiting, not working), and freezes on that turn's total when it lands,
  so the composer always answers "how long?" without a ticking row in
  the transcript.
- **Context usage** ("39%") is how full the session's context window is
  on the newest call — the same figure the agent's own terminal shows —
  with the exact numbers on hover. It is a gauge, not a running total:
  it falls when the agent compacts the conversation to make room, and
  the transcript shows a **Conversation compacted** row when that
  happens (with the before-and-after sizes where the agent records
  them). Near the end of a long Claude Code session, a project file
  such as CLAUDE.md that changed since your last message is attached
  again whole, and Claude Code can refuse the message with "Prompt is
  too long" instead of compacting first; SipAI then sends the message
  once more, and Claude Code compacts the conversation and answers. The
  transcript shows the notice and your message a second time, as Claude
  Code records them.
  When the model's window isn't known the chip shows the token
  count instead. Every agent has one; hide it in Settings → Display.
  On a Codex session the hover carries a **?** — Codex runs models
  OpenAI advertises at 1,050,000 tokens with a default window of 258,400
  usable, about a quarter, and the glyph opens the Help question that
  explains why and lets you raise it.
- **A scheduled run's** transcript carries a read-only tag with the time
  the run finished.
- **The send button becomes Stop** whenever a turn is in flight — for
  turns this app started, and for a headless `claude -p` started
  elsewhere that it can still signal. For any other turn started
  elsewhere — an interactive `claude` in another terminal, or a Codex or
  Kimi Code turn — Stop is shown disabled rather than swapped for a grey
  arrow: that turn stops where it started.

### How the three agents differ

Everything above is common to all three. These are the differences:

| | Claude Code | Codex | Kimi Code |
|---|---|---|---|
| Permission chip | **Default** (Claude Code's own default setting) and its permission modes (`bypassPermissions` … `plan`) | **Default** (Codex's own default setting), **Plan**, and the sandbox modes Workspace Write, Read Only, Full Access — all through Codex's own front end on Codex 0.159.3+ | **Default** (Kimi's own default setting, through Kimi's own front end on Kimi Code 2.1.1+), and Kimi's own **Ask When Needed**, **Never Ask** (the headless run) and **Plan** |
| Chat only | `--tools WebSearch,WebFetch` (pre-approved for the turn), an empty strict MCP config and a plain-assistant system prompt on that turn, plus `--thinking-display summarized` where the installed claude takes it (headless claude otherwise returns its thinking empty); bills what claude is signed in to — your Claude plan, or the API key | the feature switches off as `-c` overrides with web search left live, read-only/never, readable reasoning summaries (`model_reasoning_summary="detailed"`), and the persona on resumed turns only (a thread is never *born* with it); bills what codex is signed in to — your Codex limits, or the API key | the session's own `tool-policy/state.json`, naming every tool but the web lookups, written for the turn and restored after; a new session's first Chat only message goes through kimi's local server and arrives all at once; its thinking is read off the session's wire, the only place kimi records it; bills what kimi is signed in to — your Kimi Code membership, or the API key |
| Mid-turn approvals | inline Allow / Deny cards, and an MCP server's forms and links | in Default and Plan, cards in Codex's own words wherever Codex asks, Plan's questions, the questions Codex asks without stopping, and an MCP server's forms, links and tool approvals; none in the sandbox modes, where the sandbox decides up front (the questions Codex asks without stopping still arrive there) | in Default and its asking modes, cards with Kimi's own answers, its plan reviews and its questions; none in Never Ask, which approves its own tool calls |
| Model chip | aliases named by what the installed CLI resolves them to, read from its own model table; **Other models** for the previous version of each family this Mac has run; the Default row reads claude's own settings | literal Codex model ids, from its catalog (refreshed through Codex itself), your config and recent sessions | aliases from kimi's `config.toml`; a model Moonshot refused for your plan is marked on its row |
| Effort chip | the levels `claude --help` lists (`low` … `max`), per model from the installed CLI's own model table: Haiku takes none, so no chip is shown; Opus 4.6 and Sonnet 4.6 offer Max but not XHigh | per model, from the same sources as the model list | per model, when the model declares any; delivered as an environment variable |
| Fast mode | a switch in the model menu, for the models the installed CLI marks for it, paid only from usage credits on a Claude plan; the chip shows whether replies actually ran fast | a switch in the model menu for each speed — Fast, and Ultrafast when Codex offers it to your account — greyed out on a model without it; off pins standard, and until flipped they follow your config and the model's own default; any message can change it, except in Chat only, where a session keeps the speed it started at; the chip shows when Codex ran a message at standard speed anyway | none (a high-speed model instead, in the model menu when your config lists it) |
| Context usage | live, from each assistant message, over the window claude's own binary states for the model | the rollout's newest usage record, refreshed as the turn runs, over the window Codex enforces (`model_context_window` honoured) | the wire's newest usage record, refreshed as the turn runs, over the model's `max_context_size` |
| Watching a turn started elsewhere | live, for a session opened in SipAI | live, the same — Codex's own lock on the session tells a turn still running from one whose process died | live, the same — a running `kimi` in the session's folder tells the two apart |
| Slash commands | resolved by the CLI itself (`/mcp`, `/model`, `/context`), and the answer is kept with the session | `/compact` and `/review` run as in Codex's own terminal, through its app-server (`/review` opens Codex's review picker: a base branch, uncommitted changes, a commit, or your own instructions); any other is sent to the model as an ordinary message, and the composer says so before you do | in Default and its asking modes, answered by Kimi itself (`/status`, `/usage`, `/help`; `/compact` runs to its end) — shown, not kept; in Never Ask, sent to the model, and the composer says so |
| `!` commands | claude's own headless message for them runs the command line Claude Code's terminal builds — your shell with your aliases and functions, no input, the folder kept between `!` commands (Claude Code 2.1.310+) — then claude is handed the two rows its terminal writes and answers the output, unless `respondToBashCommands` is off; long output goes in claude's own preview-and-file form | its app-server's `thread/shellCommand` (Codex 0.165.0+): a turn of Codex's own, outside the sandbox, no model request; Codex reads it with your next message | sent to the model as an ordinary message — Kimi offers apps no way to run one; the composer says so before you send. A `!` run in Kimi's own terminal is drawn as one |
| Editing a message in place | yes — the edit's turn resumes at the message above it | yes — Codex reverts the session itself (0.162.1 or later) | yes — Kimi's own undo (2.2.0 or later) |
| Branching a session | yes — a new transcript beside the original | yes — a fork Codex itself makes and lists | yes — a session in Kimi's own fork format |
| Plan usage | the 5-hour and weekly windows, from claude's own `/usage` answer, and in Settings → Usage its own account of what is using them; usage credits from its cache | the weekly window, per-model limits and free resets, over Codex's app server, and in Settings → Usage its credits, spend cap and token history; a free reset can be used there | the 5-hour and monthly limits (a weekly one too on older plans; the monthly one split between Kimi and Kimi Code), the Extra Usage wallet and the membership's name, over `kimi web`'s own usage route (a Kimi Code membership login; an API-key provider reports none) |
| Listed when | installed and signed in — the login in `~/.claude.json`, or an API key in claude's environment or settings — and not hidden | installed and signed in (`~/.codex/auth.json`), and not hidden | installed and signed in — a membership login, or an API-key provider in `config.toml` — and not hidden |
| Scheduled tasks | yes | yes | yes |

Model and effort lists are read from each CLI rather than hardcoded, so a
model or level the vendor adds shows up without a SipAI update. Both are
per model where the agent makes them per model: changing model, in the
composer or in a scheduled task's editor, clears an effort the new model
doesn't offer, rather than sending a value it would reject or quietly
replace, and a model with no effort levels shows no effort chip.

### Editing an earlier message

Hover one of your own messages and click the pencil to edit it — with
VoiceOver, choose **Edit this message** from the message's actions. Two
buttons send the edit:

- **Send** goes back to that message in the same session: the message
  and everything after it leave the conversation, and your edit is sent
  in its place — what each agent's own terminal does when you edit an
  earlier message (Claude Code's `/rewind`, Codex's Esc Esc, Kimi Code's
  `/undo`). The session keeps its name, its place in the sidebar and its
  id. Each agent makes the cut itself:
  - **Claude Code** — the edit's turn resumes at the message above the
    one you edited. The replaced turns stay in the transcript file as a
    branch Claude Code never loads again, and SipAI doesn't draw them.
  - **Codex** — Codex reverts the session to before that message's turn
    and carries on in a new file of the same session.
  - **Kimi Code** — Kimi Code's own undo takes back the turns from that
    message on.
- **Create Branch** starts a new session from that point and keeps this
  one as it is (next section).

Send is greyed out, with the line under the box saying why, when the
agent summarised the conversation after that message, or when the
installed tool is too old to go back. Editing your very first message
starts a new session instead, as Create Branch does: there is nothing
above it to go back to. Like every branch, it carries on with this
session's mode, model and effort. A session rewound in the agent's own
terminal is read the same way — SipAI shows the conversation the agent
continues from.

### Branching a session

Hover one of your own messages, click the pencil, edit the text, and
**Create Branch** forks everything above it into a new session, then
sends your edited text as its first turn. The original session is
untouched, and the branch is a real session of that agent — the agent
itself can resume it. What the branch *is* differs per agent, because
each one keeps sessions differently:

- **Claude Code** — a new transcript file written beside the original,
  holding a copy of everything above the edited message.
- **Codex** — a fork Codex makes itself (the same thing `codex fork`
  does), cut at the turn you edited. Codex records a fork as a
  *reference* to its parent rather than a copy, so a Codex branch
  depends on the original session staying on disk: delete the original
  and the branch keeps only the turns made after the fork, in Codex as
  much as in SipAI.
- **Kimi Code** — a new session directory in the shape `kimi fork`
  writes, holding a copy of the wire up to the edited message.

A branch stays where its parent lives: it runs in the same folder, and
if the parent is filed in a custom group — or is a run of a scheduled
task that is — the branch is filed there too.

Send and Create Branch are unavailable while a turn is running. Both
rewind the *conversation*, not the working tree: files the agent already
wrote stay written.

### Approvals

Most of this section is Claude Code's. A Codex session in a sandbox mode
decides the same question up front with its sandbox chip; on Default and
in Plan it stops to ask, on cards of its own — see [Codex](#codex). A
Kimi session in Never Ask approves its own tool calls; on Default and in
Kimi's asking modes it stops to ask, on cards of its own — see
[Kimi Code](#kimi-code). Both kinds answer from the keyboard the same
way.

When Claude Code asks permission for a tool call, the request surfaces
**inline in the transcript** as a card with **Allow / Deny / Allow Always
/ Deny Always**. The card is answered from the keyboard the way Claude
Code's own terminal is: the filled (blue) button is the one Return will
press — Allow to begin with — and the arrow keys move it; Escape denies.
The keys reach the newest card only, and only while nothing is being
typed: with a message half-written in the box, Return and the arrows are
the box's own, so a Return meant for a message can never approve a
command. A card scrolled out of view is not answered by a key either.

What **Allow Always** remembers is Claude Code's own suggestion for the
call — the rule its terminal offers as "don't ask again for …", shown
on a line under the command: the exact command, a family such as
`git commit *` or `npm run *`, a whole tool, a folder to work in, or
"accept every edit" for an edit. SipAI hands that rule back to Claude
Code, which applies and matches it itself: a rule marked for the folder
is saved to the project's own `.claude/settings.local.json` and holds
for every later session there, and a grant kept for the session is
replayed to the session's later turns (each turn is a `claude` process
of its own). When Claude Code suggests nothing for a call, Allow Always
remembers that exact call for the session, and the line says so. Deny
Always always means that exact call, for the session. Claude Code
reports its suggestions through a `PermissionRequest` hook SipAI adds
to each turn on the versions known to run it; on older versions Allow
Always remembers the exact call, as before.

Note what **Accept Edits** accepts: file edits, and the file commands
Claude Code counts as edits (`mkdir`, `touch`, `rm` inside the folder).
Other commands still ask — in SipAI as in the terminal; that is Claude
Code's rule, not SipAI's — and Allow Always on such a command is the
way to stop them asking.

A card belongs to the session that asked, from its very first message:
a new session's first turn is started before Claude Code has a session
id, and its requests are still matched to it once the id arrives.

If the app isn't focused on that session, you get a system notification
instead, and clicking it opens the right session. Resolving a card
dismisses its notification.

**Plan mode** ends with a plan card rather than a permission card. When
Claude Code finishes planning, the whole plan is shown with the answers
Claude Code's own terminal offers, in its words:

| Choice | What happens |
|---|---|
| **Yes, and use auto mode** | Claude leaves plan mode into auto mode and implements the plan in the same turn (offered where the installed Claude Code lists auto mode) |
| **Yes, auto-accept edits** | Claude leaves plan mode and implements the plan in the same turn, accepting its own file edits without a card each (other commands still ask) |
| **Yes, manually approve edits** | Claude leaves plan mode and asks before each edit |
| **No, keep planning** | Claude stays in plan mode. Type what to change in the line above the buttons and it revises the plan in the same turn and hands it over again; leave the line empty and it stops and waits for your next message |
| **Yes, and bypass permissions** | offered only to a turn that was in Bypass before it planned: Claude goes back to it |

The filled button is the one Return takes: the mode the turn was in
before it planned, or auto-accept edits for a session started on Plan.
Two of the terminal's answers are not here because they need the
terminal — "clear context and …", which restarts the conversation with
the plan, and refining the plan in a cloud session.

Approving also moves that session's mode chip off **Plan** — to the mode
you chose, which Claude is now in — because a next message sent on Plan
would start planning all over again. It changes that session only: new
sessions still start on the mode you picked for them. The approved plan
stays in the transcript, readable, under the file Claude saved it to.

While a card of any kind waits — a permission, a plan, a question — the
turn clock in the composer holds still with a pause mark in place of the
clock: the turn is waiting on you, not working. (A question Codex asks
without stopping is the exception: Codex works on while it waits — see
[Questions](#questions).) Stop stays, since the turn is still running;
the clock goes on from where it stopped once you answer, and the time
the turn took counts only its working time.

Cards never outlive the turn that asked. Pressing Stop, quitting, or a
`claude` that exits on its own clears that session's pending cards — a
dead agent can't consume an answer, and a card whose buttons do nothing
is worse than no card.

This all works through a small MCP approver that SipAI installs into
`~/Library/Application Support/SipAI/mcp/` and Claude Code launches on
demand. SipAI raises that approver's time limit in its own MCP config
(on Claude Code versions known to accept the setting), so a card waits
about a day for you — left alone, Claude Code gives up on a card after
30 minutes and carries on without the answer.

### Questions

When Claude Code stops to ask you something in the middle of a turn —
its multiple-choice questions, which it asks most while planning — the
question appears at the end of the transcript as a card: each question
with its options (pick one, or several where it says so), a field for an
answer in your own words, and **Submit**, **Skip** or **Chat about
this**. Several questions show one at a time, their short headers as
tabs. Claude Code carries on with your answers the moment you submit;
**Skip** tells it to choose for itself and carry on; **Chat about this**
hands the questions back with a note to ask you what you would like to
clarify, so the turn ends with Claude Code's question in words and you
answer in the composer. From the keyboard the card works the way the
terminal's does: ↑ and ↓ walk the options, the field for your own answer
and the buttons, ← and → turn to the previous or the next question, and
Return picks the option or presses the button the keyboard is on — the
blue outline, or the filled button, shows where that is.

While a question waits, the turn clock holds still, as for any card (see
[Approvals](#approvals)). Like an approval card, a question posts a
notification when you are looking elsewhere and marks its session in the
sidebar.

With **Non-stop** on in the mode menu, a question never reaches you:
Claude Code is told to choose what it judges best, say which option it
chose and why, and continue. A scheduled task runs this way only when
its card's **Non-stop** box is ticked; otherwise a question a run asks
waits on a card for you, like any other turn's. In
Claude Code's **Don't Ask** mode, Claude Code declines its own questions
before they reach SipAI.

Kimi Code asks too, on Default and in its asking modes (see [Kimi Code](#kimi-code)):
all of its questions arrive together on one card, without a field for
your own words or **Chat about this**, because Kimi's question form has
neither. **Skip** dismisses them — Kimi is told you did not answer and
decides for itself — and so does Non-stop.

Codex asks in its Plan mode (see [Codex](#codex)): its questions arrive
together on one card, with a field for your own words where Codex offers
one. **Skip** leaves them unanswered, and Codex goes on with the option
it recommends, noting it as an assumption in its plan — and so does
Non-stop. There is no **Chat about this**.

With the models Codex's own catalog marks for it, Codex can also ask
*without stopping*, in any mode: it keeps working while the question
waits. The question arrives on the same kind
of card, which says Codex keeps working — so the turn clock keeps
running. Pick an option or type your own answer: it reaches Codex in the
turn that asked, the way Codex's own terminal and desktop app send it,
and shows in the transcript as your reply under the question. The card
goes away when the turn ends, since Codex takes no answer after that;
whatever you had started to answer moves into the message box under its
question, as Codex's own terminal does, ready to send as your next
message. **Skip** sends nothing, and Codex
decides for itself, as its own instructions tell it to; with Non-stop
on (in **Default** and **Plan**, the modes it applies to), no card is
shown. In **Chat only** the turn runs headless and nothing can reach it
until it ends, so the question stays Codex's message and you answer it
in your next one.

### When an MCP server asks

An MCP server you add to an agent can pause one of its tools to ask you
for something — a short form to fill in, a yes or a no, or a link to
open in your browser, to sign in somewhere for example (MCP calls this
*elicitation*). SipAI shows it at the end of the transcript, on a card
named after the server:

- **A form** is drawn like a question card, one field per page: a choice
  to pick, several to tick where the server allows it, Yes or No, or
  your own words. A field the server requires has to be filled in before
  **Submit**, and a field that takes a number, an email address, a date
  or a length of text says so under it. **Submit** sends the answers to
  the server typed as its form asks; **Decline** sends nothing, and the
  tool carries on without them. A card shows up to 8 fields, and up to
  12 choices in each; SipAI declines a form beyond that, or one with a
  field of another kind, for you — as if you had chosen **Decline** —
  and no card appears.
- **A link** is shown whole, exactly as it would open. **Open in
  browser** opens it; once you have finished there, **I'm done,
  continue** tells the server. **Decline** refuses it. SipAI opens only
  `https` links it can show exactly as they would open; any other is
  shown with Decline alone.
- **A yes-or-no** (a form with nothing to fill in) names the server and
  shows its words: **Allow**, **Deny** or **Cancel**.

The turn waits while such a card is up, so the clock holds still, a
notification comes when you are looking elsewhere, and Stop cancels the
request with the rest of the turn's cards. All three are the server's
questions: with **Non-stop** on, each is declined without a card.

| Agent | How it reaches SipAI |
|---|---|
| Claude Code | through an `Elicitation` hook SipAI adds to each turn, on Claude Code 2.1.288 and later; without it, `claude -p` cancels every such request itself |
| Codex | on **Default** and **Plan**, where Codex also asks before it runs an MCP tool that may change something — a permission, which waits with Non-stop on as well — in its own words: **Allow / Allow for this session / Always allow / Cancel**, laid out like Claude Code's card — Allow, where Return starts, at the bottom right with Always allow above it. **Allow for this session** lasts until the turn ends, since SipAI starts Codex afresh for each message. **Always allow** is saved by Codex in its own settings (`~/.codex/config.toml`, or a project's own Codex settings for a server set up there), so that tool stops asking wherever Codex runs — in SipAI, its terminal and its app. In **Read Only**, **Workspace Write** and **Full Access** Codex never asks: it declines a server's forms and links itself; in Read Only and Workspace Write it also declines a yes-or-no and refuses an MCP tool that needs approval, while in Full Access it accepts a yes-or-no and runs the tool unasked |
| Kimi Code | Kimi's MCP client takes no forms or links, so its servers can't ask; before it runs an MCP tool, Kimi asks on its usual permission card |

### Organising the list

The section header carries a **Group by** menu:

| Mode | Groups by |
|---|---|
| None | nothing — newest first, the default |
| Folder | the directory the agent ran in — running first, then unread, then most recently used |
| Date | Today, Yesterday, Previous 7 days, Previous 30 days, then by month |
| State | waiting for you (an approval, a plan or a question), working, running in another terminal, unread, scheduled, then the rest |
| Custom | groups you name yourself — running first, then unread, then most recently used |

The button tints while a grouping is on, and the choice persists. Group
headers show their row count and fold away when clicked; folded state is
remembered per mode. A folded group whose session is running shows the
same pulsing dot after its name, and one with an unopened finished run
the steady blue dot — both, when it holds both — and so does the section
header, if you collapse the whole section — so a turn never runs or ends
out of sight.

Inside every group, in every mode, running sessions come first, then
finished ones you have not opened, then the rest, newest first within
each. Grouping by Folder or Custom orders the groups the same way.
Headers also drag into your own order. In Folder and Custom mode a group
with a running or unread session is still drawn above it, and among the
rest, in Folder, Date and Custom mode, the dragged order holds until a
turn starts somewhere: the group it starts in moves to the top. A session you open keeps its place
until you open something else, so a row never moves out from under the
pointer. Rows keep exactly the look they have with grouping off.

A **folder** group's header carries a **+** that starts a new session
already pointed at that folder, and a **custom** group's header carries
the same **+**: the session it starts belongs to that group from its
first message, and opens in the folder you last worked in there — or in
the usual new-session folder if the group is new. Scheduling a task from
that page files the task in the group too. **Ungrouped** carries a **+**
as well: it starts a session in no group, in the folder you last worked
in there. Grouped by Custom, the section's first row is **+ New group**
rather than **+ New session** — a session starts from its group's **+** —
and Ungrouped is shown even while empty, so that **+** is always there.

Between a Folder or Custom group's count and its **+** is a … menu holding
everything you can do to the group; the header has no right-click menu.
**Mark all as read** clears the steady blue dot of every session in the
group. A folder's … menu has **Delete all sessions**: every
session in that folder is removed — for every app that reads them — but
never the folder or your files. A custom group's … menu has **Delete the
group**, which removes the group and every session in it, and
**Ungroup**, which removes only the group and moves its sessions to
Ungrouped; Ungrouped's … menu has **Delete all sessions**. None of these
deletes a scheduled task or its runs, and each asks first, saying what
goes and what stays.

**Custom groups:** with the list grouped by Custom, **+ New group** (or
the Group menu's **New group…**) makes one, and right-clicking a session or
task → **Add to group** files it. Unfiled rows collect under **Ungrouped**.
A group you have named stays visible while it is empty, showing 0, so a new
one can be used straight away; its header's … menu renames it, ungroups it, or
deletes it with its sessions. Group names live in this app's `config.json`, never in the
agent's session files, and two agents may each have a group of the same
name without one's changes reaching the other's.

Long lists are capped at 10 rows with a **Show all (N more)** row that
counts only what a *visible* group actually hid, and toggles back to
**Show less**. A row with a dot is never behind it.

Sessions whose working directory sits in a system temp folder are
filtered out as scratch — except scheduled runs, which are always shown.

---

## Codex

When the Codex CLI is installed and signed in — and not unticked in
**Settings → Agent Initialization** — a **Codex** section appears in the sidebar
listing rollouts from `~/.codex/sessions/`, with the same grouping and
the same transcript rendering as Claude Code sessions — those stored
compressed (`.jsonl.zst`, how Codex keeps a session left alone for a
while) included, read through the zstd decoder SipAI bundles. A
session is
titled with its thread name from Codex's `session_index.jsonl` where it
has one, else from its first message; current Codex versions keep
thread names elsewhere, which SipAI does not read yet, so a name given
in Codex's own app may not show here.

**Codex sessions are driven in-app**, the same way Claude Code ones are:
**+ New session** opens a draft, sending runs the turn through
`codex app-server` — `codex exec --json` behind a pty for Chat only and
on a Codex older than 0.159.3 — and the reply streams into the
transcript turn by turn. Follow-up sends resume the same thread, so a
conversation
started here continues here — and one started in a terminal continues
here too.

Beyond [the differences table](#how-the-three-agents-differ), a few
things are worth knowing:

- **Default and Plan stop to ask you.** On Codex 0.159.3 or later,
  **Default** is Codex's own default setting, run the way Codex's own
  app runs it: in a folder Codex trusts it reads and edits the folder and
  runs commands, and asks before going online or editing anything else;
  in one it does not trust, it asks before editing at all. SipAI asks
  Codex for that default on every turn, so a Default turn never inherits
  the approval setting an earlier turn ran with (after a Full Access
  turn, Codex's own thread would otherwise go on never asking), and a
  permission profile of your own in Codex's config stays in force.
  Default never marks a folder as trusted: Codex records that when a
  session is started there in Workspace Write or Full Access, or when you
  trust the folder in Codex itself. Where the
  installed Codex lists it, **Plan** is offered too. Both run through
  `codex app-server`, the front end Codex's own terminal and desktop app
  use, because `codex exec` cannot ask; on an older Codex, Default runs
  `codex exec` with no override. Codex's requests arrive as
  cards in the words its terminal uses — "Would you like to run the
  following command?", with the whole command and the reason the model
  gave — answered with Codex's own answers. "Yes, and don't ask again for
  these files" lasts until that message's turn ends, since SipAI starts
  Codex afresh for each message; "No, and tell Codex what to do
  differently" ends the turn, and you say it in your next message.
  Codex's offer to allow every command that starts the same way is not
  shown: it writes a rule every Codex session on the Mac would follow. In
  **Plan**, Codex explores, asks you questions, and ends with a plan;
  **Implement this plan?** then names the mode to carry it out in, as
  Claude Code's own plan dialog does — **Yes, implement in Default**,
  **Yes, implement in Workspace Write**, and **Full Access** for a
  session that was in it before it planned — and sends Codex's own
  "Implement the plan." in that mode. A Plan turn leaves the Codex
  thread in plan mode — a `codex exec` turn on it would go on planning —
  so before a Chat only turn on such a thread SipAI asks Codex to switch
  it back; every other turn states its own mode. Slash commands other
  than `/compact` and `/review` are not answered by Codex here: they go
  to the model. Each turn states its model, effort and speed to
  Codex, so a model, effort or speed left on **Default** means what Codex
  itself would run in the folder — Codex's own answer for it, a trusted
  project's `.codex/config.toml` included — not what an earlier turn
  picked.
- **The sandbox is a real boundary**, not a label. Each turn tells
  Codex the chip's sandbox and that it must never ask — through
  `codex app-server`, or as `-c sandbox_mode=…` on `codex exec` — and
  Codex itself enforces it, the same on either route, so a **Read Only**
  session is refused permission to write a file where a **Workspace
  Write** one writes it. **Full Access** turns both the sandbox and
  approvals off. These never ask: a step the sandbox does not allow
  simply fails, and an MCP server's ask is answered by Codex itself.
  Through the app-server each message states its own speed, and a
  command left running in a background terminal keeps the turn open
  until it ends, as in Default.
- **Codex runs outside a git repo.** A session can point at any folder:
  the app-server runs a turn there as it is, and for `codex exec` SipAI
  passes `--skip-git-repo-check`, without which Codex refuses to start
  there. The sandbox mode, not the git check, is what bounds what a run
  can touch.
- **Chat only keeps Codex's web search and leaves one local tool,
  refused.** Codex's shell, image, computer-use, goals and plugin tools
  are switched off as `-c` feature overrides; web search stays on
  (`web_search="live"` — OpenAI runs it, not your Mac); `apply_patch`
  has no switch, and the turn's
  `sandbox_mode="read-only"` + `approval_policy="never"` refuse it
  ("patch rejected: writing is blocked by read-only sandbox" — nothing is
  written). Plugins or MCP servers of your own may add read-only lookups
  the switches don't reach. The persona replaces Codex's instructions on
  *resumed* turns only: a thread records its instructions at birth and a
  plain resume reuses them, so a thread born with the persona would run
  every later agent turn as a chat assistant. Codex runs a turn with an
  unknown `-c` key instead of refusing it — older versions without a
  word, newer ones with a warning — so the row is offered only on Codex
  0.155.1 or later whose `codex features list` names the switches. A
  Chat only turn
  bills your Codex allowance — a ChatGPT plan's Codex pool, not its chat
  pool; the two are separate, and the only bridges to the chat pool are
  browser automation, which SipAI does not do.
- **Subagent sessions appear too.** Runs Codex spawned as subagents get
  their own titles and a distinct glyph, sorted after your own sessions.
- **A fork opens whole.** Codex stores a fork — `codex fork` in a
  terminal, or a branch made here — as a reference to its parent rather
  than a copy; SipAI follows the reference the way Codex does, so the
  fork shows the conversation above it.
- **The model list follows Codex's own.** It is read from Codex's
  catalog cache, your `config.toml` and recent sessions, re-read
  whenever the cache or `config.toml` changes, and — after a Codex
  update, and once a day otherwise — refreshed through `codex
  app-server`'s `model/list`, which is how Codex's own picker fills
  itself at startup. No model is called for that. The Default row names
  the model Codex would run in the session's folder, asked of Codex
  itself (`config/read`), so a trusted project's own `.codex/config.toml`
  counts. The context chip divides by the window Codex
  enforces: the model's default, or your `model_context_window` clamped
  to the model's maximum, times Codex's effective percentage.
- **The default window is 272,000 tokens — 258,400 usable — on models
  OpenAI advertises at 1,050,000.** That default sits exactly on
  OpenAI's long-context price line (prompts over 272K input tokens are
  billed at 2× input and 1.5× output for the whole request), and Codex
  has no switch for it in its own interface. Settings → Help has the
  question (also reached from the **?** on the chip's hover): a table of
  which installed models allow a larger window and how large, read from
  Codex's own catalog, and two buttons — **Use the maximum** and **Back
  to default** — that set or remove `model_context_window` in
  `~/.codex/config.toml` *through Codex itself* (`codex app-server`'s
  `config/value/write`, the same request Codex's desktop app makes),
  so the file keeps its formatting and Codex validates the value. The
  chip moves at once; the next turn of every Codex session, here or in
  a terminal, runs with the new window.

A Codex that is installed but not signed in is not listed; **Settings →
Agent Initialization** offers **Sign In** (a ChatGPT plan in the browser, or a
pasted API key — both through Codex's own app server) and **Install**
(OpenAI's release package, checked against OpenAI's checksum file, with
every program in it checked for OpenAI's own Developer ID signature
before any of it runs, into `~/.local/share/sipai/codex` with a `codex`
command in `~/.local/bin`).
Detection re-checks every few seconds, so `codex login` in a terminal
surfaces the section without a relaunch.

---

## Kimi Code

When the [Kimi Code](https://github.com/MoonshotAI/kimi-code) CLI is
installed and signed in — and not unticked in **Settings → Agent Initialization**
— a **Kimi Code** section appears in the sidebar listing sessions from
`$KIMI_CODE_HOME/sessions/` (default
`~/.kimi-code/sessions/`) — same grouping, same transcript rendering,
same **+ New session** draft as the other two. Sending runs
`kimi --prompt … --output-format stream-json` behind a pty; follow-up
sends pass `--session <id>` so the conversation continues. While another
Kimi Code has the session open — its own terminal, its desktop app, an
editor — Kimi keeps it to that one (Kimi Code 2.3 or later), so a
message sent from SipAI is not started: the transcript says which Kimi
has it. Send it again once that one has stopped the session or exited.

> **In Never Ask, a Kimi session driven from SipAI edits files and
> runs commands without asking.** That is Kimi's headless run: kimi
> refuses `--yolo`, `--auto` and `--plan` on a `--prompt` run, because
> print mode approves every tool call itself — what Kimi calls Never Ask.
> On Kimi Code 2.1.1 or later the mode chip's **Default** is Kimi's own
> default setting — the `default_permission_mode` in its config, Always
> Ask when it names none (a new session is simply left as Kimi opens it;
> one already under way is told that mode, since a Kimi session keeps
> whatever its last turn set) — and the chip also offers Kimi's own **Ask When
> Needed** and **Plan**; on 2.0.1 or later **Chat only**, which takes the
> file and command tools away for that one message. On an older kimi the
> chip is a plain readout, Never Ask. Pick Never Ask only for a folder you
> are willing to let Kimi change.

**Default and Kimi's asking modes** run the turn through `kimi acp`, Kimi's own
Agent Client Protocol server — the front end through which Kimi stops to
ask. A tool request becomes a card with Kimi's own answers, **Approve
once**, **Approve for this session** (remembered by Kimi for that
session's later turns) and **Reject**, showing the command and its
folder or the edit as a diff. A finished plan becomes a plan card — the
plan, the file Kimi saved it to, and Kimi's answers, each approval
naming the mode the session continues in, as Claude Code's own plan
dialog does: **Approve, then Default**, **…then Ask When Needed**,
**…then Never Ask** (where the plan offers several approaches, the
approach is picked first and the mode next), **Revise**, **Reject and
Exit**. Return starts on the mode the turn was sent in — a plan Kimi
drew up on its own under Ask When Needed starts on Ask When Needed. The
mode is set the moment Kimi has the approval, so the rest of
that turn already runs in it, and the chip follows; **Revise** keeps the
session planning and moves the chip to Plan, so your next message — what
to change — is planned too, not carried out; **Reject and Exit**
moves a chip that is on Plan to Default (a plan Kimi drew up on its own
in another mode leaves the chip where it is). A question becomes a
question card (see
[Questions](#questions)). What each mode asks about is Kimi's rule, and
the menu says what Kimi was measured to do: Kimi's own default, **Always
Ask**, asks before every command and every edit, except an edit inside
the folder when the folder is a git repository (reading, searching and
web lookups never ask); **Ask When Needed** runs routine edits and commands and asks
before risky ones such as `rm -rf`, and for questions and plans;
**Plan** makes no edits until you approve its plan, and asks before
commands. The transcript is read from the session's own record — the
same reader a reopened session uses — so it fills a step at a time, as
in Never Ask. In these modes Kimi answers its own slash commands
(`/status`, `/usage`, `/help`) without calling the model;
the answer shows as a notice and is not kept with the session.
`/compact` is answered the same way and then runs: the turn stays open
until Kimi has finished compacting, since Kimi cancels a compaction the
moment it is closed. A
background task the turn started keeps the turn going until Kimi's own
follow-up turn is done — Kimi's notice that the task finished shows
under a system label, then its report — since Kimi stops its tasks a few
seconds after it is closed. Stop answers a card that is waiting, then
asks Kimi to cancel the turn; with a background task still running that
takes about five seconds, the time Kimi needs to stop the task itself.

Two things SipAI does around these turns, both in Kimi's own format.
An ACP turn binds the session to that conversation's runtime, and Kimi
replays the binding whenever the session is opened — under it, Kimi in
your terminal (and SipAI's next Never Ask turn) would run the session
without Bash, Write, Edit, Glob, Grep or Agent. So when the turn ends
SipAI appends Kimi's own record binding the session back to its local
runtime (journaled first, so a crash is healed at the next launch or
when the session is opened). And a Plan turn leaves the session in
Kimi's plan mode, where a later Never Ask or Chat only turn could
edit nothing; before such a turn SipAI asks Kimi to leave plan mode —
the request an asking turn makes when it sets its own mode — which
costs about half a second.

**Chat only on Kimi** works through kimi's own mechanisms, because
print mode has no per-run tool switch and binds its persona per session.
On an existing session SipAI writes the session's
`tool-policy/state.json` — the file kimi's own server writes when a
prompt disables tools, `{"disabledTools": [names]}`, with the names from
the session's own tool snapshot, all but the web lookups (`FetchURL`,
and `WebSearch` where kimi has a search provider — a Kimi Code login
has one; an API key alone can open a page but not search) — runs the
ordinary `--prompt --session` turn (which streams as usual), and
restores the file when the turn ends.
What was there before is journaled in SipAI's config first and put back
at the next launch or the next open if a crash got in the way, since a
session left with that file would be tool-less in your terminal too. A
file of a shape SipAI doesn't recognise refuses the send rather than
being rewritten. A *new* session's first Chat only message takes
another door: kimi's local server (`kimi web`, the one SipAI already
starts for sign-in and the usage window) creates the session and takes
the prompt with the tools disabled, so that one answer arrives all at
once rather than streaming; later messages stream. The chip's hover on a
draft says so. Kimi keeps its own prompt in Chat only — no persona — and
the effort chip does not reach that first server-driven message. An image
can be attached only to that first message: a later `--prompt --session`
turn has no image input, so an existing Kimi session refuses one when you
attach it.

The model chip lists the aliases from kimi's own `config.toml` and marks
the configured default, because kimi rejects a model that file doesn't
declare. If the file yields nothing, the chip falls back to models recent
sessions used, and failing that offers **Default** alone, which sends no
`--model` and lets kimi's configuration decide. Kimi Code's plans include
different models, and nothing kimi lists says which: when Moonshot refuses a
message's model for your plan ("Your current subscription does not have
access to …"), its row — and Default, when it is the default — says "Your plan
doesn't include this model" from then on, for that account. It stays pickable,
since plans change, and the note goes the next time the model answers. The note
is read off Kimi Code's own record of the turn, which Kimi Code 2.6.1 no longer
keeps the model in: there, no note appears.

A Kimi Code that is installed but not signed in is not listed; **Settings
→ Agent Initialization** offers **Sign In** (a Kimi Code membership through
kimi's own device-code flow — SipAI shows the code and opens the site's
sign-in page — or a pasted Moonshot platform key, starting on the model you
pick from kimi's own catalog list) and **Install** (Moonshot's own
installer). Signed-in is read off
kimi's `config.toml` and its token file, the same read the plan-usage
window makes.

Kimi Code runs two separate services: **kimi.com** in mainland China and
**kimi.ai** everywhere else, each with its own accounts, memberships and
API keys. So the Sign In sheet asks which one first. It presets the site
Kimi Code itself would use — the site of an earlier sign-in, else the one
it was installed from — which is what `kimi login` in Terminal would
pick, and offers only that site's platform key (platform.moonshot.cn, or
platform.moonshot.ai). A key from the Kimi Code Console belongs to the
membership, so — as Kimi Code's own `/login` does — the sheet sends it to
the membership sign-in, where Kimi Code takes the account's model list
from its own server.
Signed in, the card names the membership as Kimi does, the site, or the
key's platform — "Membership · Pro (kimi.ai)", "API key
(platform.moonshot.cn)"; a Kimi Code Console key signed in before reads
"Kimi Code key (kimi.com)". Install asks nothing:
Moonshot's kimi.com and kimi.ai installers differ only in the host they
download from and install the same program, so it uses the kimi.com
one; a Kimi Code installed that way starts on kimi.com until you sign
in.

`SipAI-macOS/Verification/KimiCode/run.sh` re-checks every assumption
this support is built on against the `kimi` on your `PATH` — it spawns
two real turns in a temp folder and names the file to edit for anything
that fails. Run it after a kimi upgrade.

---

## Skills

A skill is a folder holding a `SKILL.md` — instructions an agent loads
when a task calls for them. Each agent uses the skills in its own skills
folder: `~/.claude/skills`, `~/.codex/skills` and `~/.kimi-code/skills`
for every folder, and `.claude/skills`, `.codex/skills` and
`.kimi-code/skills` in a project for that project (Codex and Kimi Code
also both read the shared `.agents/skills`). Skills keep working the way
they do in a terminal: you call one by name (`/name` in Claude Code,
`$name` in Codex, `/skill:name` in Kimi Code), or the model picks one
that fits.

**Settings → Agent Skills** lists each agent's skills under that agent: the
ones it has in every folder (**Skills · Global**), the chosen folder's
own (**Skills · *folder***; pick **Global** in the folder menu to see
the global ones alone), those of each folder below it — up to three
levels down — that has skills of its own (**Subfolder · *name***: what
a session started in that subfolder has; one started in the chosen
folder isn't started with them), and — folded — its **Plugins** and
**Built-in** skills. Where an agent has
no skill of its own, the page says so: *No global skills* on Global,
*No skills in folder* under a folder. The folder menu, under the search
box, lists the folders you browsed there in the last month, the newest
first (ten at most; one whose disk is away is left out until it is
back), then **Choose Folder…**. A skill more than one agent has
is listed under each, *shared with* the others beside its name — and *in
the common folder* when its files sit in the `.agents/skills` that Codex
and Kimi Code both read. Its **…** menu holds the rest:

- **Share With** gives the skill to another agent. SipAI keeps one copy
  of a skill it shares in its library — `~/.sipai/skills`, or
  `.sipai/skills` in a project — and links it into each agent's own
  folder, so an edit reaches every agent that has it. A skill that sits
  in one agent's folder moves into the library when you share it, and a
  link takes its place, so that agent keeps it. Each agent reads a
  `SKILL.md` its own way: Kimi Code skips a skill whose header has no
  name, and Codex and Kimi Code both skip one with no description or
  with a value YAML can't read as written (a `:` inside a description,
  say), all of which Claude Code loads as it is. So before sharing,
  SipAI fixes what the new agent would skip the skill over — adding the
  missing line, putting the value in quotes, writing a description that
  is a list as one sentence, moving an indented header to the margin,
  clearing a stray tab or an invisible line-break character that Codex
  stops at — and carries **Only when I call it** over in that agent's
  own words (Codex keeps it in its own `agents/openai.yaml`; Claude Code
  and Kimi Code both read it from `SKILL.md`, so setting it for one of
  those two sets it for the other). A share is one click; Settings →
  Help explains what it moves and changes. What it can't fix for you —
  a name longer than Codex takes, a key given twice, a description that
  is a map rather than text, a line of the header that isn't valid YAML,
  a skill in a folder SipAI doesn't edit — it says, and shares nothing.
  What one agent alone understands (Codex's `agents/openai.yaml`, Claude
  Code's `allowed-tools`) the others ignore, so a skill that depends on
  one may work differently there. And where SipAI can't write **Only
  when I call it** for the new agent — the skill's files aren't SipAI's
  to change — the skill is still shared, and the page says that agent
  may now use it on its own.
- **Delete** takes the skill from that agent alone: the others keep it,
  and their *shared with* stops naming it. Deleting it from the last
  agent moves its folder to the Trash — unless the folder is one you
  linked in from somewhere else, which loses only its link. A skill in
  `.agents/skills` taken from one of Codex and Kimi Code moves into
  SipAI's library and stays linked for the other, if that one is
  installed.
- **On, Only when I call it, Off.** Off uses the agent's own switch,
  and says where it applies: Claude Code's is saved for the project the
  skill's folder belongs to — the top folder of its repository, or the
  folder itself outside one — *Off (applies to folder)*, and for your
  home folder on Global — Codex's applies everywhere — *Off (applies to
  every folder)* — and Kimi Code has none (delete it there instead).
  Only when I call it stops the model from using a skill on its own, and
  SipAI writes it into the skill's own files, so every agent that has
  the skill respects it.
- **Start New Sessions With It** — the pin — marks a skill new sessions
  of that agent start with on the skill chip (below). Kimi Code starts
  with one skill, so pinning another there replaces the first, and the
  item says which.
- **Edit…**, **Show in Finder** and **Open SKILL.md**. A skill several
  agents use is one set of files, so the edit sheet says that saving
  changes it for all of them (an edit made in another app does too). A
  skill an agent
  has but doesn't load is marked **Not loaded**, with the reason (Codex's
  own words, where it gave some), and offers **Fix for *agent*…** when
  SipAI can fix it. Claude Code offers no skill whose folder's name holds
  a hidden or direction-changing character, a space at either end or two
  in a row, a blank other than a space, a stray accent mark, `<` or `>`
  (rename the folder; SipAI's own names never do), and calls a skill whose
  `name:` holds one by its folder's name instead. Clicking a skill's name
  shows where its files are,
  how each agent calls it, and anything in it only one agent understands.
  SipAI edits the skills it keeps — those in its library, in an agent's
  own folder or in the shared `.agents/skills`; a folder you linked in
  from somewhere else is listed and loads like any other, and stays
  yours to edit where it lives.

Library skills no agent has are listed under **Not in use**, where Share
With gives one to an agent again. If two agents' skills folders are one
folder on disk (one linked to the other), a skill in it belongs to both,
and SipAI says so rather than take it from one.

**New Skill** writes one from a name, a description and its
instructions; **Add…** brings one in from a folder, a `.zip` or a
`.skill` file, under the name you give it — only add skills from sources
you trust, since a skill can include scripts an agent may run (an
archive holding a link to a file outside itself is refused). A name is
refused when an agent you tick already has a skill called that, among
its global skills or in the folder: the three agents disagree about
which of two same-named skills they use, so SipAI keeps each agent to
one. Different agents can use the same name, and so can two different
project folders. Plugin,
built-in and claude.ai skills belong to their agent: SipAI lists them
and never changes them, and **Copy to My Skills** makes an editable copy
of one whose files it can read — Codex's, and the claude.ai ones; Claude
Code's own plugin and built-in skills have no folder to copy.

**The skill chip** — the little robot beside **+** under an agent
session's text box — preloads skills. Click it, tick the skills you want
from **Global**, **This folder** and the session folder's subfolders
(**Subfolder · *name***), and press **Done**; the robot turns orange.
Each chosen skill loads once, with your next message, and stays in the
conversation. When a long conversation is summarised, Claude Code and
Codex are sent the skill again with your next message; Kimi Code keeps
it by itself, and is sent it again only when it had to trim your
earlier messages to make room. Unticking a skill stops it from being
sent again, but what it already put into the conversation stays —
edit an earlier message, or start a new session, to leave it
behind. Click the orange robot to see where each one stands — loaded,
loading with your next message, or not available here — and **Edit** to
change the choice. A message that loaded skills names them under your text; if a
skill turns out not to have loaded — it was deleted or moved since SipAI
last looked, or the agent wouldn't take it — the session says so and the
message stops naming it. A skill you chose and later deleted stays in
the list, dimmed, so you can untick it.

A subfolder's skill is not one a session started in the folder above
it begins with, so how it loads depends on the agent: Claude Code
(2.1.287 or newer) and Codex (0.160.0 or newer) load it in any mode,
and Kimi Code only in a session started in
that subfolder — where it can't load, it is listed dimmed with the
reason. The session still works in its own folder. A subfolder's skill
named like one the session already has — its folder's or a global one —
is offered to Claude Code 2.1.309 or newer as ***subfolder*:*name*** (for
example `packages/web:review`), the name Claude itself gives it; Codex and
Kimi Code are offered the session's own. Kimi Code takes one
skill per message, so its chip (and a Kimi task) holds one skill at a
time; a message that loads it goes through Kimi's own front end, in
**Never Ask** too, and a skill whose name has a space or a slash in it
can't be called there and is listed dimmed. Chat only turns load none;
Claude Code needs to be 2.1.283 or newer and Kimi Code 2.1.1 or newer —
an older one lists its skills dimmed, with a note to update it.

## Scheduled tasks

A scheduled task is a folder under `~/.claude/scheduled-tasks/<name>/`
whose `SKILL.md` holds everything: the prompt, the schedule, the working
directory, which agent runs it, the model / effort / mode / speed and
Non-stop, and the skills each run loads (`skills:`). A run whose skill is
missing or switched off for its agent in its folder does not start, and
the task says which skill and why.

**Create one** from a new session's composer: fill in the prompt, switch
on **Run on a schedule**, and pick when it runs — **Once**, at a day and
time you choose (Today, Tomorrow, or any date on the calendar), or every
hour, day, weekday, week or month. Every choice is a chip: the time opens
a grid of hours and minutes, a one-time run's date a month calendar, and
nothing already in the past can be picked. **Custom (cron)**, last in the
row, takes a hand-written 5-field cron expression for anything else.
While the schedule is armed the send button turns into a calendar, with a
banner previewing exactly what will be created. The task then appears at
the top of its group in the sidebar, alongside your sessions, and expands
inline to show its runs. Its icon is a clock between two short bars —
above and below it while the task is folded, either side of it while its
runs are showing. Clicking a folded task's row shows its runs and opens
the task's page; clicking the row again hides the runs and nothing
else — whatever is on screen stays. Open a run by clicking the run.
While one of its runs
is going, the pulsing dot follows the task's name, and a run you have not
opened leaves the steady blue dot there — both, when both are true.

The agent is part of the definition, not a global setting: a task created
from a Codex session runs under Codex, one created from a Claude Code
session runs under Claude Code, and a Kimi task runs under Kimi. All
three live in the same place: `~/.claude/scheduled-tasks/` is the task
store for every agent.

**Speed** belongs to the task too, and a task created from the composer
takes the composer's along with its model and effort, as the composer's
switch showed it. Claude Code tasks have a **Fast mode** checkbox and
Codex tasks a checkbox for each speed (**Fast mode**, and **Ultrafast**
when Codex offers it), the composer's switches: on the models that have
them, saying what stands in their way and, for Claude Code, what fast
mode costs (on a Claude plan, usage credits only). A Codex task whose
speed was never set runs at what Codex runs an unattended turn at by
itself — the speed in your Codex config for the task's folder, never
the speed a model starts on in Codex's own window — and the checkboxes
show which.

**Mode and Non-stop** belong to the task the same way, and a run does
exactly what its task says. The card's **Runs as** row is the composer's
three chips in the composer's order — **Model**, **Effort**, **Mode** —
each listing the composer's own choices (Chat only and each tool's
asking modes included), with the speed and **Non-stop** checkboxes
under them. A run is Non-stop only when that box is ticked: otherwise a
question a run asks waits on a card for you, and the run stays open
until you answer. Non-stop answers questions and nothing else: in a mode
that asks before it acts — Claude Code's Manual, Accept Edits (for
commands) and Plan, and Auto when it is unsure; Default wherever the
tool's own default asks; Plan on Codex; Ask When Needed and Plan on Kimi
Code — an approval card waits for you whether the box is ticked or not.
For a task meant to run with nobody there, pick a mode that does not
ask. A task created from the composer takes the composer's mode and
Non-stop as they stand — Default stays Default. Files attached in the
composer go into the task's prompt as their paths, one per line, for
every run to open; under Chat only, a task scheduled with files attached
is refused, since its prompt cannot carry their content. A mode the installed tool
cannot run (too old for it) fails the run with a line saying so; it is
never run as another mode. In a Kimi task's file, no `mode:` line means
Never Ask — what every Kimi task ran as before Kimi had modes here — and
Default is written out, as `mode: kimi-default`.

**Inspect and edit one** on its page — clicking the task's folded row
opens it — or from any of its runs. A panel above a run's transcript
shows — collapsed — what the task is, when it next runs, and how the last
run went ("Paused", "Next run in 3 hours", "missed a run yesterday",
"last run failed"). Expanded, it lists every setting the next run will
use — schedule, folder, model / effort / mode / speed and Non-stop, the full prompt —
all editable behind **Edit**; on the task's page the same settings are
the whole page, open for editing. A saved edit applies to every upcoming run and
never to one already in flight. A changed schedule starts from its next
time, as a new task does: moving a task that ran at 9:00 to 13:00 at
two in the afternoon doesn't start a run, and neither does resuming a
task you paused. This is also where a schedule comes off entirely:
switching to *Only when I run it* leaves a task that lives on the **Run
now** button.

The panel's header carries **Run now**, which runs once and leaves the
schedule untouched. **Pause / Resume** sits in the expanded details;
renaming happens in the editor or from the sidebar row's … menu. The
task's page has **Pause / Resume** and **Run now** in its header, and a
pencil right beside the task's name that renames it. **Run now** pressed
on the page opens the run it starts; a run the schedule starts while the
page is open leaves the page where it is and appears under the task in
the sidebar. Run now always runs the saved task, so it is hidden while
the settings in front of you have unsaved changes, and comes back once
you save or revert them. In the sidebar, a task's row carries its state —
Active, Paused, No schedule, and for a one-time task Finished after its
run, or Missed if SipAI was closed too long past its moment — and when it
last ran ("Never" until the first). A task is placed in its group by its
newest run, or by when it was scheduled if that is later, so a task you
have just created sits at the top.

**Delete one** from its row's … menu, two ways, each asking first and
saying what goes (the same menu's **Mark all as read** clears the steady
dot of every run). **Delete definition** stops the task and removes its
definition; its past runs stay, listed under it. **Delete all** removes
the definition *and* every run the task made — for every app that reads
those sessions — and the task is gone from the sidebar; a run still
going is stopped first. If the `SKILL.md` disappears behind the app's
back, the panel degrades to "Definition deleted — past runs only", and
such a task offers **Delete all** alone.

**The app fires tasks itself**, in-process, through the same code path as
an interactive turn — so a run inherits the app's own file access and
appears in the sidebar as an ordinary live session. A task runs once at a
time: if its previous run is still going when the next time comes, SipAI
waits up to five minutes for it and otherwise skips that time — the
panel says so — rather than starting the next run the moment the long
one ends. A task whose agent is hidden in Settings → Agent Initialization, signed
out or uninstalled doesn't fire until the agent is listed again; a slot
it missed meanwhile is then treated like one missed while SipAI was
closed.

> **Why not cron?**
>
> `/usr/sbin/cron` has no Full Disk Access on macOS, so any job it spawns
> gets `Operation not permitted` for `~/Desktop`, `~/Documents` and
> `~/Downloads` — where projects live. It doesn't fail loudly either: the
> task runs and reads nothing. cron also skips slots the machine slept
> through, and its single crontab file has no history, so anything that
> rewrites it erases every task at once. LaunchAgents hit the same wall.
>
> **The cost:** the app has to be open at the scheduled moment. A slot
> missed while SipAI was closed fires once, about fifteen seconds after
> the next launch — so "be
> open at 9:00 sharp" becomes "open the app sometime that day", and a
> task due forty times while you were away fires once, not forty times.
> Catch-up reaches back 24 hours at most; an older miss is recorded as
> skipped and reported on the panel, and each task's editor can turn
> catch-up off entirely. Nor does a task fire for a slot that passed
> before SipAI first saw it: creating a 9:00 task at 14:00 doesn't start
> a run. A one-time task is the exception, because its moment was
> chosen ahead of time: if SipAI first sees it after that moment — you
> quit right after creating it — the catch-up rule decides, as for any
> missed slot.

A task whose schedule is still sitting in your crontab is read into its
`SKILL.md` on first launch and the crontab entry removed, so one task can
never end up with two schedulers.

---

## Settings

Click **Settings** at the bottom of the sidebar and a menu of its
sections rises from it. Pick one and the sidebar lists every section —
**Factory reset** last, set apart — while the section fills the window
beside it; **Back to app**, where Settings was, returns to whatever you
had open.

| Section | What's in it |
|---|---|
| **Chat Settings** | A short explanation of what a chat is — a message sent straight to a provider's API on your own key, billed per token — pointing anyone who would rather use a subscription at an agent session's **Chat only** mode; then every configured model, which one is the default, add / remove, and the provider each belongs to; then the system prompt sent with every chat message, and named roles — reusable prompts you switch between per chat. The prompt and roles are for chats only: agent sessions, Chat only mode included, never use them. One starter role (Code Reviewer) ships as a worked example; add your own with **Add Role** |
| **Agent Initialization** | Why a command-line tool is needed, then one card per agent — Claude Code, Codex, Kimi Code — with the installed version, whether it is signed in and as what, and what it needs: **Install** (the vendor's own installer, or OpenAI's release package for Codex), **Sign In** (a subscription, or pay-per-use billing — an Anthropic Console sign-in for Claude Code, an API key for Codex and Kimi Code), and — once installed, signed in or not — **Delete** (the same as uninstalling in Terminal, offered when SipAI can tell how the tool was installed; sessions and any sign-in stay; on a tool not signed in it sits before Sign In), plus **Sign out** and a **Show … in SipAI** checkbox that hides the agent everywhere without removing it. Opening it asks each installed tool, with its own login, what it is signed in as. Updating a tool is under Updates |
| **Agent Skills** | Each agent's skills under that agent — its own for every folder and for the chosen one, its plugins' and its built-in ones — with a *shared with* hint on a skill other agents have too; each skill's … menu switches it On, Only when I call it or Off, pins it so new sessions start with it, shares it with another agent (fixing its `SKILL.md` first where that agent reads it differently) and deletes it from that agent alone; New Skill and Add…. See [Skills](#skills) |
| **Files & Notes** | The dedicated folder the sidebar's local-files section browses, and which model writes notes |
| **Display** | Appearance (System / Light / Dark); Zoom, four sizes — Small, Default, Larger, Large text mode — that scale the sidebar, the conversation, the text box and the controls under it, the scheduled-task page, notes, and Settings itself together, and widen line spacing as they grow (the space between paragraphs and list items grows with it); the View menu's Zoom In (⌘+), Zoom Out (⌘−) and Actual Size (⌘0) move the same setting from anywhere, and a conversation, a chat or a note's preview keeps the line you were reading at the top; switches for the sidebar's Notes, Chats and Chat groups sections (a section's own … menu → Hide turns its switch off); a toggle for the notifications beside the logo (the sidebar's logo and wordmark are always shown — the notifications take the wordmark's place); the chatbox toggles (context usage, note button, note prompt, chat-group chip, role chip); Compact view for agent sessions (the toolbar window's switch, and View → Agent Session Compact View, ⌃⌘O); and spell-checking in the text boxes |
| **Labels** | Rename "You", "AI", and each agent's label as they appear above messages |
| **Language** | English and 中文 ship; switching asks for a restart, and warns that any agent turn in progress will be stopped |
| **Usage** | What each agent's plan reports — the toolbar T window's figures, with more room: Claude Code's own account of what is using your limits, Codex's credits, workspace spend cap, limit resets (usable here, after Codex's own confirmation), its lifetime, peak-day and streak figures and a year of token activity (point at a day for its exact token count), Kimi Code's 5-hour and monthly limits (weekly too on older plans) and Extra Usage — each beside a link to the tool's own usage page. An agent on an API key gets one line saying where it is billed, with the provider's page where there is one. The figures are asked for when the section opens, unless they are under a minute old, and with ↻; no tokens are spent |
| **Updates** | The running version, **Check Now**, a *Last checked* readout, and a toggle for the once-daily automatic check — and, when there is one, SipAI's new version with **Update…**, which shows its release notes and installs it — then one row per installed agent command-line tool not hidden in Agent Initialization: its version, whether a newer release exists, and **Update**, with switches for the tools' release check and for updating them automatically. A blue download icon beside this row (and beside **Settings** in the sidebar) means something here is new |
| **Privacy** | What SipAI keeps and sends, in three short paragraphs: it collects no data and keeps your chats, notes and settings on your Mac; what you send to an AI model goes straight to that provider, whose own privacy policy says how it handles your data (a note goes to your note model's provider); and apart from your AI providers it goes online only for the update checks, which you can turn off under Updates |
| **Help** | Expandable answers to the questions that come up most — getting a key, requests that fail, token usage and cost, why Codex shows a 258k window and how to get the larger one (with the two buttons that change it), why Claude Code said “Prompt is too long”, how much of a plan is used, what Chat only is, what Compact view changes, why Codex sometimes asks a question as plain text instead of on a card, what happens when an MCP server asks for your input, what happens when an agent runs something in the background, sending a message while the agent works, which of Codex's own commands work here, how cloud sessions work, chats versus agent sessions, agent CLI setup, what sharing a skill with another agent does, how the skill chip loads skills, where data lives, prompts and roles, organising and exporting, hiding a sidebar section or marking or deleting a whole group, and macOS folder permissions |

**Updates apply to release copies.** The test is a team identifier on
the running app's signature. A copy built to run locally — ad hoc, which
is what a fresh clone gets, or signed with a self-signed certificate —
has none, so it never offers itself updates: your build is yours, and
overwriting it with ours would discard any changes you made. (A build
signed with your own Apple team, `SIPAI_TEAM`, does carry one, and
checks for updates like a release copy.) On a locally-built copy the
pane shows the same rows as a released copy with the controls greyed
out — hover over one for why — and the menu's **Check for Updates…**
item is greyed out the same way. A released copy asks
`updates.sipai.dev` once a day whether a newer version exists, and the
Settings toggle turns that off. Nothing is downloaded until you
choose to install it, no usage data, account or system profile is ever
sent, and every update must carry a valid EdDSA signature before Sparkle
will install it. If an update is accepted while an agent turn is running,
SipAI asks whether to wait for the turn or interrupt it and install right
away. If it waits, the waiting update stands beside the logo with an
**Install Now** button until the turn ends, the download icon marks
Settings → Updates, and **Install Now** in either place installs at
once; quitting before the turn ends installs the update on the way out
without reopening the app. After an update relaunches SipAI, a notice
beside the logo says "SipAI updated to …" for five seconds.

**The agent command-line tools are checked too**, in the same pane. A
stale CLI fails silently — turns keep working against whatever models
the old binary knows, and Claude Code bakes its model aliases into its
binary, so one release behind can mean one model behind. Each tool's row
therefore names the installed version and, once a check has
succeeded, whether a newer release exists. The check asks the npm
registry (Claude Code, Codex) and `code.kimi.com` (Kimi Code) every
eight hours, sends nothing about you, is silent when it fails, and has
its own toggle — off, the rows still state the installed versions and
nothing leaves the machine.
**Update** runs the tool's own command — `claude update`, `codex update`,
`kimi upgrade` — and judges success by the version moving, never by the
exit code. Two installs take another road. A Codex installed from
Agent Initialization is updated the way it was installed — OpenAI's release
package for the new version, checked the same way — because `codex
update` does not recognise that install. And a Kimi Code installed by
Moonshot's installer declines `kimi upgrade` and names that installer
instead, so SipAI downloads the script over HTTPS and runs it pinned to
the version shown, into the folder the binary already lives in, without
touching your shell files. Nothing runs while a turn of that agent is in
flight.
A Claude Code or Kimi Code that Homebrew installed shows **Managed by
Homebrew** instead: their own update commands leave a Homebrew install
to Homebrew, which SipAI never runs, so update those with `brew
upgrade` in Terminal (Codex's `codex update` runs Homebrew itself and
keeps its row). Claude Code is checked against the release channel its
own settings name (`autoUpdatesChannel`), so a copy kept on the
`stable` channel is not called behind by the `latest` one.
A tool that cannot start shows **Can’t start**: asked its version, it
stopped with an error instead. npm, for one, can finish an update
without a tool's macOS program, and the tool then stops on every start.
**Details** shows what the tool printed, which usually says how to fix
it — Codex's own: reinstall with `npm install -g @openai/codex@latest`.
An update that ends that way says it did not go through, with those
words at the end of its details, and the plan-usage window shows them
on that tool's card.
A tool stays in this list and in the sidebar for the whole update —
npm, for one, removes a tool while it downloads the new version — and
shows the new version the moment it lands. **Cancel** keeps it listed
too: npm finishes the download it is in before it puts the old version
back, and the row says “Cancelling…” until it has. SipAI stops an
updater that is still running after fifteen minutes, unless it has
already removed the old version: then SipAI waits for the update to
finish, however long the download takes.
**Update these tools automatically** (off until you turn it on, and
available while the release check is on) does
the same by itself as soon as a new version is found — after any
running turn of that tool finishes. If an automatic update doesn't go
through, the tool's row says why. A message you send to a tool while
SipAI is updating it waits: a line under it says so, and it goes out
the moment the update finishes.

**When something is out of date** — SipAI itself or one of these
tools — it stands beside the logo at the top of the sidebar, as a name
and a version (“Claude Code 2.1.300”), with an update button and a ×,
until you use one of them. The update button runs the same update as
the tool's row in Settings → Updates (and waits, like the row, for a
running turn of that tool); for SipAI it opens the update window with
the release notes. The × hides that version; a newer release comes
back, and so does an update that was tried and did not go through.
When Claude Code stops its own download because it took longer than
the 10 minutes Claude Code allows — a slow connection can do that —
the failed update says “10-min timeout” instead of a name and a
version; pointing at it gives the whole sentence.
With several out of date, they come one at a time. A small blue
download icon also appears beside **Settings** in the sidebar and
beside **Updates** inside Settings; it goes away once you open
Updates, and comes back only for a newer release. A tool that updates
itself, from SipAI or elsewhere, takes both down on its own; one set
to update automatically shows them only if its update fails.

**Whenever a tool is updated** — by an update button, automatically,
by the tool itself, or with `claude update` in Terminal while SipAI is
open — a notice beside the logo says so for five seconds (“Claude Code
updated to 2.1.300”). SipAI notices an update made outside it within a
minute, or as soon as you switch back to it.

**Factory reset** sits at the bottom of the Settings sidebar. It wipes
chats, chat groups, notes, models, API keys, scheduled-task definitions
and every setting, then returns the app to first-run setup without
quitting. The agent CLIs' own stores (`~/.claude/projects`, `~/.codex`,
`~/.kimi-code`) are untouched — but `~/.claude/scheduled-tasks` *is*
emptied, deliberately: a reset app must not keep firing tasks you can no
longer see. Past runs of those tasks survive, as ordinary sessions.

---

## Data and storage

```
~/Library/Application Support/SipAI/
├── config.json          providers + API keys, models, default model,
│                        note model, roles, display settings, labels,
│                        sidebar order, per-agent group state, session
│                        names and branch lineage, per-session launch
│                        options, unread marks, hidden agents, which
│                        turns ran Chat only, the Kimi tool-policy
│                        journal, theme, language, tagline
├── meta.json            chat-group folder-slug → name map
├── system_prompt.txt    your general system prompt
├── chat-only-instructions.md  the persona a Codex Chat only turn is given
├── usage.json           per-request token counts
├── scheduled_state.json scheduled-task run state
├── <slug>.json          a chat at the root level
├── <group>/
│   └── <slug>.json      a chat inside a chat group
├── notes/
│   └── <slug>.md        generated notes (Markdown)
└── mcp/                 the approver script, its MCP config, and the
                         socket Claude Code connects back through
```

Agent data is **not** SipAI's: Claude Code sessions stay in
`~/.claude/projects/`, scheduled tasks in `~/.claude/scheduled-tasks/`,
Codex rollouts in `~/.codex/sessions/`, and Kimi sessions under
`$KIMI_CODE_HOME` (default `~/.kimi-code/`). SipAI reads those in place,
and writes into them only in each agent's own format: a branch (a new
Claude Code transcript beside the original, a Kimi session directory in
`kimi fork`'s shape plus one `session_index.jsonl` line, or a fork Codex
makes itself), a rename (Claude Code's `custom-title` record plus
`custom-title.json`, Kimi's `state.json`; Codex names stay in SipAI's
config), an edit sent in place (made by each agent itself: Claude Code's
next turn resuming at the earlier message, Codex's revert, Kimi Code's
undo), a Kimi Chat only turn's `tool-policy/state.json`, put back when
the turn ends, and — through Codex itself — `model_context_window` in
`~/.codex/config.toml`. Skills you share from Settings → Agent Skills live in
SipAI's skill library, `~/.sipai/skills` (or `.sipai/skills` in a
project), with a link in each agent's skills folder; a skill switched off
goes through the agent's own switch (Claude Code's
`.claude/settings.local.json` for the folder, Codex's `config.toml`). Outside those stores, a Codex installed from
Agent Initialization lives in `~/.local/share/sipai/codex` with a `codex` link in
`~/.local/bin`, and an install may add one PATH line to your shell's
startup file.

A folder you nominate in **Settings → Files & Notes** gets its own
sidebar section, named after the folder. Expanding it lists what is
inside that folder's `chats/` and `notes/` subfolders, which are found by
a hidden marker file rather than by name, so renaming either one in
Finder doesn't lose track of it. It is a browser and nothing more —
SipAI reads that folder and never writes to it. Chats and notes live
where the tree above says they do, and a note leaves that tree only when
you download it, to wherever the save panel points.

### About API keys

A key you paste is stored in plaintext in `config.json` under
`providers.<key>.api_key`, and the file is written owner-only
(`chmod 600`) as defence in depth. Keys are never uploaded anywhere —
every request goes straight to the provider — but if you'd rather not
have a key on disk at all, fill in **Use environment variable** instead
of the key when you add the provider (Add Model's key step): only the
variable's *name* is stored, and the value is read at runtime.

A key you paste into **Settings → Agent Initialization** is different: it goes
straight to that tool's own sign-in — Codex keeps it in
`~/.codex/auth.json`, Kimi Code in its `config.toml` — and SipAI keeps
no copy.

Nor is a request kept anywhere else: requests to a provider never go
into the web cache macOS keeps for an app, and SipAI deletes that cache
each time it starts (Factory reset empties it too) — an earlier version
did keep some there, a key in its header included.

One caveat that trips people up: an app launched from the Dock inherits
launchd's minimal environment, not your `~/.zshrc` exports. SipAI works
around this by capturing your login shell's environment at startup, so
env-var keys resolve the way they do in a terminal.

---

## Project structure

The repository root holds this README, the release notes, the licence,
and two directories — the app, and the small GitHub Pages site that
serves the update feed:

```
├── README.md
├── CHANGELOG.md                      release notes, and the source the
│                                     in-app update dialog renders
├── LICENSE
├── THIRD-PARTY-LICENSES.md           Sparkle's, KaTeX's and zstd's
│                                     licences, reproduced whole
├── docs/                             the Sparkle appcast host behind
│                                     updates.sipai.dev
└── SipAI-macOS/                      everything that builds the app
```

Inside `SipAI-macOS/`:

```
SipAI-macOS/
├── SipAI.xcodeproj/
├── Signing.xcconfig                  ad hoc by default; Local.xcconfig
│                                     (gitignored) overrides with your team
│                                     or your own certificate
├── Release/                          the release pipeline — see below
├── Verification/                     behaviour harnesses — see below
└── SipAI/
    ├── SipAIApp.swift                @main — wires the managers together
    ├── Models/
    │   ├── APIClient.swift               OpenAI / Responses / Anthropic transports
    │   ├── AgentCLIUpdates.swift         agent CLI versions, release checks, updaters
    │   ├── AgentEventParsing.swift       claude stream-json → StreamEvent
    │   ├── AgentGuide.swift              presence (listed / not), install, sign-in, delete
    │   ├── AgentLaunchOptions.swift      mode / model / effort / speed, Chat only, catalogs
    │   ├── AgentManager.swift            CLI detection, session list, history cache
    │   ├── AgentQuestions.swift          a question card's form, its answers, the clock's pause
    │   ├── ApprovalCardRules.swift       the cards' keyboard, a plan's answers, what Allow Always remembers
    │   ├── AgentRunner.swift             one agent subprocess (pty + read loop)
    │   ├── AgentSession.swift            session scanner + JSONL history reader
    │   ├── AgentSessionFork.swift        branching a Claude Code session
    │   ├── AgentSessionGrouping.swift    folder / date / state / custom grouping
    │   ├── AgentSessionRename.swift      a rename, written in the agent's own format
    │   ├── AgentSessionTailer.swift      follows turns another process runs
    │   ├── AppState.swift                routing + composer drafts
    │   ├── AttachmentInline.swift        inlined attachment blocks and image markers
    │   ├── ChatAttachment.swift          reading and sizing attached files
    │   ├── ChatManager.swift             chat load / save
    │   ├── CodexEventParsing.swift       `codex exec --json` → StreamEvent
    │   ├── CodexRecordedTools.swift      a Codex tool row, live and from the session file's records
    │   ├── CodexSessionFork.swift        branching a Codex session, through Codex
    │   ├── CodexSessions.swift           Codex rollout scanner + reader
    │   ├── ConfigManager.swift           config.json round-trip
    │   ├── FactoryReset.swift            the wipe-and-start-over path
    │   ├── GlobalSearch.swift            the ⇧⌘F search-everything index
    │   ├── KimiEventParsing.swift        kimi stream-json → StreamEvent
    │   ├── KimiSessionFork.swift         branching a Kimi session
    │   ├── KimiSessions.swift            Kimi wire-file scanner + reader
    │   ├── KimiToolPolicy.swift          the tool-policy file a Kimi Chat only turn uses
    │   ├── KimiWebTurn.swift             a new Kimi session's first Chat only turn
    │   ├── MCPBridge.swift               approval and question bridge (UDS + approver.py)
    │   ├── McpElicitation.swift          an MCP server's form or link, drawn and answered
    │   ├── NotesManager.swift            notes, including in-place editing
    │   ├── NotificationCoordinator.swift  system notifications for approvals
    │   ├── PlanUsage.swift               plan-usage probes and account verdicts
    │   ├── ProjectManager.swift          chat groups
    │   ├── ProviderCatalog.swift         built-in providers + regions
    │   ├── ScheduledTaskCreator.swift    composer → SKILL.md
    │   ├── ScheduledTaskDefinition.swift the SKILL.md model + cron parsing
    │   ├── ScheduledTaskScheduler.swift  the in-app timer and due rule
    │   ├── SidebarNotices.swift          the notices beside the sidebar's logo
    │   ├── SipaiPaths.swift              Application Support paths + slugify
    │   ├── SkillCatalog.swift            each agent's skills, as its files and its CLI say
    │   ├── SkillModel.swift              skill folders, SKILL.md, preloading, load records
    │   ├── SkillOps.swift                sharing, moving, creating, editing a skill
    │   ├── UpdateController.swift        Sparkle wiring + install timing
    │   └── UpdateNotices.swift           the download badge, and turns that wait for an update
    ├── Utilities/
    │   ├── AgentRendering.swift          tool-input / result summarising
    │   ├── ChatOnlyActivity.swift        a Chat only turn's one-line activity
    │   ├── CodeBlockActions.swift        Copy and Save on code blocks
    │   ├── DesignSystem.swift            colours, spacing, font tiers
    │   ├── HangCapture.swift             Debug builds: a `sample` of a hung main thread
    │   ├── LatexSymbols.swift            LaTeX → Unicode, for inline math
    │   ├── MarkdownRenderer.swift        block-level Markdown (memoised)
    │   ├── Math*.swift                   typesetting display equations
    │   ├── NoteHTML.swift                a note as HTML, for KaTeX and PDF export
    │   ├── SearchMatching.swift          case- and accent-insensitive matching
    │   ├── SettingsPageLayout.swift      the Settings page's centred column
    │   ├── ShellEnvironment.swift        login-shell env capture
    │   ├── TranscriptFollow.swift        the stay-at-the-bottom scroll rule
    │   ├── TranscriptSeam.swift          where saved history meets live rows
    │   ├── UpdateInstallHold.swift       holding an update for a running turn
    │   ├── UpdaterAvailability.swift     is this build allowed to self-update
    │   └── ZstdFileDecoder.swift         reading Codex's compressed sessions
    ├── Vendor/zstd/                      zstd's decoder, unmodified (BSD), with
    │                                     its licence; sipai_zstd.c builds it
    ├── Views/
    │   ├── ContentView.swift             onboarding-or-main, sidebar + centre pane
    │   ├── GlobalSearchPalette.swift     the ⇧⌘F overlay
    │   ├── OnboardingView.swift          first-run welcome page
    │   ├── ModelSetupSheet.swift         Add Model window
    │   ├── UsagePopover.swift            the plan-usage window
    │   ├── Chat/                         chat, agent session, composers, find bar,
    │   │                                 the permission, plan and question cards,
    │   │                                 scheduled-task panel + timing editor
    │   ├── Notes/                        note viewer + editor
    │   ├── Settings/                     settings pages, the menu and sidebar
    │   │                                 list that reach them, Agent Initialization pane
    │   └── Sidebar/                      the logo and its notice bubble; sections:
    │                                         chats, groups, agents, notes, files
    └── Resources/
        ├── Assets.xcassets               app icon + logo renditions
        ├── approver.py                   MCP approver spawned by Claude Code
        ├── Credits.rtf                   what About SipAI shows: the Sparkle,
        │                                 KaTeX and zstd acknowledgements
        ├── THIRD-PARTY-LICENSES.txt      the same licence text the repo root
        │                                 carries, bundled so it ships with
        │                                 the app
        ├── katex/                        KaTeX's script, stylesheet and WOFF2
        │                                 maths fonts, for notes
        └── Localizable.xcstrings         String Catalog (English + 中文)
```

`SipAI-macOS/Verification/` holds small harnesses — each with a
self-contained `run.sh` — that compile the real sources against stubs
and pin the behaviours with the worst regression history: the provider
catalog, note editing and export, session forking, the runner's stdout
drain, the context chip, scheduled-run visibility, one-time and deleted
scheduled tasks, the schedule chips and when a task may fire, the Kimi
Code assumptions and session discovery, transcript search and the
renderer's link gate, code blocks, a slash command's answer surviving a
reload, the composer's Enter key and session-id tokens, the sidebar's
lockup and the notices beside its logo, groups, dots and Settings
navigation, factory reset, the model
chip, fast mode, Chat only, the approval, plan and question cards and
their keyboard, skills, the skill catalog's reads and the Agent Skills
pane, Agent Initialization, the
plan-usage window, the CLI update rules, and an end-to-end Sparkle
update. Most are token-free; `KimiCode` spends two real one-word turns,
`SparkleUpdate` builds the app, and the live sections elsewhere run only
when their environment switch is set — each `run.sh` says what it does
in its header. A check of what appears under the pointer points with
made-up events. SwiftUI answers a pointer only while macOS reports the
cursor visible, and macOS can report it hidden from a pointer at rest
(under Screen Sharing, for one), so those harnesses run their test
programs with the cursor reported visible inside the program alone
(`SyntheticHover`); should a plain test view still get no hover, the
check says SKIP and why rather than failing.
Run the relevant one after touching
the code it covers; after upgrading an agent CLI, run the ones that
drive it — `KimiCode`, `CodexContextTokens`, `CodexContextWindow`,
`ContextChip`, `AgentSessionFork`, `ExternalTurnWatch`, `ChatOnlyMode`,
`FastMode`, `ComposerModelChip`, `UsageWindow`, `AgentGuide`,
`ApprovalCards`, `AgentQuestions`, `Skills` (with `SIPAI_SKILLS_LIVE=1`)
and `CLIUpdates` — since they are what notice a changed file format or
interface.

`SipAI-macOS/Release/release.sh` is the whole release: archive, export
under a Developer ID, notarize and staple, build the DMG, build the
Sparkle update archive, and generate the signed appcast into `docs/`.
`./release.sh --preflight` checks every prerequisite — certificate,
notarization credentials, the EdDSA signing key, version consistency
between the two build configurations, that the version is the
changelog's newest section and its build number rises above the
published one, a dated CHANGELOG section — and builds nothing, so a
missing piece costs a second rather than a full build. It ends by
printing the publish steps in the one order that works: tag first, the
GitHub release with both assets second, and the push that puts the feed
live last. No credential is stored in the repository: the signing identity
comes from the login keychain and notarization from a `notarytool`
keychain profile. Release notes are rendered from `CHANGELOG.md` by
`changelog_to_html.py`, so the update dialog and the changelog can never
drift apart.

---

## Troubleshooting

**"Signing for SipAI requires a development team"**
Something has set a team the machine has no account for — most likely a
stale `SipAI-macOS/Local.xcconfig`, or a team picked once in **Signing &
Capabilities**. Delete the `Local.xcconfig` line to fall back to ad-hoc,
or put your own Team ID in it. See [Signing a build of your
own](#signing-a-build-of-your-own).

**The build stops at the signing step, naming a certificate it can't find**
`SipAI-macOS/Local.xcconfig` names an identity this Mac's keychain
doesn't hold — deleted, renamed, expired, or the file was copied from
another machine. Delete its two lines to fall back to ad-hoc, or create
a Code Signing certificate under that exact name. The
`Verification/SparkleUpdate/run.sh` harness reports the same thing
without a build.

**"BUILD FAILED" mentioning a missing file**
`project.pbxproj` is probably out of sync after a manual file add or
remove. Re-add the file through Xcode's Project navigator.

**Xcode reports "Missing package product 'Sparkle'"**
A package resolution that failed once is latched for the life of the
Xcode process, and every later build reports it even after the download
succeeds. File → Packages → Resolve Package Versions clears it; so does
quitting and reopening Xcode. Nothing on disk needs fixing, and resolving
from a terminal does not reach the latch. Avoid running `xcodebuild`
against the project while Xcode has it open — both processes resolve
packages into the same cache, and the loser is what latches.

**The window never takes focus**
`SipAIAppDelegate` explicitly sets `.regular` activation policy and
activates the app. If that adapter goes missing, the symptom is "no dock
icon, no focused window".

**No model list when adding a model**
The error carries the provider's own words — usually a rejected key or
the wrong region. Two ways out, both on that screen: the manual model-id
field underneath, which saves identically and verifies the id for you,
and **Edit key or endpoint**, which returns to those fields with the
provider still selected. Try the endpoint even if the key is certainly
right: providers move their API hosts, and a base URL this app shipped
with can be out of date.

**A key that "works in my terminal" doesn't work here**
Dock-launched apps don't see shell exports. SipAI captures your login
shell's environment at startup, but if the export lives somewhere that
shell doesn't read, paste the key itself, or move the export to a file
your login shell reads (for zsh, `~/.zshrc` or `~/.zprofile`) and
relaunch SipAI. Starting it with `open -a SipAI` doesn't help: `open`
launches it with the system's environment, not your terminal's.

**An agent turn produces nothing at all — no output, no error**
An agent that cannot reach its provider usually keeps retrying instead
of failing. While it says it is retrying, a row under "Sipping…" shows
the attempt; one that retries in silence gets a note in the transcript
after five minutes with no output, saying the turn is still running and
may be blocked. If
your network needs a proxy, export `HTTP_PROXY` / `HTTPS_PROXY` /
`ALL_PROXY` in your login shell: agent CLIs ignore the macOS system
proxy, and SipAI passes those variables from your shell to the agent.

**An agent's section is missing even though I have sessions**
SipAI lists an agent only while its CLI is installed AND signed in, and
not unticked in Settings → Agent Initialization. Open it: its card says
which of the three is missing and offers the fix. SipAI looks for the
binary on its own search list plus your login shell's `PATH`, and for
the sign-in in the CLI's own files (`~/.claude.json`, `~/.codex/auth.json`,
kimi's `config.toml` and token file); a `login` in a terminal is noticed
within a few seconds, no relaunch. Sessions live under
`~/.claude/projects/*/<session-id>.jsonl`, `~/.codex/sessions/`, and
`$KIMI_CODE_HOME/sessions/` (default `~/.kimi-code/sessions/`) and are
never touched by any of this.

**Install in Agent Initialization said it ran, but Terminal can't find the tool**
The tool went where its installer puts it — `~/.local/bin` for Claude
Code; OpenAI's package in `~/.local/share/sipai/codex`, with a `codex`
link in `~/.local/bin`, for Codex; `~/.kimi-code/bin` for Kimi Code.
SipAI finds those directories itself; a Terminal only does if they are
on your shell's `PATH`. Kimi's installer adds its own line to your
shell's startup file; for the other two SipAI appends one guarded line
putting `~/.local/bin` on the `PATH` — to `~/.zshrc` for zsh, `~/.bashrc`
or `~/.profile` for bash, `config.fish` for fish, and to nothing for any
other shell — when your login shell's `PATH` lacks the directory. Open a
new Terminal window for it to take effect.

**Approval cards never appear**
`MCPBridge` writes `approver.py` into
`~/Library/Application Support/SipAI/mcp/` and Claude Code runs it with
Python 3. Without a reachable `python3` the approver can't start, and the
request never reaches the app. (Codex and Kimi Code ask through their
own protocols and need none of this.)

**Kimi in Terminal can't run commands or edit files in one session**
An asking-mode turn binds its Kimi session to that conversation's
runtime, and SipAI binds it back when the turn ends (see [Kimi
Code](#kimi-code)). If SipAI was force-quit mid-turn, the session keeps
the binding until SipAI next launches or opens it — both repair it.

**macOS asks for permission to a folder over and over**
Being asked *once* per folder is normal: agent sessions read and edit
real files, so the first time SipAI opens a project inside Desktop,
Documents, Downloads, iCloud Drive or an external volume, macOS asks. The
answer sticks, including across restarts, and scheduled runs reuse it
because they run inside the app.

Being asked *repeatedly* is about the copy you're running. An ad-hoc or
unsigned build is identified by the exact contents of its binary, so
every rebuild can look like a different app and the grant doesn't carry
over. Two fixes: switch SipAI on in **System Settings → Privacy &
Security → Files and Folders** to grant the copy you have now, or give
your builds a stable identity — a team ID or a self-signed certificate
in `SipAI-macOS/Local.xcconfig`, see [Signing a build of your
own](#signing-a-build-of-your-own). If you clicked Deny by mistake, the
agent will report that it can't read anything in the folder — re-enable
SipAI in that same pane and send again.

**Renames, groups or branches keep reverting**
Two copies of SipAI running at once — say the release in
`/Applications` and a build of your own — share one `config.json`, and
each writes the whole file from what it had in memory. Whichever saves
last wins, so the other's renames, custom-group filings and branch
lineage go. Run one at a time.

**A scheduled task didn't run**
The app has to be open at the scheduled moment. A slot missed by less
than a day fires once, about fifteen seconds after you reopen it — the
task's editor can turn that catch-up off — and an older miss is recorded
as skipped. A task whose agent is hidden, signed out or uninstalled
doesn't fire until the agent is listed again. A time
that comes while the task's previous run is still going is skipped after
five minutes, and times that pass while a task is paused aren't made up
when you resume it. Check the task's panel: it names the next run and
how the last one went.

**A scheduled task ran twice at the same time**
Two copies of SipAI running at once — say the release in
`/Applications` and a build of your own — each fire every scheduled
task on its schedule. Run one at a time.

**The app froze — how do I report it usefully?**
A hang leaves no crash report. If you are running a Debug build (from
Xcode), the app samples itself once the main thread has been silent for
about twelve seconds and writes every thread's stack to
`~/Library/Logs/SipAI/hang-<date>.txt`; attach that file. On a released
build, run `sample SipAI 5 -file ~/Desktop/sipai-hang.txt` in Terminal
(or Activity Monitor → ⋯ → Sample Process) *before* force-quitting —
after the quit there is nothing left to look at.

**The model picker still names last month's model**
The agent CLI is behind, not SipAI: Claude Code resolves `fable`,
`opus` and the rest inside its own binary, and the picker names each
alias by what the installed binary resolves it to, so a stale install
keeps naming — and running — the models it shipped with. **Settings →
Updates** lists each installed CLI's version and offers **Update** when
a newer release exists, and a blue download icon beside **Settings**
says there is something to look at. If the CLI is current and a row is still old, send one message
under that row — the chip's hover then shows the model it actually
ran.

**Start completely fresh**
Delete `~/Library/Application Support/SipAI/`, or use Settings → Factory
reset, which also empties `~/.claude/scheduled-tasks` so nothing keeps
firing behind your back. Agent session stores under `~/.claude/projects`,
`~/.codex` and `~/.kimi-code` are never touched — remove those separately
for a full wipe.

---

## License

MIT — see [LICENSE](LICENSE). Use it, change it, ship it; keep the notice.

SipAI links and redistributes three third-party components. Two are
under the MIT licence: **[Sparkle](https://github.com/sparkle-project/Sparkle)**
2.9.6, the macOS update framework behind Settings → Updates, and
**[KaTeX](https://github.com/KaTeX/KaTeX)** 0.18.4, which lays out the
mathematics in notes — the Preview pane and "Save as PDF" — and is
bundled with its WOFF2 maths fonts. The third is the decoder of
**[Zstandard](https://github.com/facebook/zstd)** 1.5.7, under its BSD
licence, which reads Codex sessions stored compressed. Their full texts — Sparkle's
including the external licences it carries for bsdiff, sais-lite, the
portable Ed25519 implementation and SUSignatureVerifier — are in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md), and ship inside every
copy of the app: **About SipAI** names all three, and the whole text is at
`SipAI.app/Contents/Resources/THIRD-PARTY-LICENSES.txt`. Nothing else in
this repository is derived from third-party code, and apart from
KaTeX's maths fonts no third-party fonts, icons or artwork are
bundled.

### Trademarks

SipAI is an independent project with no affiliation to, sponsorship by,
or endorsement from any AI provider. Claude and Claude Code are
trademarks of Anthropic; Codex and ChatGPT are trademarks of OpenAI;
Kimi and Kimi Code are trademarks of Moonshot AI; every other provider
and product named here belongs to its respective owner. Those names
appear only to say what SipAI interoperates with.

### How it was built

SipAI was written with the help of AI coding assistants. The main
assistant was **Claude Code**; **Codex** and **Kimi Code** also made
their contributions. They are the same three agents the app drives —
SipAI is a client for the tools it was built with.

That changes nothing about who is responsible for it. One human author
directed the work, reviewed what went in, holds the copyright and
answers for the result. An assistant is a tool here, the way a compiler
or an editor is; none of them is credited as an author, in the commit
history or anywhere else.

---

Created by **Yizhan Huang (黄一展)**.
Copyright © 2026 Yizhan Huang.
