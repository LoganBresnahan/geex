# ADR-0001: Build the editor on the BEAM / OTP

- **Status:** Accepted
- **Date:** 2026-05-27

## Context

An editor needs crash-resilience, concurrency (language servers, panes, extensions,
background work), and — for our ambitions — collaboration and isolation. Most editors
fight their runtime for these properties and bolt them on.

## Decision

Build geex on the BEAM (Erlang VM) with OTP. Model the editor as processes: a buffer is
a process, each LSP client is a process, each pane is a process, each extension is a
process — under supervision trees.

## Consequences

- **Free:** crash recovery (a syntax highlighter dies, the supervisor restarts it, the
  buffer never notices), process isolation (an extension can't scribble another
  process's heap — security by default), distribution ("edit my buffer from your laptop"
  is spawning a process on another node), hot code reload.
- **Cost / weak spots:** the BEAM is not a GUI-native runtime — TUI on `prim_tty` is the
  v0.1 frontend; a native/GPU frontend is a harder, later question. Heavy numeric/text
  crunching needs care (NIFs/ports where it matters).
- Underpins everything downstream: commands-as-data, the single shared path, provenance,
  collab, and the "supervised execution" the AI layer would otherwise need a library for.

## See

[notes.md](../notes.md) (Why BEAM), [vision.md](../vision.md) §1.
