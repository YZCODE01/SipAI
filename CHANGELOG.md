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

[1.0.2]: https://github.com/YZCODE01/SipAI/releases/tag/v1.0.2
[1.0.1]: https://github.com/YZCODE01/SipAI/releases/tag/v1.0.1
[1.0.0]: https://github.com/YZCODE01/SipAI/releases/tag/v1.0.0
