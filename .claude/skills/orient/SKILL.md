---
name: orient
description: Take a bearing at the start of a new geex context window. Read the recent commits, the roadmap's command-surface track, and the tail of the testing.md verification log to reconstruct what shipped and what's next, follow the commit trail into whichever ADRs it points at, then reconcile that ground truth against remembered state (MEMORY.md, cavemem) and flag any drift. Read-only — it briefs, it does not write memory or change code. Run when opening a fresh session or whenever you've lost the thread of where the project stands.
---

# /orient — take a bearing at session start

A new context window starts blind to *where we are*. This reconstructs it from
the sources that don't auto-load — the commits, the roadmap, the verification
log, and the ADRs they point at — then checks that what you already remember
still matches reality.

**Read-only.** The deliverable is a briefing, not actions. It does **not** edit
code and does **not** write memory — memory files and cavemem own writing;
orient only reads and reconciles them. Assumes cwd = the geex repo root (same as
`/shipshape`).

## The context sources — and which lane is orient's

| Source | Holds | Trust | Loaded |
| --- | --- | --- | --- |
| CLAUDE.md | how-to-work rules + invariants | authoritative, static | auto |
| MEMORY.md + `memory/*.md` | curated durable facts | *as-of-write-time* — can drift | auto |
| **cavemem** (MCP, if connected) | narrative / the *why*, cross-session | *as-of-write-time*, richer | **on-demand** |
| **git + `doc/roadmap.md` + `doc/testing.md` log + ADRs** | what the code *is* / the plan *says* / what was hand-verified | authoritative, **current** | **must be read** |

Rules that keep the lanes disjoint:

- **Don't re-summarize CLAUDE.md or MEMORY.md** — they're in context already.
  Add the *delta* (what changed since last session) and the *reconciliation*
  (does memory still match ground truth?).
- **git = what shipped. ADRs = what was decided. testing.md = what was
  verified by hand. cavemem = what was discussed.** Reach into cavemem only for
  a *why* none of the others carry.
- **orient never writes memory.**

**The geex twist: the build-progress memory is a long narrative log.**
`geex-build-progress.md` accretes a paragraph per slice and is far larger than
any one session needs. Read its **last two or three dated sections only** —
they carry the "Next BUILD" and "DEFERRED" lists that the roadmap may not have
caught up with. Everything older is history the commits already prove.

## 1. What shipped — read the commits

```bash
git log --format='%h %ad %s' --date=short -12
git status --short
git branch --show-current
```

Read back only until the arc is coherent — usually the last 5–10 commits. You're
answering three things: last known-good state, what landed most recently, and
whether there's uncommitted WIP on the floor. Note the **date gap** to today —
after a long gap, say so and lead the bearing with "verify the suite still
runs" (toolchain and the `../tree_sitter_wasm` path dep can rot independently).

Subjects are `<Area>: <what> (ADR-NNNN)`; the area is a fast filter for which
subsystem has been moving, and the ADR number is the doc to pull on demand.

## 2. Where we meant to be — the roadmap

`doc/roadmap.md` is long. Read, in this order:

1. **"The command surface & shell (in flight — the minibuffer track)"** — the
   numbered list. This is the live frontier; each item says *built* /
   *remaining*.
2. **"## v0.5 — The ledger"** — the numbered ledger track (ADR-0032:
   reconcile as the primary agent path, attested by captAInHook). The old
   Direction A material under it is frozen; don't report it as the frontier.

There are two live tracks. The **frontier** = the first ledger-track item not
evidenced by a commit; name the first open command-surface "Remaining:" item
alongside it. Note any
**Deferred:** lists in the last few commit bodies — they're the carry-ins
waiting on the next task.

Then skim the **last heading** of `doc/testing.md`'s verification log:

```bash
grep -n '^### ' doc/testing.md | tail -3
```

If the newest commits are newer than the newest log entry, that's drift worth
reporting (a slice shipped without its verification entry).

## 3. Reconcile ground truth against memory  ← the cavemem step

MEMORY.md is already in your context. For every remembered claim naming a
concrete artifact — a file, module, function, keybinding, ADR number, test
count — **verify it against what git / roadmap / code show now.** Memories
reflect write-time truth; flag drift explicitly rather than trusting them.
Known-drifty claims in this repo:

- **Test counts** — memory, roadmap "Where we are", and commit bodies all quote
  them; only `mix test` is current.
- **Keybindings** — they've been re-laid-out at the user's request more than
  once (ERTYUIOP → WASD cluster; Ctrl-G → Alt+N). Check `lib/geex/loop/keymap.ex`.
- **"Deferred" items** — may have quietly landed. Grep before reporting one as
  open.

Then, and only then, reach for the *why* the commits don't carry (skip cleanly
if the cavemem MCP isn't connected):

```
cavemem search "<topic the commit raised>"   → get_observations(ids)
# or replay the last session:
cavemem list_sessions → timeline(session_id) → get_observations(ids)
```

Query cavemem against a **specific question the commits raised** — never dump it.

## 4. Follow the trail into docs (on demand)

Read the *specific* referenced doc **only when the next move touches it**:

- **`doc/adr/README.md`** — the index; resolve an ADR number to its title and
  status. Many ADRs carry dated **amendments** at the bottom — the amendment,
  not the original Decision, is often the current truth.
- **`doc/vision.md`** — before anything that changes *what geex is* (the
  world-vs-brain test).
- **`doc/mcp-ai-integration.md`** — before AI-layer work; `§N` references in
  other docs point here.
- **`doc/bugs.md`** — the triage shelf; an open bug outranks new work.
- **`doc/notes.md`** — brain-dumps (e.g. grid-render ideas); non-authoritative.

Statuses matter: an ADR marked **Proposed** is a design not yet built.

## 5. The bearing (report)

```
ORIENT — geex @ <branch> <sha>  (last commit <date>, <n> days ago)
  shipped     <recent arc in one line>  · last good: <commit>
  wip         <uncommitted files, or "clean">
  frontier    <command-surface "Remaining:" item | v0.5 item>  · open bugs: <n>
  verify-log  <newest testing.md entry> <in step | behind by: <commits>>
  drift       <remembered-vs-actual mismatch, or "none">
  next move   <the obvious task> — read <the one doc> first
```

Keep it to that shape. The point is a fast "you are here" that lets work resume
in one turn — not a re-run of the project's whole history.
