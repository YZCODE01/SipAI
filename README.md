# SipAI

A native Swift / SwiftUI desktop app for macOS that does two things:
chatting with any of 20 built-in AI providers (plus anything
OpenAI-compatible), and living inside your Claude Code, Codex and Kimi
Code sessions. Chats, notes, roles, agent transcripts that stream as they
happen, inline permission approvals, and scheduled agent tasks the app
fires itself.

Everything is local: your keys, your chats, your notes. Requests go
straight from your Mac to the provider you picked. The only other call is
a once-daily update check, which sends nothing about you and can be
turned off in Settings.

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
launch](#first-launch) walks through it.

Once installed, SipAI keeps itself up to date: it asks
`updates.sipai.dev` once a day, shows you the release notes, and installs
nothing until you say so. Turn it off in **Settings → Updates**.

Rather build it yourself? See [Build and run](#build-and-run) — a copy
you compile never offers itself updates, on purpose.

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
| **A model** | An API key from any supported provider. A local server (Ollama, LM Studio, vLLM, …) works too — add it through **Custom (name & URL)** with its base URL |
| **Optional** | An agent CLI, for agent sessions: [Claude Code](https://docs.anthropic.com/claude/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`), [Codex](https://developers.openai.com/codex/cli) (`npm install -g @openai/codex`) and / or [Kimi Code](https://github.com/MoonshotAI/kimi-code) (`curl -fsSL https://code.kimi.com/kimi-code/install.sh \| bash`). Any one of them, signed in, is driven fully from inside the app |

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
need. If you're going to *run* the app rather than just build it, sign
with your own team. Create `SipAI-macOS/Local.xcconfig` with one line:

```
SIPAI_TEAM = ABCDE12345
```

That is your ten-character Team ID, from Xcode ▸ Settings ▸ Accounts or
from developer.apple.com. The file is gitignored, and the signing
identity follows from it, so one line is the whole change — and unlike
picking a team in **Signing & Capabilities**, it doesn't write your team
into `project.pbxproj`, where it would break the build for everyone else.

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

On a fresh install (no models configured, setup never completed) the app
opens a wizard instead of the main window:

1. **Welcome.**
2. **Choose a provider.** A searchable list of all 20 cloud providers in
   alphabetical order, an **Image Models** entry, and a **Custom** entry
   for any OpenAI-compatible URL — which is also how you reach a local
   server (Ollama, LM Studio, vLLM, …) or anything self-hosted. If an
   agent CLI is already installed, a quiet **Skip — agent sessions only**
   link at the bottom lets you leave without configuring a chat model at
   all. Image models can be configured, but configuring is as far as it
   goes for now — nothing in the app generates an image yet.
3. **API key.** Paste it, or name an environment variable that holds it —
   env-var mode stores only the variable's *name* and reads the value at
   request time, so the key never touches disk. Providers whose keys are
   bound to one platform or region (Qwen, Moonshot, MiniMax, Volcengine,
   Z.AI) ask which endpoint yours came from, with an **Other…** option
   for a URL of your own; every other provider has an **Endpoint**
   disclosure for the same purpose.
4. **Set your default chat model.** The app calls the provider's
   `/models` endpoint and lists what it finds — chat models only, newest
   first, long lists capped behind **Show all**. **Enter model ID
   manually** opens a field with live verification, and is always
   available. For OpenAI you also pick the API style, Chat Completions or
   Responses, because some models answer only one of them. NVIDIA,
   Hugging Face and Venice publish their catalogue *without* checking the
   key, so on those the model you pick is probed once — a list arriving
   there proves nothing about your credentials. If a fetch fails for any
   reason, **Edit key or endpoint** goes straight back to the fields that
   fix it; a shipped base URL can simply be out of date.
5. **Your chat models.** Optional: add more from the same or a different
   provider, change which one is the default, or delete one.

**Get started** / **Continue** move through the steps, and **Finish**
drops you into the main window with your new model selected. Everything
here is reachable again later from **Add Model** (in the composer's model
picker) or from **Settings** — except image models, which only the wizard
offers.

---

## The window

```
┌──────────────────┬─────────────────────────────────────────────┐
│  Left sidebar    │  Centre pane                                │
│                  │                                             │
│  Notes           │   • a chat, or                              │
│  <your folder>   │   • an agent session transcript, or         │
│  Chats           │   • a note                                  │
│  Chat groups     │                                             │
│  Claude Code     │   with its composer pinned to the bottom    │
│  Codex           │                                             │
│  Kimi Code       │                                             │
│  ⚙ Settings      │                                             │
└──────────────────┴─────────────────────────────────────────────┘
```

- **Sections collapse** independently and **drag into the order you
  want** — grab a section header and move it; the order persists.
  ⚙ Settings is pinned at the bottom, and is a button rather than a
  section.
- **Drag the divider** to resize the sidebar. ⌃⌘S, or the toolbar button
  next to the traffic lights, hides it entirely.
- **Every row has a ⋮ menu** on hover or right-click: chats rename / move
  / delete, notes rename / download / delete, agent sessions and
  scheduled tasks rename / delete / file into a group.
- **Sections appear when they're relevant.** The local-files section
  exists only once a dedicated folder is configured, and takes that
  folder's own name; **Codex** and **Kimi Code** appear once their CLI or
  their session store does.

The centre pane shows exactly one thing at a time, and switching never
costs you a half-written message — unsent composer text is stashed per
conversation and restored when you come back.

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
  transcript for all three agents, tool calls and tool results included.
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

- **Rich rendering.** Fenced code blocks with a dim language label,
  headings, horizontal rules, ordered / unordered / nested lists, block
  quotes, tables (with per-column alignment), bold / italic / inline
  code, auto-linked URLs, and LaTeX symbol translation (`\pi` → π,
  `x^2` → x², `H_2O` → H₂O, `\frac{a}{b}`, `\mathbb{R}`, …). Inline code
  is shielded from the LaTeX pass, so `snake_case` survives intact. Every
  rendered block is selectable, and hovering one of your own messages
  reveals a copy button in its corner. Only `http`, `https` and `mailto`
  links are clickable — a model's reply, a note or an agent's tool result
  can put any address behind any words, and the rest of what macOS would
  accept there opens applications rather than pages.
- **The input card** holds everything: the text box (Enter sends,
  Shift+Enter newlines), **+** to attach files, a **notebook** button
  that turns the conversation into a note, a find magnifier, project and
  role chips (each appears once enabled in Settings → Display), the
  **model picker**, and a send button that becomes a stop button while a
  reply is in flight.
- **Attachments** are read as text and inlined into your message; a
  banner names what's staged for the next send. Anything unreadable as
  text, or over 100,000 characters, stops the send with an explanation
  rather than being dropped silently.
- **Replies arrive complete**, not streamed — the app shows a "Sipping…"
  indicator with a running clock while it waits, and Stop cancels. A
  reply cut short by the model's output limit is flagged ("Response may
  be incomplete") rather than left looking whole.
- **Assistant messages are headed by the model id and how long the reply
  took**; your own messages name their attachments.
- **Long chats open on the newest messages** — 40 at a time, with a
  **Show earlier** button above.
- **Branch from any of your messages.** Hover a message you sent, click
  the pencil, edit the text, and **Create Branch** copies everything
  above it into a new chat — titled "X (branch)" — and sends your edit
  there. The original is untouched.
- **Chat groups** are folders for related chats. Create one from the
  section's **+ New group** row, or move a chat in from its ⋮ menu or the
  composer's project chip. Groups drag into whatever order you want;
  deleting one removes its chats too, after a warning that says so.
- **Titles** start as the first few words of your first message; rename
  anytime from the row's ⋮ menu.
- **Switching chats mid-reply is safe.** The answer is delivered to the
  chat that asked, even if you've moved on, and errors never surface on
  the wrong conversation. A chat waiting on its reply shows a pulsing dot
  in the sidebar.
- **The empty state** is editable: click the tagline next to the logo and
  write your own.

Nothing you type is intercepted as a command — every message goes to the
model as written. The actions live on controls instead: the composer
buttons, a row's ⋮ menu, or Settings.

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

From a note's ⋮ menu you can rename it, download it as Markdown, or
delete it. Which model writes notes is set in **Settings → Files & Notes
→ Note generating model** — useful if you want a thinking-heavy model for
notes and a fast one for chat.

---

## Agent sessions

An agent session is the Claude Code, Codex or Kimi Code CLI running on
your Mac, driven from a SwiftUI window instead of a terminal.

With `claude` on your `PATH`, the **Claude Code** sidebar section lists
every session under `~/.claude/projects/` plus the scheduled tasks under
`~/.claude/scheduled-tasks/`, and **+ New session** starts a fresh one.
Without the CLI the same sessions still list and still read, marked
read-only. `codex` and `kimi` get their own sections on the same terms.

SipAI reads those files in place — it keeps no copy of them, so a session
created in Terminal shows up here, and one created here shows up there.

No CLI's interactive TUI is embedded. All three are driven headless —
`claude -p --output-format stream-json`, `codex exec --json`,
`kimi --prompt --output-format stream-json` — and SipAI renders the event
stream itself, which is what makes inline approvals, live transcripts and
in-app scheduling possible.

### The transcript

Sessions render as a conversation, not as a terminal log:

- **User and assistant turns** as message bubbles with full Markdown.
- **Tool activity as collapsible chips** — chevron, icon, tool name, and
  a dim one-line summary (`Bash(npm test)`, `Update src/main.swift`).
  Click one to expand its full input and the result folded in beneath.
- **Errors** stand out in their own row.
- **Session plumbing stays out of the way** — the turn's duration and the
  session's context usage live on the composer, not between your
  messages.

Long sessions open on the newest turn with a capped window of history and
a **Show earlier** button above it. Opening a session you've already
visited is instant, because parsed transcripts are cached.

### Live streaming, wherever the turn came from

- **Turns you start here** stream in line by line, for all three agents,
  because SipAI runs the agent behind a pty and reads it on a background
  queue.
- **Turns started elsewhere** — a `claude` in Terminal, Claude Desktop, a
  scheduled run — stream in too. SipAI tails the session's JSONL,
  batching and coalescing updates so a fast external turn can't wedge the
  window, and the sidebar row shows the session as live while it works.
  This is Claude Code only: a Codex rollout and a Kimi wire file are
  different formats, and following one live is still to be built, so
  those sessions update here once their turn ends.
- **A dropped stream is retried, not abandoned**, behind a single notice
  row that the next attempt replaces. After a minute of total silence, a
  "No output from \<agent\> yet" row appears with the agent's own error
  output, and points at the likeliest cause if the silence lasts — a
  network route the CLI can't take, which looks exactly the same as a
  slow turn.

### Reading a session's state

In the sidebar, a session that is doing something swaps its icon for a
signal:

| Signal | Meaning |
|---|---|
| pulsing orange dot | a turn is running — started here, or by another terminal |
| yellow badge | waiting for you to approve a tool call |
| both | mid-turn *and* blocked on a permission |

In the transcript, a **“Sipping…”** spinner fills the gap between your
message and the agent's first output, and an unresolved tool row keeps
its own spinner until the result arrives. Nothing in the transcript
ticks: the clock lives on the composer, on purpose.

A turn that was killed — Stop, quit, a crash, a rebuild — is marked where
it stopped with an **Interrupted** row the next time the session loads.
That marker is derived rather than stored, so a session that turns out to
still be alive quietly loses it again.

### The composer

Under the input box sits a quiet control strip. Everything on the left
says *where and what* this session is; everything on the right says *how
this send will run*, then reports on it:

| Left | Right |
|---|---|
| working folder · schedule · add files · note · find | model · effort · permission mode · turn clock · token count |

- **Permission mode, model and effort** apply per send, and each agent
  gets its own vocabulary in those chips — see [the table
  below](#how-the-three-agents-differ). Leave model or effort at
  *default* and no flag is sent at all.
- **The folder** is editable while a session is still a draft, and fixed
  afterwards. A new session resolves its folder from the best evidence
  available — the last folder used, then the newest session on record;
  only a machine with no history at all starts at your home folder.
- **The schedule button** appears on drafts only: a session that already
  exists can't retroactively become a scheduled task. See [Scheduled
  tasks](#scheduled-tasks).
- **Add files** opens a picker (files or folders) and inserts the chosen
  paths into your message — quoted when they contain spaces — for the
  agent to read itself.
- **The turn clock** counts up while a turn runs and freezes on that
  turn's total when it lands, so the composer always answers "how long?"
  without a ticking row in the transcript.
- **The token count** ("47k tokens") is the session's context footprint,
  and every agent has one. The tooltip spells out the fraction of the
  window in use. Hide it in Settings → Display.
- **A scheduled run's** transcript carries a read-only tag with the time
  the run finished.
- **The send button becomes Stop** whenever a turn is in flight — for
  turns this app started, and for a headless run started elsewhere that
  it can still signal. When the writer is another terminal's interactive
  `claude`, Stop is shown disabled rather than swapped for a grey arrow:
  that turn stops where it started.

### How the three agents differ

Everything above is common to all three. These are the differences:

| | Claude Code | Codex | Kimi Code |
|---|---|---|---|
| Permission chip | permission modes (`bypassPermissions` … `plan`) | sandbox modes: Workspace Write, Read Only, Full Access | none — a fixed **Auto-approve** readout |
| Mid-turn approvals | inline Allow / Deny cards | none — the sandbox decides up front | none — headless runs approve their own tool calls |
| Model chip | aliases, with versions learned on this machine | literal Codex model ids, from its models cache, your config and recent sessions | aliases from kimi's `config.toml` |
| Effort chip | `low` … `max`, scraped from `claude --help` | per model, from the same sources as the model list | per model, when the model declares any; delivered as an environment variable |
| Token counter | live, from each assistant message | the context snapshot the rollout records, refreshed as the turn runs | summed from the session's usage records at turn end |
| Watching a turn started elsewhere | live | after it finishes | after it finishes |
| Slash commands | resolved by the CLI itself (`/mcp`, `/model`, `/context`), and the answer is kept with the session | none — the text is sent to the model as an ordinary message, and the composer says so before you do | none — same, and the composer says so |
| Branching a session | yes | no | no |
| Readiness | installed | installed **and** signed in (`~/.codex/auth.json`) | installed |
| Scheduled tasks | yes | yes | yes |

Model and effort lists are read from each CLI rather than hardcoded, so a
model or level the vendor adds shows up without a SipAI update. Both are
per model where the agent makes them per model: changing model clears an
effort the new model doesn't offer, rather than sending a value it would
reject.

### Branching a session

Hover one of your own messages, click the pencil, edit the text, and
**Create Branch** forks everything above it into a new session — a new
transcript file written beside the original, so both Claude Code and
SipAI treat it as its own session — then sends your edited text as its
first turn. The original session is untouched.

Claude Code only, because the branch is a Claude-format transcript, and
unavailable while a turn is running. Note that a branch rewinds the
*conversation*, not the working tree: files the agent already wrote stay
written.

### Approvals

This section is Claude Code's. A Codex session decides the same question
up front with its sandbox chip, and a Kimi session approves its own tool
calls; neither interrupts mid-turn.

When Claude Code asks permission for a tool call, the request surfaces
**inline in the transcript** as a card with **Allow / Deny / Allow Always
/ Deny Always** (Return and Escape drive the newest card). "Always"
decisions are cached per session, so the same tool and input stop
interrupting.

If the app isn't focused on that session, you get a system notification
instead, and clicking it opens the right session. Resolving a card
dismisses its notification.

Cards never outlive the turn that asked. Pressing Stop, quitting, or a
`claude` that exits on its own clears that session's pending cards — a
dead agent can't consume an answer, and a card whose buttons do nothing
is worse than no card.

Claude Code's own multiple-choice questions (`AskUserQuestion`) are
answered by SipAI before they can reach you. That tool draws its options
in Claude Code's terminal front-end, which doesn't exist under `claude
-p`: the call arrives as an ordinary approval, and whatever you click, the
agent is told the question went unanswered. SipAI declines it with a note
asking the agent to put the question in its reply text instead, where the
composer can answer it.

This all works through a small MCP approver that SipAI installs into
`~/Library/Application Support/SipAI/mcp/` and Claude Code launches on
demand.

### Organising the list

The section header carries a **Group by** menu:

| Mode | Groups by |
|---|---|
| None | nothing — newest first, the default |
| Folder | the directory the agent ran in, most recently used first |
| Date | Today, Yesterday, Previous 7 days, Previous 30 days, then by month |
| State | waiting for approval, working, running in another terminal, scheduled, then the rest |
| Custom | groups you name yourself |

The button tints while a grouping is on, and the choice persists. Group
headers show their row count and fold away when clicked; folded state is
remembered per mode, and headers drag into your own order. A folder
group's header carries a **+** that starts a new session already pointed
at that folder. Rows keep exactly the look they have with grouping off.

**Custom groups:** right-click a session or task → **Add to Group** →
pick one or create it. Unfiled rows collect under **Ungrouped**.
Right-click a custom group's header to rename or delete it; deleting
keeps every session and simply unfiles them. Group names live in this
app's `config.json`, never in the agent's session files.

Long lists are capped at 10 rows with a **Show all (N more)** row that
counts only what a *visible* group actually hid, and toggles back to
**Show less**.

Sessions whose working directory sits in a system temp folder are
filtered out as scratch — except scheduled runs, which are always shown.

---

## Codex

When the Codex CLI or its session store is present, a **Codex** section
appears in the sidebar listing rollouts from `~/.codex/sessions/`, with
the same thread names Codex Desktop shows, the same grouping, and the
same transcript rendering as Claude Code sessions.

**Codex sessions are driven in-app**, the same way Claude Code ones are:
**+ New session** opens a draft, sending runs `codex exec --json` behind
a pty, and the reply streams into the transcript turn by turn. Follow-up
sends resume the same thread (`codex exec resume`), so a conversation
started here continues here — and one started in a terminal continues
here too.

Beyond [the differences table](#how-the-three-agents-differ), three
things are worth knowing:

- **The sandbox is a real boundary**, not a label. The chip travels as
  `-c sandbox_mode=…`, which Codex itself enforces, so a **Read Only**
  session is refused permission to write a file where a **Workspace
  Write** one writes it. **Full Access** turns both the sandbox and
  approvals off. Leaving the chip on **Default** sends no override, so
  Codex decides from its own config.
- **Codex runs outside a git repo.** SipAI passes
  `--skip-git-repo-check`, because a session can point at any folder and
  Codex otherwise refuses to start there. The sandbox mode, not the git
  check, is what bounds what a run can touch.
- **Subagent sessions appear too.** Runs Codex spawned as subagents get
  their own titles and a distinct glyph, sorted after your own sessions.

A session whose CLI is missing — or installed but not signed in — still
lists and still reads, with a read-only bar in place of the composer
naming the fix (`npm install -g @openai/codex`, then `codex login`).
Detection re-checks every few seconds, so signing in flips the section to
interactive without a relaunch.

---

## Kimi Code

When the [Kimi Code](https://github.com/MoonshotAI/kimi-code) CLI or its
session store is present, a **Kimi Code** section appears in the sidebar
listing sessions from `$KIMI_CODE_HOME/sessions/` (default
`~/.kimi-code/sessions/`) — same grouping, same transcript rendering,
same **+ New session** draft as the other two. Sending runs
`kimi --prompt … --output-format stream-json` behind a pty; follow-up
sends pass `--session <id>` so the conversation continues.

> **A Kimi session driven from SipAI can edit files and run commands
> without asking.** The Auto-approve chip is a statement of fact, not a
> setting: kimi refuses `--yolo`, `--auto` and `--plan` on a `--prompt`
> run, because print mode already approves every tool call itself. There
> is nothing to choose, so SipAI shows what is in force rather than a
> picker it could not honour. Point a Kimi session at a folder you are
> willing to let it change.

The model chip lists the aliases from kimi's own `config.toml` and marks
the configured default, because kimi rejects a model that file doesn't
declare. If the file yields nothing, the chip falls back to models recent
sessions used, and failing that offers **Default** alone, which sends no
`--model` and lets kimi's configuration decide.

A session whose CLI is missing still lists and still reads, with a
read-only bar naming the fix. There is no signed-in check: unlike Codex,
Kimi has no credential file this app can read, so an installed `kimi` is
treated as ready and an unauthenticated run surfaces kimi's own message
in the transcript.

`SipAI-macOS/Verification/KimiCode/run.sh` re-checks every assumption
this support is built on against the `kimi` on your `PATH` — it spawns
two real turns in a temp folder and names the file to edit for anything
that fails. Run it after a kimi upgrade.

---

## Scheduled tasks

A scheduled task is a folder under `~/.claude/scheduled-tasks/<name>/`
whose `SKILL.md` holds everything: the prompt, the schedule, the working
directory, which agent runs it, and the permission mode / model / effort.

**Create one** from a new session's composer: fill in the prompt, switch
on **Run on a schedule**, and pick when it runs — every hour, every day,
every weekday, every week, every month, or a custom cron expression.
While the schedule is armed the send button turns into a calendar, with a
banner previewing exactly what will be created. The task then appears in
the sidebar alongside your sessions and expands inline to show its runs.

The agent is part of the definition, not a global setting: a task created
from a Codex session runs under Codex, one created from a Claude Code
session runs under Claude Code, and a Kimi task runs under Kimi. All
three live in the same place: `~/.claude/scheduled-tasks/` is the task
store for every agent.

**Inspect and edit one** by clicking it. A panel above the transcript
shows — collapsed — what the task is, when it next runs, and how the last
run went ("Paused", "Next run in 3 hours", "missed a run yesterday",
"last run failed"). Expanded, it lists every setting the next run will
use — schedule, folder, mode / model / effort, the full prompt — all
editable behind **Edit**. A saved edit applies to every upcoming run and
never to one already in flight. This is also where a schedule comes off
entirely: switching to *Only when I run it* leaves a task that lives on
the **Run now** button.

The panel's header carries **Run now**, which runs once and leaves the
schedule untouched. **Pause / Resume** sits in the expanded details;
renaming happens in the editor or from the sidebar row's ⋮ menu. A task
that has never run shows the panel as the whole page, with all three
controls in its header. In the sidebar, a task's row carries its state —
Active, Paused, No schedule — and when it last ran ("Never" until the
first). Deleting a task keeps its past runs; if the `SKILL.md` disappears
behind the app's back, the panel degrades to "Definition deleted — past
runs only".

**The app fires tasks itself**, in-process, through the same code path as
an interactive turn — so a run inherits the app's own file access and
appears in the sidebar as an ordinary live session.

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
> missed while SipAI was closed fires once on the next launch — so "be
> open at 9:00 sharp" becomes "open the app sometime that day", and a
> task due forty times while you were away fires once, not forty times.
> Catch-up reaches back 24 hours at most; an older miss is recorded as
> skipped and reported on the panel, and each task's editor can turn
> catch-up off entirely. Nor does a task fire for a slot that passed
> before SipAI first saw it: creating a 9:00 task at 14:00 doesn't start
> a run.

A task whose schedule is still sitting in your crontab is read into its
`SKILL.md` on first launch and the crontab entry removed, so one task can
never end up with two schedulers.

---

## Settings

Reached from the bottom of the sidebar.

| Pane | What's in it |
|---|---|
| **Chat models** | Every configured model, which one is the default, add / remove, and the provider each belongs to |
| **Prompt and Roles** | The general system prompt, plus named roles — reusable prompts you switch between per chat. One starter role (Code Reviewer) ships as a worked example; add your own with **Add Role** |
| **Files & Notes** | The dedicated folder the sidebar's local-files section browses, and which model writes notes |
| **Display** | Appearance (System / Light / Dark); four font-size tiers — Small, Default, Larger, Large text mode — that scale the sidebar and the chat/agent content together and widen line spacing as they grow; a toggle for the sidebar's logo and wordmark; the chatbox toggles (token count, note button, note prompt, chat-group chip, role chip); and spell-checking in the text boxes |
| **Labels** | Rename "You", "AI", and each agent's label as they appear above messages |
| **Language** | English and 中文 ship; switching asks for a restart, and warns that any agent turn in progress will be stopped |
| **Updates** | The running version, **Check Now**, a *Last checked* readout, and a toggle for the once-daily automatic check |
| **Help** | Ten expandable answers to the questions that come up most — getting a key, requests that fail, token usage and cost, provider plan limits, chats versus agent sessions, agent CLI setup, where data lives, prompts and roles, organising and exporting, and macOS folder permissions |

**Updates apply to distribution builds only.** The test is a Developer ID
signature on the running app, so a copy you built from source never
offers itself updates: your build is yours, and overwriting it with ours
would discard any changes you made. The pane says so plainly on such a
build, and the menu's **Check for Updates…** item is hidden. A released
copy asks `updates.sipai.dev` once a day whether a newer version exists,
and the Settings toggle turns that off. Nothing is downloaded until you
choose to install it, no usage data, account or system profile is ever
sent, and every update must carry a valid EdDSA signature before Sparkle
will install it. If an update is accepted while an agent turn is running,
the install waits for the turn to finish.

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
├── config.json          providers + API keys, models, image models,
│                        default model, note model, roles, display
│                        settings, labels, sidebar order, per-agent
│                        group state, theme, language, tagline
├── meta.json            chat-group folder-slug → name map
├── system_prompt.txt    your general system prompt
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
`$KIMI_CODE_HOME` (default `~/.kimi-code/`). SipAI reads and writes those
in place.

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
have a key on disk at all, choose **Use $ENV_VAR** during setup: only the
variable's *name* is stored, and the value is read at runtime.

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
├── THIRD-PARTY-LICENSES.md           Sparkle's licence, reproduced whole
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
├── Release/                          the release pipeline — see below
├── Verification/                     behaviour harnesses — see below
└── SipAI/
    ├── SipAIApp.swift                @main — wires the managers together
    ├── Models/
    │   ├── APIClient.swift               OpenAI / Responses / Anthropic transports
    │   ├── AgentEventParsing.swift       claude stream-json → StreamEvent
    │   ├── AgentLaunchOptions.swift      mode / model / effort + scraped catalogs
    │   ├── AgentManager.swift            CLI detection, session list, history cache
    │   ├── AgentRunner.swift             one agent subprocess (pty + read loop)
    │   ├── AgentSession.swift            session scanner + JSONL history reader
    │   ├── AgentSessionFork.swift        branching a session into a new transcript
    │   ├── AgentSessionGrouping.swift    folder / date / state / custom grouping
    │   ├── AgentSessionTailer.swift      follows externally-driven sessions
    │   ├── AppState.swift                routing + composer drafts
    │   ├── ChatManager.swift             chat load / save
    │   ├── CodexEventParsing.swift       `codex exec --json` → StreamEvent
    │   ├── CodexSessions.swift           Codex rollout scanner + reader
    │   ├── ConfigManager.swift           config.json round-trip
    │   ├── FactoryReset.swift            the wipe-and-start-over path
    │   ├── GlobalSearch.swift            the ⇧⌘F search-everything index
    │   ├── KimiEventParsing.swift        kimi stream-json → StreamEvent
    │   ├── KimiSessions.swift            Kimi wire-file scanner + reader
    │   ├── MCPBridge.swift               approval bridge (UDS + approver.py)
    │   ├── NotesManager.swift            notes, including in-place editing
    │   ├── NotificationCoordinator.swift  system notifications for approvals
    │   ├── ProjectManager.swift          chat groups
    │   ├── ProviderCatalog.swift         built-in providers + regions
    │   ├── ScheduledTaskCreator.swift    composer → SKILL.md
    │   ├── ScheduledTaskDefinition.swift the SKILL.md model + cron parsing
    │   ├── ScheduledTaskScheduler.swift  the in-app timer and due rule
    │   ├── SipaiPaths.swift              Application Support paths + slugify
    │   └── UpdateController.swift        Sparkle wiring + install timing
    ├── Utilities/
    │   ├── AgentRendering.swift          tool-input / result summarising
    │   ├── DesignSystem.swift            colours, spacing, font tiers
    │   ├── LatexSymbols.swift            LaTeX → Unicode
    │   ├── MarkdownRenderer.swift        block-level Markdown (memoised)
    │   ├── SearchMatching.swift          case- and accent-insensitive matching
    │   ├── ShellEnvironment.swift        login-shell env capture
    │   ├── TranscriptFollow.swift        the stay-at-the-bottom scroll rule
    │   └── UpdaterAvailability.swift     is this build allowed to self-update
    ├── Views/
    │   ├── ContentView.swift             onboarding-or-main, sidebar + centre pane
    │   ├── GlobalSearchPalette.swift     the ⇧⌘F overlay
    │   ├── OnboardingView.swift          first-run wizard
    │   ├── ModelSetupSheet.swift         Add Model window
    │   ├── Chat/                         chat, agent session, composers, find bar,
    │   │                                 scheduled-task panel + timing editor
    │   ├── Notes/                        note viewer + editor
    │   ├── Settings/                     settings sheet
    │   └── Sidebar/                      sections: chats, groups, agents, notes, files
    └── Resources/
        ├── Assets.xcassets               app icon + logo renditions
        ├── approver.py                   MCP approver spawned by Claude Code
        ├── Credits.rtf                   what About SipAI shows: the Sparkle
        │                                 acknowledgement
        ├── THIRD-PARTY-LICENSES.txt      the same licence text the repo root
        │                                 carries, bundled so it ships with
        │                                 the app
        └── Localizable.xcstrings         String Catalog (English + 中文)
```

`SipAI-macOS/Verification/` holds small harnesses — each with a
self-contained `run.sh` — that compile the real sources against stubs
and pin the behaviours with the worst regression history: the provider
catalog, note editing, session forking, the runner's stdout drain, Codex
context tokens, scheduled-run visibility, the Kimi Code assumptions,
transcript search and the renderer's link gate, a slash command's answer
surviving a reload, the composer's Enter key, the sidebar lockup's
alignment, factory reset, and an end-to-end Sparkle update. Run the
relevant one after touching the code it covers; run `KimiCode` and
`CodexContextTokens` after upgrading those CLIs, since they are what
detect a changed file format.

`SipAI-macOS/Release/release.sh` is the whole release: archive, export
under a Developer ID, notarize and staple, build the DMG, build the
Sparkle update archive, and generate the signed appcast into `docs/`.
`./release.sh --preflight` checks every prerequisite — certificate,
notarization credentials, the EdDSA signing key, version consistency
between the two build configurations, a dated CHANGELOG section — and
builds nothing, so a missing piece costs a second rather than a full
build. No credential is stored in the repository: the signing identity
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

**No model list during setup**
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
shell doesn't read, paste the key itself or launch from a terminal
(`open -a SipAI`).

**An agent turn produces nothing at all — no output, no error**
Agent CLIs read `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` and ignore the
macOS system proxy, and a blocked route makes them retry in silence
rather than fail. SipAI passes the proxy variables from your login shell
down to the agent, so the fix is usually to export them there. The
transcript says as much after a minute of silence.

**The agent section is empty even though I have sessions**
SipAI looks under `~/.claude/projects/*/<session-id>.jsonl`,
`~/.codex/sessions/`, and `$KIMI_CODE_HOME/sessions/` (default
`~/.kimi-code/sessions/`). If the CLI isn't on the app's `PATH`, sessions
still list but read-only — launch from a terminal so the app inherits
your full `PATH`, or symlink the binary into `/usr/local/bin/`.

**A Codex session says "read-only" but Codex is installed**
Being installed isn't enough — SipAI also checks `~/.codex/auth.json` for
usable credentials, so that a "New session" it offers doesn't fail on the
first send. Run `codex login` (or set an API key) in a terminal; the
section flips to interactive within a few seconds, no relaunch.

**Approval cards never appear**
`MCPBridge` writes `approver.py` into
`~/Library/Application Support/SipAI/mcp/` and Claude Code runs it with
Python 3. Without a reachable `python3`, Claude Code falls back to its own
terminal prompt and the app never sees the request.

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
Security → Files and Folders** to grant the copy you have now, or sign
your builds with a team identity (Xcode → Settings → Accounts, add an
Apple ID, then pick that team under **Signing & Capabilities** on the
SipAI target). If you clicked Deny by mistake, the agent will report that
it can't read anything in the folder — re-enable SipAI in that same pane
and send again.

**A scheduled task didn't run**
The app has to be open at the scheduled moment. A slot missed by less
than a day fires once when you reopen it — the task's editor can turn
that catch-up off — and an older miss is recorded as skipped. Check the
task's panel: it names the next run and how the last one went.

**Start completely fresh**
Delete `~/Library/Application Support/SipAI/`, or use Settings → Factory
reset, which also empties `~/.claude/scheduled-tasks` so nothing keeps
firing behind your back. Agent session stores under `~/.claude/projects`,
`~/.codex` and `~/.kimi-code` are never touched — remove those separately
for a full wipe.

---

## License

MIT — see [LICENSE](LICENSE). Use it, change it, ship it; keep the notice.

SipAI links and redistributes one third-party component:
**[Sparkle](https://github.com/sparkle-project/Sparkle)** 2.9.5, the
macOS update framework behind Settings → Updates, under its own MIT
licence. Its full text — including the external licences it carries for
bsdiff, sais-lite, the portable Ed25519 implementation and
SUSignatureVerifier — is in
[THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md), and ships inside
every copy of the app: **About SipAI** names it, and the whole text is at
`SipAI.app/Contents/Resources/THIRD-PARTY-LICENSES.txt`. Nothing else in
this repository is derived from third-party code, and no third-party
fonts, icons or artwork are bundled.

### Trademarks

SipAI is an independent project with no affiliation to, sponsorship by,
or endorsement from any AI provider. Claude and Claude Code are
trademarks of Anthropic; Codex and ChatGPT are trademarks of OpenAI;
Kimi and Kimi Code are trademarks of Moonshot AI; every other provider
and product named here belongs to its respective owner. Those names
appear only to say what SipAI interoperates with.

### How it was built

SipAI was written with help from AI coding assistants — Claude Code,
Codex and Kimi Code, the same three the app drives. It is a client for
the tools it was built with.

That changes nothing about who is responsible for it. One human author
directed the work, reviewed what went in, holds the copyright and
answers for the result. An assistant is a tool here, the way a compiler
or an editor is; none of them is credited as an author, in the commit
history or anywhere else.

---

Created by **Yizhan Huang (黄一展)**.
Copyright © 2026 Yizhan Huang.
