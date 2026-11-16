# Changelog

Notable changes to **SipAI for macOS**, newest first.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow [Semantic Versioning](https://semver.org/).

This file is the single source for release notes. For each release, the
release script extracts the matching section and uses it in three
places: the in-app update dialog (Sparkle renders it as HTML), the
GitHub release body, and — once that window exists — the "what's new"
panel shown after updating. Write each entry for the person reading it
inside the app, not for someone reading a diff.

## [1.0.5] — 2026-11-15

**Highlights.** Agents can now ask you things. Claude Code's questions,
plans and permissions, Codex's and Kimi Code's own approvals, plans and
questions, and an MCP server's forms and links all arrive as cards you
can answer from the keyboard, and the mode chip's **Default** now means
each tool's own default setting. Skills get a Settings page and a chip
under the message box. You can edit an earlier message in place, send a
message while a turn runs, run your own `!` commands, and fold
everything an agent did into one line per answer with Compact view.
Settings gains Usage, Privacy and Agent Skills, the View menu gains
Zoom, Codex gains its Ultrafast speed and gets its older sessions back,
and a turn that fails now says so — on a scheduled run too.

### Added

- **Questions on a card.** When Claude Code stops to ask you something
  in the middle of a turn — its multiple-choice questions, most often
  while planning — the question now appears at the end of the
  conversation as a card: each question with its options (one, or
  several where it says so), a field for an answer in your own words,
  and **Submit**, **Skip** or **Chat about this**. Several questions
  show one at a time. From the keyboard it works the way Claude Code's
  terminal does: ↑ and ↓ walk the options, ← and → turn the page, and
  Return takes what the keyboard is on. Like an approval, a question
  posts a notification when you are looking elsewhere and marks its
  session in the sidebar. Before, SipAI declined these questions and
  asked the agent to put them in its reply.
- **Non-stop**, a switch at the bottom of the mode menu. Off — the
  default — a question waits for your answer. On, the agent chooses what
  it judges best, says what it chose, and carries on to the end. It
  answers questions only: in a mode that asks before it acts, an
  approval card still waits for you. Nothing turns it on but you — a
  scheduled task runs Non-stop only when its own **Non-stop** box is
  ticked.
- **Codex and Kimi Code stop to ask, too.** On Codex (0.159.3 or newer),
  **Default** and the new **Plan** mode run through the front end
  Codex's own app uses, so Codex's requests arrive as cards in the words
  its terminal uses — "Would you like to run the following command?",
  with the whole command — answered with Codex's own answers. In Plan,
  Codex explores, asks you questions and ends with a plan; **Implement
  this plan?** then names the mode to carry it out in. On Kimi Code
  (2.1.1 or newer) the mode chip offers Kimi's own modes — **Default**,
  **Ask When Needed**, **Plan** and **Never Ask** — and a tool request,
  a finished plan or a question becomes a card with Kimi's own answers
  (**Approve once**, **Approve for this session**, **Reject**; a plan
  approval names the mode the session continues in). In Default and
  Kimi's asking modes Kimi answers its own slash commands (`/status`,
  `/usage`, `/help`, `/compact`) itself.
- **An MCP server's own questions.** A server you added to an agent can
  pause one of its tools to ask you for something — a short form, a yes
  or a no, or a link to open in your browser, to sign in somewhere for
  example. SipAI now shows it on a card named after the server: a form
  with one field per page (up to 8 fields, and 12 choices in each), a
  link shown whole exactly as it would open, or **Allow** and **Deny**.
  This works for Claude Code (2.1.288 or newer) and for Codex on Default
  and Plan, where Codex's own approval of an MCP tool arrives the same
  way: **Allow**, **Allow for this session**, **Always allow** or
  **Cancel**. Before, every such request was cancelled or declined
  without you seeing it.
- **Questions Codex asks without stopping.** With the models Codex marks
  for it, Codex can ask a question and keep working. The question
  arrives on a card that says so; your answer reaches Codex in the turn
  that asked and shows in the conversation as your reply. If the turn
  ends first, whatever you had started to answer moves into the message
  box under its question, ready to send — as Codex's own terminal does.
- **Skills.** **Settings → Agent Skills** lists each agent's skills
  under that agent — its own for every folder, the chosen folder's,
  those of the folders below it, its plugins' and its built-in ones —
  and each skill's **…** menu switches it **On**, **Only when I call
  it** or **Off**, pins it so new sessions start with it, edits it,
  shares it with another agent, or deletes it from that agent alone.
  **Share With** keeps one copy in SipAI's own library and links it into
  each agent's skills folder, so an edit reaches every agent that has
  it; because the three tools read a `SKILL.md` differently, it first
  fixes what the new agent would skip the skill over, or says what it
  can't fix and shares nothing. A skill an agent has but doesn't load is
  marked **Not loaded**, with the reason, and offers a fix where SipAI
  can make one. **New Skill** writes one; **Add…** brings one in from a
  folder or an archive. Under an agent session's message box, the new
  **skill chip** — a small robot — preloads the skills you tick: each
  loads once, with your next message, stays in the conversation, and is
  sent again after the conversation is summarised where the tool doesn't
  keep it by itself. A message that loaded skills names them under your
  text. A scheduled task can list skills for every run to load.
- **Edit an earlier message in place.** The pencil on a message you sent
  now offers **Send** beside **Create Branch**. Send goes back to that
  message in the same session — the message and everything after it
  leave the conversation and your edit takes their place — the way each
  tool's own terminal does it (Claude Code's rewind, Codex's revert,
  Kimi Code's undo). In a chat, Send replaces the message and the
  replies after it. A session rewound in the tool's own terminal is read
  the same way now: SipAI shows the conversation the agent continues
  from. Like a branch, this rewinds the conversation, not the files the
  agent already wrote.
- **Send while a turn runs.** A message you send while an agent works
  now waits above the message box and goes when the turn ends.
  **Steer**, beside it, hands it to the running turn instead — the agent
  reads it at its next step (Claude Code 2.1.310 or newer, and Codex;
  Kimi Code takes none mid-turn). × puts a waiting message back in the
  box, with its files, so you can change it; after Stop nothing is sent
  by itself.
- **Background tasks are waited for, and named.** When an agent starts a
  long command in the background and answers before it finishes, the
  turn now stays open until the task ends and the agent has reported on
  it. A line under the answer names what the agent is waiting for, a
  short notice says when a task finished or was stopped — the same after
  a reopen — and with Claude Code 2.1.310 or newer, or Codex, each task
  has a Stop of its own. Claude Code's background tasks, switched off
  since 1.0.2, are back on wherever the installed Claude Code (2.1.309
  or newer) waits for them itself.
- **`!` commands.** A line that starts with `!` in a Claude Code
  (2.1.310 or newer) or Codex (0.165.0 or newer) session is your own
  shell command, run the way that tool's terminal runs one — directly,
  with no model, no approval and no sandbox — and its output joins the
  conversation. In a Claude Code session it runs in your own shell, with
  your aliases, in the folder the last one ended in. This is also how
  each tool's cloud commands work here, as in its own terminal (`!codex
  cloud list`, for example). Kimi Code offers apps no way to run one, so
  a Kimi session sends the line as an ordinary message, and the composer
  says so before you send.
- **Codex's `/compact` and `/review`** run as they do in Codex's own
  terminal. `/review` opens Codex's review picker: a base branch,
  uncommitted changes, a commit, or your own instructions.
- **Compact view, for reading the answers rather than the work.** A new
  icon in the toolbar, beside the magnifier, opens its switch (also in
  Settings → Display, and View → Agent Session Compact View, ⌃⌘O). With
  it on, each of the agent's answers is one line with its final message
  under it. The line holds everything between your message and that
  final message — thinking, tool calls, messages written along the way,
  answered questions, a reviewed plan, a background task reporting back
  — and shows the newest of them while the agent works, then a summary
  of what it did; a click opens it into its steps. A card still appears
  while it waits for you. Only the drawing changes.
- **View → Zoom In, Zoom Out and Actual Size** (⌘+, ⌘−, ⌘0) step through
  the four text sizes from anywhere. Settings → Display → **Zoom** — the
  setting that was Font Size — shows the same choice. A conversation, a
  chat or a note's preview keeps the line you were reading in place when
  the size changes.
- **Settings → Usage.** What each agent's plan reports, with more room
  than the toolbar's plan-usage window, whose new **Learn more** opens
  it: Claude Code's own account of what is using your limits, as a
  table; Codex's credits, workspace spend cap, limit resets, its
  lifetime figures and a year of token activity, a square a day; Kimi
  Code's limits and Extra Usage; and a link to each tool's own usage
  page. A free Codex limit reset can be used there, after Codex's own
  confirmation. An agent on an API key gets a line saying where it is
  billed. No tokens are spent.
- **Settings → Privacy** says in three short paragraphs what SipAI keeps
  and sends: it collects no data, what you send to a model goes straight
  to that provider, and apart from your providers it goes online only
  for the update checks, which you can turn off.
- **Codex's Ultrafast speed.** The model menu has a switch for each of
  Codex's speeds — **Fast mode**, and **Ultrafast** where Codex offers
  it to your account — each described in Codex's own words, and greyed
  out on a model without it or where your Codex config or your
  organization turns it off. Scheduled Codex tasks get the same boxes.
  When Codex can't use the picked speed for a message, the bolt on the
  chip is struck through and the switch says why.
- **Attached files show as chips in agent sessions.** **+** and a drop
  on the box now put a chip above the text, as on the chat page, in
  every mode — instead of typing the file's path into your message — and
  the sent message names each file with a paperclip. Outside Chat only
  the file stays where it is, and the agent opens it itself.
- **Links to files in a reply.** A reply's link to a file on your Mac —
  Codex writes one for every file it mentions — used to show only its
  words. It now shows the file's path after them; a click opens a
  document in its usual app, and opens a folder in Finder. A file that
  isn't there is greyed out.
- **Notices beside the logo.** The SipAI name at the top of the sidebar
  gives way to a sky-blue bubble when something is worth saying: a
  session waiting for you (ten seconds), a finished or failed run, or a
  chat's reply (five), a tool that was just updated. Click one to open
  what it names. An update on offer — SipAI's or a tool's — stands there
  with an update button and a × until you use one of them, and a SipAI
  update held for a running turn shows **Install Now**. Settings →
  Display → **Show notifications beside the logo** turns them all off.
- **More in the sidebar's menus.** **Notes**, **Chats** and **Chat
  groups** have a … menu whose **Hide** takes the section off the
  sidebar; Settings → Display → **Show sections** brings it back, in its
  place. A folder or custom group's header has a … menu — **Mark all as
  read**, **Delete all sessions** for a folder, and **Rename**,
  **Ungroup** and **Delete the group** for a custom group, each asking
  first — **Ungrouped** has a **+** of its own, and a scheduled task's
  menu has **Mark all as read** for its runs.
- **A new session waits under its +.** A new session you haven't sent
  yet — its message, files, schedule, skills and the chips you changed —
  is kept under the **+** you started it from, so each group's **+**,
  and **+ New session**, has its own. A group's **+** starts on the
  mode, model, effort and speed of that group's newest session.
- **Scheduled tasks: mode, Non-stop, Chat only and skills.** A task's
  **Runs as** row now offers the composer's own Model, Effort and Mode
  menus — each tool's asking modes and Chat only included — with
  **Non-stop** and the speed boxes under them, and a run does exactly
  what its task says. A task created from the composer keeps the
  composer's mode as it stands.
- **Kimi Code plans.** The Agent Initialization card and the usage card
  name your membership as Kimi does. Signing in with a Moonshot platform
  key now asks which model to start on, from Kimi's own list. And when
  Moonshot refuses a model for your plan, its row in the model menu says
  "Your plan doesn't include this model" from then on, for that account
  — still pickable, since plans change. (That note is read off Kimi
  Code's own record of the turn; Kimi Code 2.6.1 no longer keeps the
  model there, so no note appears with it yet.)
- **Delete for a tool that isn't signed in.** Settings → Agent
  Initialization offers **Delete** on an installed tool whether it is
  signed in or not.
- **Edit and Copy for VoiceOver.** A message you sent offers **Edit this
  message** and **Copy this message** among its actions.
- **Settings → Help** gained eleven answers: Compact view, background
  tasks, sending while the agent works, which of Codex's own commands
  work here, how cloud sessions work, an MCP server asking for your
  input, why Codex sometimes asks a question as plain text, Claude
  Code's "Prompt is too long", sharing a skill, the skill chip, and
  hiding a sidebar section or clearing a whole group.

### Changed

- **Default means the tool's own default.** The mode chip's **Default**
  is now each tool's own default setting — Claude Code's from its
  settings, Codex's own default for the folder, the default mode in Kimi
  Code's config. A Codex session on Default therefore stops for approval
  where Codex's own app would, and a model, effort or speed left on
  Default means what the tool itself would run in that folder.
- **Kimi Code's Auto-approve is now Never Ask**, Kimi's own name for it.
  It remains what a Kimi task with no mode in its file runs as.
- **The approval card is answered from the keyboard the way Claude
  Code's terminal is.** The filled button is the one Return presses, the
  arrow keys move it, and Escape denies — only for the newest card, and
  only while nothing is being typed, so a Return meant for a message can
  never approve a command.
- **Allow Always remembers Claude Code's own rule.** It now hands back
  the rule Claude Code itself suggests for the call — the exact command,
  a family such as `git commit *`, a folder to work in, or "accept every
  edit" — shown on a line under the command, where it used to remember
  that one exact call. A rule for the folder holds for every later
  session there.
- **The plan card offers what Claude Code's terminal offers, in its
  words** — **Yes, and use auto mode**, **Yes, auto-accept edits**,
  **Yes, manually approve edits**, **No, keep planning** — with a line
  for what to change: type it and Claude Code revises the plan in the
  same turn.
- **The turn clock holds still while a card waits for you** — a
  permission, a plan, a question — and the time a turn took counts only
  its working time. A card now waits about a day for you, where Claude
  Code used to give up on one after 30 minutes.
- **Codex's Read Only, Workspace Write and Full Access** run through
  Codex's own front end too (Codex 0.159.3 or newer): any message can
  change the speed, a command left running in the background keeps the
  turn open, and Stop is Codex's own interrupt. Chat only still runs as
  before and keeps the speed the session started at; its switches say
  so.
- **Settings, regrouped.** Chat models and Chat Prompt and Roles are one
  section, **Chat Settings**. Agent Guide is now **Agent
  Initialization**. What SipAI does with your data is said once, in
  Privacy, instead of in several places.
- **Chat only.** A Chat only answer draws as one line with its final
  message under it, whether Compact view is on or off, and a scheduled
  task can run Chat only.
- **Grouped by Custom, the section's first row is + New group**, and a
  session starts from its group's **+**. A group header's … menu
  replaces its right-click menu.
- **One Show earlier, always at the top**, however long a turn runs —
  and the page holds still while you scroll up to read during a
  streaming turn.
- **Tool rows say what ran, for Codex and Kimi Code.** A Codex edit row
  shows each file with its diff; a reopened Codex session shows the
  commands and edits Codex recorded instead of its internal scripts; a
  Kimi Code read, edit or write row names its file, and a failed Kimi
  tool is marked while the turn runs.
- **Chats with Claude models stream**, and a reply is capped at the
  model's own published maximum rather than a fixed 16,384 tokens.
  Requests to Anthropic now carry its API version `2026-10-21`.
- **Kimi Code key sign-in offers the Moonshot platform key only.** A key
  from the Kimi Code Console belongs to the membership, so the sheet
  points its owner to the membership sign-in, as Kimi Code's own login
  does.
- **The first-launch welcome page** uses the system's own text sizes,
  symbols and button, in a window sized to the screen.
- **Links show the pointing hand**, link buttons and links inside text
  alike.
- **Bundled components.** Sparkle moves to 2.9.6 (see Security). SipAI
  now includes the decoder of Zstandard 1.5.7, under its BSD licence, to
  read Codex's compressed sessions; About SipAI and the licence file
  name it.

### Fixed

- **Chats with current Claude models failed whenever the model thought
  first** ("Decode error: Anthropic: missing content[0].text"), and so
  did notes written with them. A reply is now read by its text, wherever
  the thinking sits.
- **A turn that fails now ends as failed, on all three agents.** An API
  error, a refused connection or a limit used to end a turn looking
  finished, and a scheduled run was recorded as done under its own
  error. The task's page now says the run failed, in the tool's words.
  While Claude Code or Codex retries a dropped connection, one row under
  "Sipping…" shows the attempt (Kimi Code's too, up to Kimi Code 2.5),
  and a Kimi Code turn that fails with no internet no longer ends with
  nothing on screen.
- **"Prompt is too long" near the end of a long Claude Code session.**
  When a project file such as CLAUDE.md had changed since your last
  message, Claude Code could refuse the next message instead of making
  room first. SipAI now sends it once more, and Claude Code compacts the
  conversation and answers.
- **Coming back to a session while its turn runs** showed the page
  starting at the new question, with every earlier turn missing.
- **Long Claude Code sessions reopened with almost none of their
  history**, and with the mode chip on Default, once Claude Code
  (2.1.300 or newer) began recording each request in the session file.
- **Codex sessions older than about a week had left the sidebar.** Codex
  now stores a session left alone for a while compressed; SipAI reads
  those — in the list, in search, as a task's runs and as a branch's
  history.
- **Codex 0.164 and newer kept a session's first speed**, whatever the
  Fast mode switch said afterwards, and a branch took the speed in your
  Codex config instead of its parent's. Each message's speed is its own
  again (Chat only excepted, and it says so), and a branch keeps its
  parent's.
- **The Kimi Code usage card was empty** on Kimi Code 2.x, whose usage
  answer changed shape. It shows the 5-hour and monthly limits (a weekly
  one on older plans) and Extra Usage.
- **Kimi Code 2.6.1: a new session's first Chat only message failed.**
- **A Kimi Code session open elsewhere.** While Kimi Code's own
  terminal, desktop app or an editor has a session open (Kimi Code 2.3
  or newer), a message sent from SipAI is no longer started beside it;
  the conversation says which Kimi has the session.
- **Kimi Code's local server could hang for good when it was stopped**,
  after which signing in, reading usage and a new session's first Chat
  only message all answered "busy" until SipAI was relaunched.
- **A tool that an update left unable to start** was announced as
  updated — with a version that was not its own — and its usage card
  said only that the tool did not answer. Its row in Settings → Updates
  now says **Can’t start**, and **Details** shows what the tool printed,
  which usually says how to fix it.
- **A tool SipAI was updating could vanish from the sidebar** when a
  slow download ran past fifteen minutes. SipAI now waits for an update
  that has already taken the old version away, however long it takes.
  And when Claude Code stops its own update download at its 10-minute
  limit, the failed update says so.
- **The composer's chips could be saved as your pick when you never
  picked them** — for the session and as the starting choice for new
  ones — when two of SipAI's own updates of the chips landed together.
- **Editing a session's first message** started a new session that then
  fell back to the agent's latest mode, model and effort; it keeps the
  session's own.
- **Kimi Code: Create Branch below a first message of attached files
  alone** started a new session instead of a branch, and **a Chat only
  turn sent as files alone** lost its one-line look once the session was
  reopened.
- **A sidebar section that isn't shown for now** — an agent signed out
  or hidden — keeps its place when you drag the others.
- **Two agents' custom groups with the same name**: deleting, ungrouping
  or renaming one no longer reaches the other's.
- **The … button on a row** fills under the pointer and opens its menu
  wherever you click in its box; it used to answer only on the dots
  themselves.
- **The pencil and copy buttons on a message you sent could vanish**
  while macOS reported the pointer hidden — for hours at a time on a Mac
  used over Screen Sharing.
- **Settings → Display → Appearance: choosing System after Light or
  Dark** did nothing until you clicked elsewhere. Light and Dark also
  reach every window now — alerts, file panels, menus and the update
  window, not only the main one.
- **The error row's text** was drawn smaller than its icon.
- **A link to a file whose path holds a parenthesis** no longer garbles
  its line.

### Security

- **Requests to a chat provider are no longer kept in macOS's web
  cache.** macOS could keep a copy of a request — your API key in its
  header, a chat's messages in its body — in the cache it holds for
  every app, where deleting the chat, a factory reset or a key given as
  an environment variable never reached. Provider requests now bypass
  that cache, SipAI deletes the cache each time it starts, and Factory
  reset empties it.
- **Sparkle 2.9.6.** The update framework moves to its security release,
  which hardens how the installer handles a downloaded update.
- **A link to a file never runs anything.** A click opens documents
  only; an app, a script, an installer or a disk image is shown in
  Finder instead.
- **An MCP server's link is opened only when it is an `https` address
  SipAI can show exactly as it will open**; any other is shown with
  Decline alone.
- **A skill archive is checked before it is used**: one that holds a
  link pointing outside itself, or that unpacks past its size limit, is
  refused. Add skills only from sources you trust — a skill can include
  scripts an agent may run.
- **Usage and billing pages** open only on each tool's own site, over
  `https`.

## [1.0.4] — 2026-09-28

**Highlights.** Chat only talks to the model you're subscribed to inside
an agent session, without the agent's file and command tools. Settings →
Agent Guide installs, signs in, hides or removes Claude Code, Codex and
Kimi Code from inside the app; Settings opens in the main window, and
Font Size now reaches all of it. The toolbar shows how much of your plan
is used, a blue dot marks a finished run you haven't opened, Codex and
Kimi Code turns run in a terminal show live in a session you have open,
and their sessions can be branched. Scheduled tasks can run once, carry a
speed of their own, and can be deleted with their runs. Every code block
gets Copy and Save, and agent tools can keep themselves up to date.

### Added

- **Chat only — talk to the model you're subscribed to, in an agent
  session, without the agent.** A new row in the composer's mode chip,
  right under Default (on Kimi Code, under Auto-approve), on all three
  agents. A message sent under it carries none of the agent's file or
  command tools and no MCP servers — except any you added to Codex's own
  config — so the agent can't read, search or change files or run
  commands; but, like any chat app, it can still look things up on the
  web when a question needs current information (Kimi Code searches
  when it has a search provider, which a Kimi Code membership login
  gives it; with an API key alone it can open a page but not search). It
  answers in the same session, and your next message in any other row
  picks the conversation up with the tools back — discuss a plan, then
  switch the chip and ask for it to be built in the same window. It is
  far cheaper than an agent turn (a one-word exchange measured at 2,576
  context tokens on Claude Code against 23,055 in Default, and on Codex
  at 8,067 for a new chat's first message and 3,787 once it continues,
  against 13,985 for a Default first turn — much of each the web tools'
  own definitions), and it draws on whatever the tool is signed in to:
  your Claude plan, your Codex limits, your Kimi Code membership, or an
  API key, billed per token — the chip's hover says which. While it is
  on, **+** and a drop on the box attach a file instead of inserting its
  path (text files and PDF text ride inside the message, an image goes
  to the model as an image — on Kimi Code, only in a new session's first
  message — and each file is named at the top of your message), and the
  box reads *Chat with …*. While the model works, its thinking and its
  web lookups appear as one line under your message, the way a chat app
  shows them: "Sipping…" becomes the newest step as it happens
  (*Searching the web for “…”*, *Reading python.org*, or the model's
  own thought), and once the answer starts the line settles into a
  summary such as *Thought · Searched the web · Read 1 page*. Click it
  to see every thought and lookup; a reopened session shows it the same
  way. Turns in any other mode list their steps as before. A new Kimi
  Code session started in Chat only shows its first reply all at once;
  later ones stream. The row appears only where the installed tool is
  recent enough to honour it; scheduled tasks never run it. Settings →
  Help has the question.

- **Settings → Agent Guide: install, sign in, hide or delete each agent
  from inside the app.** One card per agent — Claude Code, Codex, Kimi
  Code — with its installed version, whether it is signed in and as
  what, and the one thing it needs next. **Install** runs the vendor's
  own installer (for Codex, OpenAI's release package, checked against
  OpenAI's checksum file, with every program in it checked for OpenAI's
  own Developer ID signature before any of it runs); no Homebrew, npm or
  node is needed.
  **Sign In** asks whether to use your subscription or pay-per-use
  billing (an Anthropic Console sign-in for Claude Code, an API key for
  Codex and Kimi Code), tells you which website is about to open, and
  lets the tool keep its own login exactly as a Terminal sign-in would —
  your password goes only to the provider's page, a key you paste is
  handed straight to the tool, and SipAI keeps no copy of either. Kimi
  Code runs two separate services — kimi.com
  in mainland China and kimi.ai everywhere else — so for Kimi Code the
  first question is which one your account or key is from, already set
  to the one Kimi Code itself would use; once signed in, the card says
  which (for example "Membership (kimi.ai)" or "API key
  (platform.moonshot.cn)"). **Delete** removes the tool the way uninstalling
  it in Terminal does and says so first; sessions and the sign-in stay.
  A checkbox hides an agent everywhere — sidebar, search, usage,
  updates, and its scheduled tasks stop firing — without removing it.
  Updating a tool stays where it was, under Settings → Updates.
- **An ADD AGENTS row in the sidebar** whenever a supported agent is not
  yet installed or signed in (ADD MORE AGENTS once some are), opening
  the Agent Guide.
- **A folded group or a collapsed section shows when something inside
  it is running.** The pulsing dot a running session — or a chat
  waiting on its reply — shows now also sits right after the name of a
  folded group (agent session groups and chat groups alike) and of a
  collapsed section (Claude Code, Codex, Kimi Code, Chats, Chat groups):
  after the "…" if the name is too long for the sidebar, and never over
  the row count or the section's menu. Unfold it and the dot is back on
  the row itself.
- **A steady dot marks a finished run you have not opened yet.** When a
  session's run ends — one you sent, a scheduled one, or one run in a
  terminal — the pulsing orange dot becomes a steady blue dot in the
  same place (on the row, and after the name of a folded group or a
  collapsed section) and stays until you open that session. A folded
  group or collapsed section holding both a running session and an
  unopened one shows both dots, the pulsing one first. A session
  you are looking at when it finishes gets none, and neither does a run
  you stopped yourself. Chats work the same way: a reply that arrives
  while you are elsewhere leaves the dot on its chat. The dots survive
  quitting SipAI; a scheduled task's runs are read one by one, as you
  open each; and grouping by State has an **Unread** group.
- **A Codex or Kimi Code turn run in a terminal now shows in SipAI, as a
  Claude Code one does.** For a session you have opened in SipAI since
  starting it, a turn started from a terminal or another app pulses in
  the sidebar, appears in the open conversation as it happens, keeps
  Send waiting until it ends, and leaves the steady dot when it is done.
  A turn whose process is killed is usually noticed within seconds.
- **The chat page explains itself while no model is configured**, and
  Settings → Chat models opens with a short account of what a chat is —
  a message sent straight to a provider's API on your own key, billed
  per token — and where to go instead if you would rather use a
  subscription. Both link to the next step.

- **See how much of your plan is used, from the toolbar.** A T icon
  beside the search icon opens a small window with what each of your
  agent plans reports: the current 5-hour session and weekly windows
  for a Claude subscription (and, once usage credits have ever been
  switched on, the month's spend against their limit while they are on,
  or why they are off — usage credits are separate from the plan's
  limits), the weekly and per-model limits and any free limit resets for
  a ChatGPT plan under Codex, and the weekly quota and 5-hour window for
  a Kimi Code membership — each with a bar, how much is used and when it
  resets. The figures are fetched the moment you
  open the window, by each tool itself with its own login (no tokens
  spent, and SipAI never sees a login token); the line at the bottom
  says how old they are, and the arrow beside it asks again. The icon
  appears only when at least one agent tool is signed in to a plan.
  Tools running on an API key are not listed — no tool reports an
  account figure for one — and the window points at your provider's
  developer platform for those. The Help question about plan usage now
  explains all of this instead of answering "Not yet."
- **Branch a Codex or Kimi Code session from an earlier message.** The
  pencil on your own messages — edit the text, **Create Branch**, and a
  new session starts from that point with the original untouched — used
  to appear in Claude Code sessions only. It now appears in Codex and
  Kimi Code sessions too, and works the way each of those tools forks
  its own sessions: a Codex branch is made by Codex itself — an
  ordinary Codex session — and a Kimi branch is a session in the format
  `kimi fork` writes. One thing to know about Codex: it records a fork
  as a reference to the original rather than a copy, so deleting the
  original session leaves its branches with only the turns made after
  the fork — in Codex as much as here.
- **A Codex session forked in the terminal now shows its whole
  history.** A `codex fork` used to open in SipAI as an empty
  transcript, because the forked session's file holds no copy of what
  came before it. SipAI now follows the reference the way Codex does.
- **Why Codex says 258k, and a switch to the larger window.** A Codex
  session's context chip divides by the window Codex enforces — 258,400
  tokens by default on models OpenAI advertises at 1.05M — and nothing
  said why. The chip's hover now carries a **?** that opens a new
  question in Settings → Help: what Codex's default and maximum
  actually are, that Codex's own interface has no switch for it, and
  that the setting is one line in `~/.codex/config.toml`. The card lists
  which of your installed models allow a larger window and how large,
  straight from Codex's own catalog, and two buttons — **Use the
  maximum** and **Back to default** — make the change through Codex
  itself rather than by editing its file. The chip updates at once; the
  next turn of every Codex session runs with the new window.

- **A scheduled task can run just once.** The schedule's options now
  include **Once**: pick a day — Today, Tomorrow, or any date on the
  calendar — and a time, and the task runs one time at that moment. A
  day or time that has already passed can't be picked, and one that
  passes while the form is open is refused with a message rather than
  saved. If SipAI is closed at the moment, the run is made up when it
  next opens, within the same 24 hours as any missed run. Afterwards
  the task's row reads *Finished* — or *Missed*, if SipAI stayed closed
  longer than that — and the task keeps its prompt and settings, ready
  for a new time.

- **A scheduled task has a speed of its own.** The task editor, under
  *Runs as*, now has a **Fast mode** checkbox for Claude Code and Codex
  tasks, the same switch as the composer's: on the models that have it,
  saying what it costs and whether it can run. A Codex task you never
  set runs as it always has — at the speed in your Codex config, which
  Codex applies to an unattended run, and not at a speed a model merely
  starts on in Codex's own window — and the checkbox shows which. A task
  created from the composer takes the composer's speed along with its
  model and effort, as the composer's switch showed it, and the task's
  summary line names a faster speed when one is set.

- **Agent tools can keep themselves up to date.** Settings → Updates
  has a new switch, *Update these tools automatically*, off until you
  turn it on. With it on, SipAI runs a tool's own update as soon as it
  finds a newer version, after any running turn of that tool has
  finished. SipAI itself still updates only when you say so.
- **"Just updated" beside the logo.** Whenever an agent tool is
  updated — by its Update button, automatically, by the tool itself,
  or with `claude update` in Terminal while SipAI is open — the SipAI
  name at the top of the sidebar gives way for five seconds to a line
  such as "Claude Code just updated to …" — as it lands, or, if SipAI
  is behind another app or a sheet lies over the logo, as soon as the
  logo can be seen. From the next update on, SipAI's own updates say
  the same after relaunching. Updates that land together take turns.
  Settings → Display → *Show update messages* turns the lines off.
- **A message sent while SipAI is updating its tool waits for it.** It
  appears in the conversation straight away, a line under it says the
  tool is updating and the message will be sent when the update
  finishes, and it goes out on its own the moment the update is done.
- **Copy and Save on every code block in a conversation.** Point at a
  code block — in a chat, or in a Claude Code, Codex or Kimi Code
  session — and two buttons appear in its lower-right corner. **Copy** puts the code on
  the clipboard, without the final line break, so a pasted command
  doesn't run by itself in Terminal. **Save** opens a Save dialog where
  you choose the folder and the name; it suggests the conversation's
  name with the extension for the block's language (`.py` for Python,
  `.md` for Markdown, `.txt` for plain text or a language it doesn't
  know). The buttons light up when pointed at, and so do the Copy and
  branch buttons on your own messages; when your message ends in a
  code block, the block's buttons take that corner while the pointer is
  over the block.
- **Copy session ID.** An agent session's ⋮ menu (and its right-click
  menu) has **Copy session ID**: it copies the tool's own id for that
  session — the one `claude --resume`, `codex resume` and
  `kimi --session` take — as plain text. Paste it into an agent
  session's message box and it shows on the grey a sidebar row takes
  under the pointer, so it stands out from the words around it; the
  message is sent exactly as typed.
- **A scheduled task can be deleted together with its runs.** Its ⋮ menu
  now offers **Delete definition** — what Delete did before: the task
  stops and its definition goes, its past runs stay — and **Delete
  all**, which removes the definition and every run the task made, so
  the task leaves the sidebar entirely. Each asks first and says what
  will go; a run still going is stopped before it is deleted.

### Changed

- **First launch is one page.** Get started now lands in the main
  window; the step-by-step wizard (provider, key, model, more models)
  is gone, and everything it did is reachable from Add Model or
  Settings. The wizard's image-models page went with it — nothing in
  the app generated an image.
- **The sidebar lists an agent only while it is installed and signed
  in.** The read-only tier is gone: an agent that is signed out, not
  installed or hidden shows nothing — no section, no search results,
  no usage figures — and its sessions stay in the tool's own store
  until it is listed again. Signing in, installing or unhiding it is
  one click away in Settings → Agent Guide.
- **Codex is judged signed in by what its own auth file says**, the same
  read the plan-usage icon makes, rather than by whether a saved key is
  at least 40 characters long.
- **The group you are working in moves to the top.** Custom groups are
  now listed most recently used first, the way folders already were, so
  the group a session was just started or sent to sits right under the
  agent's name. Dragging group headers into your own order still works:
  that order holds until a turn starts in some group, and then that
  group moves to the top (an order you dragged before this version is
  shown most recently used first until you drag again). In Folder mode
  a dragged order used to freeze the list for good — the folder a new
  session ran in stayed where it was, and a folder used for the first
  time appeared at the very bottom. Long group names now shorten at the
  end ("…"), like every other name in the sidebar.
- **Running sessions come first, then finished ones you have not
  opened, then the rest** — inside every group, in every way of
  grouping, and for the groups themselves when grouping by Folder or
  Custom, even over an order you dragged. Sessions used to be ordered
  only by when you last sent a message, so a session started earlier that
  was still running sat below one started later that had already
  finished. A session you open keeps its place until you open something
  else, so the row never moves out from under the pointer, and a row
  with a dot is never hidden behind "Show all". Chats follow the same
  order.

- **Codex's Fast mode switch now works the way Codex's own app does.**
  A Codex session's model menu has one **Fast mode** switch, described
  in Codex's own words for the selected model ("2x speed, increased
  usage" on GPT-6-Astra, "1.5x speed" on GPT-6-Sol). On runs the model's
  Fast speed; off runs standard speed — even where your Codex config
  turns a faster speed on by itself. Until you flip it, it follows what
  Codex itself would run in that folder — the speed in your Codex
  config, else the one the model starts on in Codex — and says "On by
  default in Codex" when that is Fast. So a session on a model that
  starts on Fast in Codex, such as GPT-6-Sol, now runs Fast here too,
  using more of your Codex limits, until you switch it off. A bolt on
  the model chip shows when it is on. The old switch could not turn off
  a speed your Codex settings had turned on, and did not know a model's
  own default.

- **Settings opens in the main window.** Click Settings at the bottom of
  the sidebar and a menu of its sections rises from it, as wide as the
  sidebar; pick one and the sidebar lists every section under the logo
  while the section you chose fills the window beside it, in a centred
  column that keeps a comfortable width as you resize the window.
  Moving between sections is one click in the sidebar, and **Back to
  app** — where Settings was — returns to whatever you had open.
  Factory reset sits at the end of the sidebar's list, set apart from
  the sections. A section's first line sits as far below the top of the
  window as a session's first message, and a long section ends as far
  above the bottom. Prompt and Roles is now **Chat Prompt and Roles** —
  its prompt and roles have only ever applied to chats — and its System
  Prompt box is a fixed size of about ten lines. The explanations in
  Updates now run the full width of the page rather than stopping at a
  narrower margin of their own.
- **Font Size now reaches the whole window.** Settings → Display → Font
  Size used to resize the sidebar and the conversation and nothing else:
  the box you type in, the chips under it, the menus they open, notes
  and Settings itself stayed at one size. All of them now follow the
  tier, and the text box and Settings → Help take the conversation's
  line spacing too — Help's answers kept a tight, fixed spacing at every
  size. Default is exactly the size it was; only the other three tiers
  move.
- **The "No output yet" note in an agent session waits five minutes and
  says what to check.** A turn that has shown nothing for five minutes
  (it was three) gets the note, and the note now ends with the two
  things worth looking at: your network connection and settings, and
  whether the AI provider is down.

- **Choosing when a task runs is all clickable chips.** How often, the
  weekday, the day of the month and the time are chips, like the
  composer's own; the time opens a grid of hours and minutes, and a
  one-time run's date opens a month calendar. The option that read
  "Custom cron" is now "Custom (cron)", last in the row: it takes a
  hand-written cron expression, and was never a one-time run.
- **A task you have just scheduled sits at the top of its group** in
  the sidebar, the way a session you have just sent a message to does,
  instead of at the bottom until its first run — and its group moves
  up with it.
- **A scheduled task's row has one icon instead of two, and a click on
  it opens the task's page or folds the task away.** The arrow beside a
  task's clock is gone: the clock now sits between two short bars that
  show whether the task is open — above and below it while it is folded,
  either side of it while its runs are showing. A click on a folded task
  shows its runs and opens the task's page — its schedule and settings,
  ready to edit, with Pause and Run now at the top — which used to be
  there only until the task's first run. A click on an open task hides
  its runs and does nothing else: whatever is on screen stays. While a
  task's page is open, a run its schedule starts appears under the task
  and leaves the page where it is; Run now pressed on the page opens the
  run it starts. The row no longer opens the task's newest run, which is
  opened by clicking it like any other run. The runs underneath sit one
  step less indented to match. What the runs are doing now shows after
  the task's name — the pulsing dot, the steady blue dot, or both at
  once — rather than in place of its icon.
- **The pencil that renames a scheduled task sits beside its name.** On
  a task's page it used to sit in the top right corner, beside Pause
  and Run now, where it read as an edit button for the whole page; it
  only ever renamed the task.
- **A scheduled task's page no longer has a Name box.** The pencil
  beside the task's name renames it, so the box under the title that
  changed the same name a second way is gone, and the page's settings
  start with the schedule.
- **Run now steps aside while a scheduled task has unsaved changes.** It
  always runs the saved task, so pressed with an edit still unsaved it
  ran the old version. The button is hidden while the settings in front
  of you have unsaved changes, and comes back once you save or revert
  them.
- **The sidebar's logo and name are always shown.** Settings → Display
  no longer offers *Show logo and app name*: the top of the sidebar is
  where a "just updated" line appears, so it stays.
- **A new version is shown by a small icon, not a banner.** The notice
  that sat in the window's top-right corner until you closed it is
  gone. When SipAI or one of its agent tools has a newer version, a
  blue download icon appears beside **Settings** in the sidebar and
  beside **Updates** inside Settings; it goes away once you open
  Updates, and comes back for a newer release — or while a SipAI update
  waits for a running turn, or when a tool's automatic update fails.
  Settings → Updates
  now also names SipAI's own new version, with a button that shows its
  release notes and installs it.
- **A copy built from source shows the same Updates page as a released
  copy.** The automatic-check checkbox, Check Now and the app menu's
  Check for Updates… are there, greyed out, and hovering over any of
  them says why: such a copy is not signed for distribution and does
  not update itself. Copies from the release page are unchanged.
- **A scheduled run missed while SipAI was closed starts about fifteen
  seconds after launch**, rather than the moment the window appears, so
  a copy opened only briefly cannot spend a task's slot on a run it
  never gets to finish. A wake from sleep still runs a missed slot at
  once.

### Fixed

- **Permission requests appear in a new session's first reply (Claude
  Code).** When the first message of a new agent session needed your
  approval — to edit a file, to run a command, or to accept a plan in
  Plan mode — no request appeared, and the session waited until you
  pressed Stop, which then answered the request with "Denied by
  SipAI." The request now appears under the conversation, the way it
  already did for later messages.
- **Plan mode ends with the plan, and three clear choices (Claude
  Code).** When a session in Plan mode finishes planning, the whole plan
  now appears under the conversation with the same choices Claude Code
  offers in the terminal: **Approve and accept edits**, **Approve, ask
  before edits**, or **Keep planning**, after which Claude stops and
  waits for your next message saying what to change. Approving also moves that
  session's mode chip off Plan, so your next message does not start
  planning all over again. The approved plan stays readable in the
  transcript instead of as a cut-off line of code.
- **A Claude Code or Kimi Code installed by Homebrew no longer shows
  an update SipAI cannot apply.** Their own update commands leave a
  Homebrew install to Homebrew — `claude update` prints that it is
  managed by Homebrew and changes nothing, `kimi upgrade` names `brew
  upgrade kimi-code` — and SipAI never runs Homebrew, yet the row
  compared the installed version with the newest release, put up the
  notice that a newer version was out, offered **Update**, and reported
  "Update did not complete" every time. The row now says **Managed by Homebrew** and offers
  nothing. For the `claude-code` cask the comparison itself was wrong:
  that cask follows Claude Code's `stable` channel, not `latest`.
- **Claude Code's update check follows its release channel.** A copy
  kept on the `stable` channel (`autoUpdatesChannel` in Claude Code's
  settings) was compared with the `latest` release, so it read as
  behind while `claude update` answered that it was up to date.
- **Updating Kimi Code works on kimi.ai.** A Kimi Code on the kimi.ai
  site asks to be updated with the kimi.ai installer, and SipAI's Update
  accepted only the kimi.com one, so every update ended "Update did not
  complete". It now runs whichever of
  Moonshot's two official installers Kimi Code names — and nothing
  else.
- **A long section name stays on one line.** A long custom agent name,
  or a long Local Files folder name, could show as one cut-off line
  stuck to the top of a header row twice as tall when the sidebar was
  narrow; it now shortens with "…" like every other name in the sidebar.
- **The model chip follows your Claude Code update.** After updating
  Claude Code, the composer's model rows now name the models the new
  CLI actually runs ("Opus 5", "Fable 5.1") as soon as it is installed
  — no relaunch and no first message needed — and an open session's
  chip says which model its next message will use, with the model it
  last ran under on hover. The "Other models" section and the Default
  row follow the same update at once.
- **The effort chip lists only the levels the model has.** On a Claude
  Code session it offered Low through Max for every model, but Haiku
  takes no effort at all, and Opus 4.6 and Sonnet 4.6 have no XHigh;
  picking one of those ran the message at a different level, with
  nothing saying so. The chip now lists each model's own levels, read
  from the installed Claude Code, and disappears for a model that has
  none. Switching model clears a level the new model lacks, now in the
  scheduled-task editor too, for every agent.
- **Fast mode now says when it isn't running (Claude Code).** On a
  Claude plan, fast mode is paid from usage credits. When those run out,
  Claude Code still asks for fast mode on every reply, is refused, and
  sends it again at standard speed — a little slower than with the
  switch off — while still reporting fast mode as on, which is what
  SipAI showed. The bolt on the model chip is now struck through
  whenever replies run at standard speed, the chip's hover and the
  switch say why in Claude Code's own words ("Fast mode disabled · usage
  credits exhausted"), and the switch warns before you send when your
  usage credits are unavailable. Under the switch, whether it is on or
  off, a line says what fast mode costs — on a Claude plan, "Claude Code
  fast mode is paid only from usage credits.", never from the plan's own
  5-hour or weekly limits — and a second line says what stands in its
  way right now. It is offered only on the models the installed Claude
  Code gives it to, rather than on every Opus model, and not through
  Amazon Bedrock, Google Vertex or Microsoft Foundry, where Claude Code
  does not offer it.
- **Fast mode no longer switches itself off in sessions you reopen.** A
  Claude Code session that had never been sent from SipAI took its fast
  mode switch from its last reply — and while usage credits are out,
  every reply records standard speed, so those sessions opened with the
  switch off and stayed off after the credits came back. A reply that
  ran fast still turns the switch on; one that ran at standard speed no
  longer turns it off.

- **At the larger font sizes, paragraphs and bullet points spread out
  with the text.** The space between paragraphs, between list items and
  between messages stayed fixed while the space between wrapped lines
  grew, so at Larger and Large text mode a wrapped line could sit
  farther from its own paragraph than the next paragraph did — and a
  bullet's second line farther than the next bullet. Every gap now
  grows in step with the line spacing, in chats and agent sessions
  alike.
- **Installing an update while an agent turn is running no longer
  looks like nothing happened.** SipAI waits for a running turn before
  it installs an update, but it used to wait silently: the "Install
  and Relaunch" button went dead the moment it was clicked, and the
  update landed minutes later — or on the next quit — with nothing in
  the update window saying why. From the next update on, the click is
  answered: SipAI asks whether to wait for the turn or interrupt it and
  install right away, and names the sessions that are mid-turn. If you
  wait, the sidebar says the update will install once the turn
  finishes, the download icon marks Settings → Updates, and **Install
  Now** there installs it at once — Check Now stays greyed out until it
  has; if you quit before the turn ends, the update is installed on the
  way out without reopening. This update is still installed by the
  previous version, which keeps the old behaviour one last time: with a
  turn running, it installs and relaunches by itself once the turn
  finishes, or installs when you quit. If you would rather choose the
  moment, let running turns finish before clicking Install and
  Relaunch.
- **The update window no longer offers "Automatically download and
  install updates in the future".** SipAI never downloads an update by
  itself — every install starts with your click — so ticking that box
  changed nothing: the setting was reset at the next launch. The window
  offering this update belongs to the previous version and still shows
  the box; from the next update on it is gone.

- **The scheduled-task page follows Font Size.** Its text, line
  spacing, buttons, pickers and gaps stayed at the Default size on every
  tier; they now grow and shrink with the rest of the window, with lines
  spaced the way a conversation spaces them.
- **Change and Choose… on the scheduled-task page highlight under the
  pointer,** like the page's other buttons.
- **A scheduled task's run appears under its task as soon as it
  starts.** It used to be listed among your other sessions, under the
  task's name, until the run finished — then it moved into the task and
  took the name the run is known by. It is now in its task, under that
  name, from the first moment.
- **Changing when a scheduled task runs no longer starts a run on the
  spot.** Moving a task to a new time — say from every hour on the hour
  to every hour at :15 — started a run the moment it was saved whenever
  the new time had already passed that hour or day, and resuming a
  paused task did the same. A changed or resumed schedule now starts
  from its next time, as a new task does.
- **A long scheduled run no longer makes the next one start the moment
  it ends.** If a run was still going when the task's next time came,
  SipAI started that next run as soon as the long one finished — and a
  task whose runs took longer than its interval then ran back to back,
  drifting further off its schedule each time. Now SipAI waits up to five
  minutes for the running one, and otherwise skips that time; the task's
  panel says it was skipped because the previous run was still going.
- **Pausing a scheduled task from its page sticks.** With unsaved edits
  in the page's form, pressing Pause and then Save wrote the task back
  as active. The form's Active checkbox now follows the Pause / Resume
  button.
- **An agent tool no longer drops out of Settings → Updates while it
  updates.** Updating Codex — or any tool installed with npm — could
  take its row out of Settings → Updates partway through, its Cancel
  button with it, and turned its sidebar section read-only until the
  update was done, because npm removes a tool while it downloads the new
  version. The tool now stays listed, with its progress, for the whole
  update, and shows the new version the moment it lands. Cancelling
  keeps it listed too: npm finishes the download it is in before it puts
  the old version back, and the row says "Cancelling…" until it has.
- **A scheduled run's first message no longer shows its filing tag.**
  While a run was in view — opened from its row while it was going, or
  shown by Run now — the message that started it carried the `<scheduled-task>` tag
  SipAI files it under, so the bubble drew the tag, the message appeared
  twice while the run was going, and the branch pencil on it could not
  find the message in the transcript. The tag is now taken off the
  message the moment it is sent, as it always was on reopen.
- **Deleting a scheduled task while a run of it was going, then creating
  a task with the same name, could start it at once.** The finished run
  wrote its record back under the deleted name, and the new task read
  that record as a slot it owed. A deleted task's run now writes nothing.
- **Branching from the older of two identical messages sent in one
  sitting cut at the newer one.** A message that only exists on screen
  (sent this visit) is found in the transcript by its text, newest
  first; the pencil now says how many newer copies to skip. And a branch
  whose source you had clicked away from before it was made no longer
  loses the edited message — it waits in the new session's box.
- **Turning off "Check these tools for new versions automatically"
  while a check was in flight could still show a new version
  afterwards.** The answer
  landing after the switch went off is now dropped.
- **A `# comment` after `model_context_window` in Codex's config made
  the Codex context chip divide by the default window.** The value is
  read the way Codex reads it, comment and all.
- **Code blocks are read the way Markdown defines them.** A Markdown
  file that contains its own code blocks — which models wrap in four
  backticks — broke apart at its first inner block; it now shows, copies
  and saves as one block. Blocks fenced with `~~~` are code blocks.
  Three backticks inside a sentence or a table cell no longer turn the
  rest of the reply into one grey block. And a code block inside a
  numbered list no longer carries the list's indentation into the code.
- **Long lines in a code block wrap.** A line wider than the
  conversation ran off the edge, with no scroll bar to show it was
  there; it now continues on the next line. Copy and Save carry the
  lines exactly as written.
- **Two Kimi Code sessions started at the same moment in one folder
  stay two.** Kimi Code names a new session only when its first reply
  ends, so SipAI looks the session up while the reply runs — and it
  took the newest new session in the folder. When two started together
  there (a scheduled task firing as you started a session, or `kimi`
  started in Terminal), both were tied to the same one, and your next
  message went into the other conversation. SipAI now takes only the
  session holding the message it sent, and when two hold the same
  words, waits for Kimi Code to name it.
- **A deleted chat's unsent message no longer turns up in a new chat.**
  Unsent text is kept per chat when you switch away. Deleting the chat
  left it behind, and the next chat whose first words matched — which
  is given the same file name — showed that text in its box right after
  its first message. Moving a chat to another group from the sidebar,
  likewise, left its unsent text behind; it now moves with the chat.
- **Deleting a Claude Code session while its reply was still running
  left a stray file behind.** The transcript was removed first and the
  run stopped after, and the stopping process wrote a few lines of its
  own bookkeeping back under the same name. A running session is now
  stopped first and deleted once it has ended — and its row leaves the
  sidebar the moment you confirm, instead of when the files are gone.
- **A scheduled task that had not run yet did not open while a note was
  on screen.** Its page now takes the note's place, as anything else
  you open does.
- **Opening a scheduled task's page from a chat left the chat
  highlighted in the sidebar.** The page showed, but the chat still
  counted as open behind it; it now closes, as it does when you open
  anything else.
- **Saving a scheduled task whose prompt ended in a blank line left Save
  lit**, as though nothing had been saved, and the settings stopped
  picking up later changes to the task's file. A save tidies the prompt
  before writing it; the settings now compare what saving would write.
- **Renaming a scheduled task from the sidebar while its page had
  unsaved changes was undone when they were saved** — the page's Save
  wrote the old name back. Renaming it with the pencil also lit Save for
  a moment, as though the settings had changed. The page's settings now
  always carry the task's current name.
- **A Codex session's web searches show when it is reopened.** A search
  appeared while its turn ran and was missing from the transcript once
  the session was opened again, because Codex records a search with
  nothing but what it looked up; SipAI now reads it that way.
- **Quitting one copy of SipAI no longer cuts off another copy's
  permission requests.** With two copies open — the installed one and
  one built from source, say — quitting either used to remove the
  connection agent tools use to ask for approval, even when the other
  copy was the one using it; that copy's requests then never appeared
  until it was relaunched. A copy now removes only the connection it
  made.

### Security

- **Deleting a scheduled task can no longer remove a folder outside
  SipAI's task folder, or another task's.** A task whose definition is
  gone takes its name from the tag in its runs' first messages, and any
  session's first message can carry one: a name such as `../../Desktop`
  made Delete remove that folder instead, and one that differed from a
  live task's only in capitals (`Daily-Report` beside `daily-report`)
  removed that task's definition. A task's folder is now only ever the
  task's own, directly inside `~/.claude/scheduled-tasks` and spelled
  exactly as its name, whatever its runs say.
- **A message can no longer crash SipAI every time it is opened.** A
  reply, a transcript or a note holding a particular sequence of
  invisible characters — one a model's reply can contain — made SipAI
  crash while drawing it, and so every time that conversation or note
  was opened again. Those characters are now ignored.
- **Deleting a Codex session removes only that session's files.** Its
  files were found by the session's id appearing anywhere in their
  names, so a crafted session whose id was a single character could have
  taken other sessions' files with it. The match is now exact.
- **A released copy always asks its own update feed.** Another program
  running as you could write a different feed address into SipAI's
  settings, and SipAI would have asked it for updates. Nothing from such
  a feed could have been installed — every update must carry SipAI's
  own signature — but it could have held real updates back and chosen
  the words the update window showed.

## [1.0.3] — 2026-09-04

### Added

- **Settings → Updates now covers the agent command-line tools.** Each
  installed CLI — Claude Code, Codex, Kimi Code — is listed with its
  version and, once a check has succeeded, whether a newer release
  exists. A stale CLI used to fail silently: turns kept working against
  whatever models the old binary knew, with nothing on screen saying so.
  Now an **Update** button runs the tool's own updater — or, for a Kimi
  Code the vendor's updater declines to update, Moonshot's own installer,
  pinned to the version shown — and a small banner in the window says a
  tool is behind until you close it for that version. A tool that
  updates itself takes its own banner down. The check has a toggle of
  its own and sends nothing about you.
- **Fast mode.** The model menu gains a switch for the agents that have
  one: Claude Code's fast mode on Opus models, and Codex's faster
  service tier where the model offers one. A bolt on the chip shows it
  is on, and the chip's hover reports what the agent said about it.
- **Previous model versions stay reachable (Claude Code).** The model
  menu lists the newest version of each family as before, and an
  **Other models** section beneath with the previous version the
  installed CLI still offers — pick one to pin a session to it, the way
  Claude Code's own picker allows. The Default row now names what a send
  with no model flag actually runs, read from claude's own settings.
- **A + on custom groups.** Grouped by Custom, each group you named
  carries the same **+** a folder header does: the session it starts
  belongs to that group from its first message and opens in the folder
  you last used there. A group stays visible while empty, so a new one
  can be used straight away, and a task scheduled from that page is filed
  in the group too.

### Changed

- **The context chip is a percentage.** It now reads like Claude Code's
  own indicator — how full the context window is on the newest call, with
  the exact numbers on hover — instead of a token count that looked like
  a running total. It divides by the window each CLI states for the model
  in force, so a Claude session at 20% of a 1M window no longer reads
  "100%". When no window is known it shows the count and says so.

### Fixed

- **Compaction is visible.** When an agent summarises the conversation
  to make room, the transcript now shows a **Conversation compacted** row
  (with before-and-after sizes where the agent records them) and labels
  the summary as the agent's, not as something you wrote; Claude Code's
  half-minute of silence while it compacts shows as "Compacting
  context…" rather than as a hang. All three agents, live and on reopen.
- Kimi Code's context chip now moves during a turn instead of only when
  the turn ends.
- **Codex's model list keeps up with Codex.** A model that appears in
  Codex's own picker after a Codex update — or that OpenAI switches on
  server-side — now shows in SipAI's model menu without a relaunch: the
  list is re-read whenever Codex rewrites its catalog, and after an
  update (and once a day otherwise) SipAI asks Codex for its list
  directly, the way Codex's own picker fills itself at startup. No model
  is called and nothing is billed.
- **Codex's context chip honours `model_context_window`.** A window
  raised in `~/.codex/config.toml` is what the percentage divides by,
  clamped to the model's maximum exactly as Codex clamps it, so the chip
  agrees with Codex's own status bar on such a setup.

### Security

- The command-line-tool version check can be switched off, and its
  requests are bounded in size. The one installer SipAI can run
  (Moonshot's, for a Kimi Code the vendor's updater declines to update)
  is fetched over HTTPS only, size-bounded, staged in a private temporary
  folder, and pinned to the version named on the row; it never edits
  your shell files.

## [1.0.2] — 2026-08-30

### Added

- **Equations are typeset, not approximated.** Mathematics in chats and
  agent transcripts is now laid out properly — real fraction bars, sums
  and integrals with their limits in place, matrices, aligned
  derivations, and brackets that grow to fit what they hold. Notes
  already rendered this way; chats and transcripts now agree with them.
  Right-click an equation for **Copy LaTeX**. One trade: a displayed
  equation is drawn rather than kept as text, so its source no longer
  turns up in search — Copy LaTeX is how to get it.
- **Renaming an agent session reaches the agent.** Rename a session in
  the sidebar and Claude Code's and Kimi Code's own session pickers show
  the new name too, instead of only SipAI showing it. Codex rebuilds its
  titles from the first message on every run, so a Codex rename stays
  SipAI's — and if a write to an agent doesn't land, SipAI now says so
  rather than leaving the two quietly disagreeing.

### Fixed

- **Work the agent backgrounds no longer disappears (Claude Code).**
  Asking for something long — "start this and tell me when it's done" —
  could end with the answer never arriving: no error, no exit, and
  nothing in the transcript on reopen. That work now runs in the
  foreground, where its result actually lands.
- **Choosing a model no longer renames the others.** Picking a different
  model mid-session could show the previously running model's name — for
  that model and then for every other one in the menu — and the wrong
  name survived a restart. The model you picked always ran; only the
  name was wrong. An install already affected corrects itself on first
  launch.
- **"Show earlier" now reaches the start of a long session.** It used to
  walk back a few hundred rows and then vanish with the beginning of the
  transcript still out of reach, and nothing saying so. It keeps loading
  older turns now, and when a session really is too large to show whole
  it says that plainly instead of going quiet.
- Symbols such as `\varphi` and `\ell` no longer print as source, and a
  nested expression — a fraction inside an exponent — is no longer
  scrambled into a different one.
- In an agent session, the context tooltip reports the model's real
  context window for Codex and Kimi Code sessions rather than assuming
  200,000 tokens.

### Security

- The new equation renderer bounds what it reads out of a font file, so
  a malformed or hostile one can stall neither the drawing nor the app.

## [1.0.1] — 2026-08-21

### Added

- **Attach files to a chat.** Drag an image, a PDF, or a text file onto
  the message box — or use the **+** button — to send it with your next
  message. Images and PDFs go to models that can read them; text files
  are included inline, so you can keep asking about them in later turns.
  A full paper fits: a PDF's text travels whole up to 400k characters.
- **Notes render mathematics, and export to PDF.** Equations are now laid
  out properly — fractions, integrals, matrices, aligned equations — instead
  of approximated. A note can be saved as **PDF** as well as Markdown, from
  the ••• menu.

### Fixed

- **Long-thinking models no longer fail with "Network error".** Chat
  requests now stream from the provider, so the connection stays alive
  while a reasoning model thinks for minutes before its first word — the
  reply still arrives in one piece. Previously, anything on the network
  path that drops idle connections (a local proxy, a corporate gateway)
  killed the request before the first byte arrived.
- **A reply could go missing if you switched away while it was arriving.**
  Send a message, then open another chat, a note, or an agent session, and
  the answer is now delivered to the conversation that asked for it. You can
  leave and come back mid-reply, and a turn that is interrupted or fails now
  says so when you return.
- Mathematics in chat and agent transcripts renders more faithfully —
  vectors and subscripts like `x_max` no longer come out garbled.
- An agent with no CLI installed and no saved sessions no longer shows an
  empty section labelled "(read only)".
- The "no output yet" notice on an agent turn now waits longer before it
  appears, so a slow first response isn't flagged as a problem.
- More of the Simplified Chinese interface is translated: find and global
  search, the model-setup screens, parts of onboarding, the "You" label
  above your messages, and the built-in starter role.

### Security

- Hardened the new note-rendering and file-attachment features against
  malformed input: crafted content can't crash note preview, attachments
  are bounded by file size and image dimensions before being read, and
  notes render in a tighter sandbox.

## [1.0.0] — 2026-08-17

First public release.

### Added

- **Chat with 20 built-in providers** through one interface, plus a
  custom entry for any OpenAI-compatible URL — which is also how you
  reach a local server (Ollama, LM Studio, vLLM, …) or anything
  self-hosted. Region-bound providers ask which endpoint your key came
  from.
- **Chats, groups and roles.** Organise conversations into folders with
  their own system prompt, and switch between named, reusable roles.
- **Notes** written by the model from a conversation or an agent
  session, with optional instructions of your own.
- **Agent sessions** for Claude Code, Codex and Kimi Code — browse,
  group, rename, resume and delete them, including sessions started in a
  terminal. Transcripts stream live as the agent works.
- **Inline permission approvals.** Claude Code tool requests appear as
  Allow / Deny cards in the transcript, with a notification when the app
  isn't focused.
- **Scheduled agent tasks**, fired in-process by the app rather than by
  `cron`, so they inherit the app's own file access. A slot missed while
  the app was closed fires once on next launch.
- **Session branching** (Claude Code): edit an earlier message and
  continue from there, as a new session, leaving the original untouched.
- **Automatic updates.** SipAI checks `updates.sipai.dev` once a day and
  offers new versions in a small window with these notes in it. Nothing
  downloads until you say so, an update never interrupts a running agent
  turn, and the whole thing can be switched off in
  **Settings → Updates**.
- **English and Simplified Chinese** throughout.

[1.0.3]: https://github.com/YZCODE01/SipAI/releases/tag/v1.0.3
[1.0.2]: https://github.com/YZCODE01/SipAI/releases/tag/v1.0.2
[1.0.1]: https://github.com/YZCODE01/SipAI/releases/tag/v1.0.1
[1.0.0]: https://github.com/YZCODE01/SipAI/releases/tag/v1.0.0
