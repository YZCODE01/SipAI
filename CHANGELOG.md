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

[1.0.0]: https://github.com/YZCODE01/SipAI/releases/tag/v1.0.0
