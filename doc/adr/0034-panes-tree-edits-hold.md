# ADR-0034: Panes, the file tree, the edits pane, and holding open buffers

- **Status:** Accepted 2026-10-15 (open decisions A, F–K taken as recommended). **Built**
  2026-10-15: the hold (1), more than one buffer (2), the edits pane with the layout and `Alt+O`
  (3), the file tree (4), "edited by you" (5). **Amended** 2026-10-16: the tree has no cap, and
  is read in a process of its own. **Keys amended** 2026-10-17 by
  [ADR-0037](0037-pane-and-file-keys.md): `Alt+P` is the next pane, `Alt+L` the edits pane,
  `Alt+J` fast-forward, `Alt+O` opens a file. **Splits and tabs** (deferred here) built
  2026-10-17 by [ADR-0038](0038-split-panes-and-tabs.md). **Amended** 2026-10-18: the tree
  follows files coming and going (`Geex.Tree.Watcher`), and reconcile's watch isn't recursive.
  Rewritten the same day after the maintainer's redirect: the first draft's follow pane is dropped.
- **Date:** 2026-10-15
- **Relates to:** [ADR-0028](0028-editor-shell-and-minibuffer.md) (the shell; it deferred tabs and
  the file tree "behind the pane system"), [ADR-0014](0014-editor-state-and-dispatch-ownership.md)
  (the cursor is view-local), [ADR-0017](0017-reconcile-file-watch.md) (reconcile; this replaces
  "adopt on every disk event" for open buffers), [ADR-0032](0032-listener-first-agent-integration.md)
  (the intake and payload; this replaces step b's "disk wins" merge),
  [ADR-0033](0033-durable-ledger.md) (the spool and its chain rule, reused for held buffers),
  [ADR-0026](0026-terminal-input-model.md) (keys)

## Context

The maintainer wants three things in geex (decided in the coordinator session):

- **A file tree**, plain: names only, no who/when column.
- **An edits pane**: a list of edits (file · who · when). Selecting a row opens that file.
- **Open buffers hold.** When an open file changes on disk, the buffer does not change: "changes
  don't magically appear". geex marks the buffer as behind, the edits pane shows a "disk is newer"
  row, and selecting it fast-forwards the buffer to disk. This applies to a clean buffer too.

And a principle: "preferably all of that can be determined by git … we just display what git says."

The first draft of this ADR proposed **follow** (the agent's file opening in a side pane as it is
written). The maintainer replaced it with the above; it is dropped, together with rebuilding a
file's before text from the tool's `structuredPatch` and the creates rule that came with it.

What exists today:

- **One buffer on screen.** `Geex.Loop` renders the active buffer full-screen. `Geex.Session` holds
  one `Geex.View` and an unused `layout`. There is no open/switch verb.
- **Reconcile adopts every disk change at once** (`Geex.Reconcile.reconcile/2`): a clean buffer takes
  the disk text; a dirty one is three-way merged by `Geex.Edit.Merge` (base = `synced`, ours = the
  buffer, theirs = disk), where an overlapping hunk of yours takes the disk version (one undo away)
  and you get a notice.
- **The payload POSTs every `Write` / `Edit` / `NotebookEdit` to every running geex.** A geex without
  the file open answers `not_open`. The payload counts only `attested`, `pending` and `ignored` as
  taken; if nobody took it, it appends it to the file's spool (ADR-0033 F).
- **No mouse.** `Geex.Input.Parser` drops mouse reports. (The mouse came later:
  [ADR-0039](0039-mouse.md).)

Holding creates a danger: `Ctrl-O` on a buffer that hasn't taken a disk change would write over the
agent's change. So saving a buffer that is behind must merge first, and that ships together with
the hold.

## Decision

### 1. Open buffers hold; fast-forward on demand

- **Behind.** A buffer is behind when the file on disk differs from its `synced` text (what it last
  loaded, saved or took in from disk). The watcher still reads each settled change. Instead of
  reconciling, it marks the buffer behind, or clears the mark when the disk matches `synced` again
  (an agent undoing its own change, a `git checkout` back). The text, cursor and history don't move.
- **Shown** on the status line ("behind disk") and as a "disk is newer" row in the edits pane (§6).
- **Fast-forward** (`Alt+L`, the verb `fast-forward`, or Enter on that row) reads the disk now and runs
  the reconcile core once, from `synced` to disk. A clean buffer takes the disk text, and a dirty one
  is merged (§2). It is one group; `Alt+Z` undoes it.
- **Credit: a held buffer treats agent writes the way ADR-0033 F treats a closed file.**
  - An attestation that matches no recorded group is **held**: kept in the buffer (at most 256) and
    answered `held`.
  - The payload counts `held` as not taken, so it also spools the attestation, and the payload needs
    no change. The payload spools only for a file with a ledger, so a crash while holding still
    credits the write on reopen only when the ledger is on (it is by default).
  - Duplicates and races are harmless. The chain rule links an entry only when its `before` is the
    current link, so a write that is both held and spooled can't link twice. A payload append that
    lands just after a fast-forward clears the spool leaves one stale line, which can't link because
    `synced` has moved past its `before`. A test pins each case.
  - Fast-forward credits its group by the spool's chain rule, over the held entries and the spool:
    one write, or a chain all from one session, credits that session; anything else stays
    `:external`. It then clears both.
  - An attestation arriving after the fast-forward still upgrades the newest group by exact match, as
    today.
  - The pending table and its 10 s expiry go away, since under the hold nothing reconciles within
    10 s.
- **The cost:** two sessions writing the same open file between two fast-forwards land as one
  `:external` group, where today each write is its own credited group. Per-write groups would need
  each intermediate text. The watcher does read them, so keeping them (bounded) is a later option.
- **Opening a file is unchanged**: it shows the disk (ADR-0033 restore, plus a gap if the file
  changed). Opening a file means you asked to see it.

### 2. The merge is `git merge-file`

- When a fast-forward (or a save, §3) meets a dirty buffer, geex runs
  `git merge-file -p -L buffer -L base -L disk <ours> <base> <theirs>`, with base = `synced`,
  ours = the buffer, theirs = disk. The three inputs go in a private `0700` temp directory, removed
  afterwards. It works outside any repository.
- **Exit 0, a clean merge:** the merged text enters as hunk commands (`LineDiff`, buffer → merged)
  through the shared path, as one group. Your unsaved changes stay unsaved.
- **Exit N > 0, N conflicts:** the merged text, with git's `<<<<<<< buffer` / `=======` /
  `>>>>>>> disk` blocks, enters the same way. A notice says "N conflicts: resolve the marked blocks,
  then save". Nothing of yours is replaced unseen.
- **Checked here** (git 2.43): a clean merge exits 0; one overlapping hunk exits 1 with the labelled
  block; a file with a NUL byte exits 255. `merge.conflictStyle` (even `zdiff3`) doesn't change
  `merge-file`'s output, so the markers §3 looks for are stable.
- **Line endings:** if one side is CRLF and the other LF, git conflicts the whole file, giving one
  block. That is what git says. It is rare, because Claude Code keeps a CRLF file's line endings.
- **This replaces ADR-0032 step b's "disk wins, you're told"** for open buffers. `Geex.Edit.Merge`
  stays: per-agent revert uses it to refuse on overlap (ADR-0033 §7), and it is the fallback.
- **Without git**, or on a git error (a binary file), geex uses its own merge and logs a warning: an
  overlapping hunk takes the disk version, one undo away.
- **Purity:** the merge runs in reconcile, outside the pure core. Only the commands it produces are
  recorded, so replay stays deterministic (invariant 3).

### 3. Saving a buffer that is behind (ships with §1)

- `Ctrl-O` reads the disk first. If it differs from `synced`, the save fast-forwards first, whether or
  not the watcher has noticed the change yet.
- **A clean merge** writes the merged text. **Conflicts** don't write: the markers are in the buffer,
  you resolve them, and you save again.
- **Leftover markers:** `Ctrl-O` refuses while the buffer still holds a `<<<<<<< buffer` …
  `>>>>>>> disk` block, and names its line. A second `Ctrl-O` in a row saves anyway, because a file
  can legitimately contain those lines.
- A write landing between the read and the write is still overwritten. The window is milliseconds,
  as in any editor.

### 4. Panes

```
┌ files ──────────┐┌ lib/geex/buffer.ex ───────────── behind disk ┐
│ ▾ lib           ││ ▌ 41 def attest(pid, a) do                   │
│   ▾ geex        ││ ▌ 42   GenServer.call(pid, {:attest, a})     │
│     buffer.ex   ││   43 end                                     │
│     ledger.ex   │└──────────────────────────────────────────────┘
│ ▸ test          │┌ edits ───────────────────────────────────────┐
│   mix.exs       ││ ▸ buffer.ex  disk is newer             17:21 │
│   README.md     ││   buffer.ex  claude-code/7ccbf3d1      17:21 │
│                 ││   ledger.ex  claude-code/7ccbf3d1      17:19 │
│                 ││   README.md  you                       17:18 │
└─────────────────┘└──────────────────────────────────────────────┘
 buffer.ex  behind disk (Alt+L)                                41:3
```

- **A fixed shape, not a general split tree yet:** the file tree on the left, the editor on the right,
  and the edits pane under the editor. A pure `Geex.Layout` maps the terminal size, and which panels
  are shown, to `Geex.Rect`s.
- **`Geex.Session` holds the panels, which ones are shown, and the focus.** The editor pane is today's
  View, and its buffer is `Session.active_buffer/0`, so the frozen MCP surface and every existing verb
  keep meaning "the buffer you're in". With both panels hidden, the screen is exactly today's.
- **Shown at start when there's room** (the tree from 100 columns, the edits pane from 20 rows);
  `tree` and `edits` toggle them.
- **Rendering:** each pane draws in its rectangle with a title on its top border. There is one status
  line for the editor. Only the editor shows the hardware cursor; a focused panel shows a selection
  bar.
- **More than one buffer:** `open PATH` (or Enter in the tree or the edits pane) shows a file in the
  editor pane, opening it if needed. `buffers` picks an open buffer through the palette's picker.
  `close` closes the current buffer and refuses a dirty one. `Geex.run/1` accepts several paths,
  or a directory, which opens the tree rooted there over an empty scratch buffer.

### 5. The file tree

- **The root comes from the path you give geex:** `git -C <dir> rev-parse --show-toplevel`, where
  `<dir>` is the directory you named or the first file's directory; outside a repository, `<dir>`
  itself. With no path, the tree is hidden. The working directory doesn't work as a root, because
  geex runs through mix from its own checkout.
- **The list comes from git:** inside a work tree,
  `git ls-files --cached --others --exclude-standard -z` (tracked files, plus untracked ones that
  aren't ignored). Outside a repository, it is a directory walk that skips dot-directories. (Capped
  at 10,000 entries until the 2026-10-16 amendment below: now no cap.)
- **Plain:** names only. Directories start collapsed. Enter toggles a directory or opens a file.
- **Re-read** whenever the tree is shown or takes focus. There is no directory watcher. (Until
  the 2026-10-18 amendment below: now it follows files coming and going by itself.)

### 6. The edits pane

- **`Geex.Edits`** keeps a bounded in-memory list (500 rows) and broadcasts each change to
  subscribers. It is not persisted, because the ledgers are the durable record.
- **A row** is file · who · when, newest first. "Who" is `claude-code/7ccbf3d1` (the status-line
  author's form), `you`, or `outside`.
- **Sources:**
  - attestations that reach the intake for files under the tree's root, open or not. The time is when
    geex got it, which is right after the write;
  - your saves;
  - disk changes to open files, keyed by the disk hash. A change an attestation explains is that
    agent's row. One nothing explains shows `outside`, and becomes the agent's row if the attestation
    arrives later;
  - one **disk is newer** row per buffer that is behind, pinned at the top until it fast-forwards.
- **Enter** opens the row's file in the editor, at the write's first changed line when its group is in
  the history. On a "disk is newer" row it opens the file and fast-forwards it.
- **What git says:** git can tell what changed since a commit, but not who changed it while it is
  uncommitted, so "who" comes from attestations. Where git does answer, geex asks git: the tree's file
  list, the merge, and later a diff view (`git diff --no-index` buffer vs disk, or against `HEAD`).

### 7. Keys and verbs (typed twins, ADR-0028 parity)

- **`Alt+O`** moves to the next pane. It is the lowercase chord: `Alt+Shift+O` sends `ESC O`, which is
  an SS3 prefix.
- **`Alt+L`** fast-forwards the current buffer.
- **In a panel:** the arrows move, Enter acts, and Esc returns to the editor.
- **Verbs:** `fast-forward`, `tree`, `edits`, `open PATH`, `buffers`, `close`.
- **Mouse:** Enter for now. Clicking a row (SGR 1006 mouse reports) is a follow-up.

### 8. Writes you edited in the permission prompt (optional)

- Claude Code's responses carry `userModified`: true when you edited the agent's proposed change
  before accepting it. The payload passes it as an optional `user_modified`, the actor records it,
  and the edits row and the status line say "edited by you".

### Out of scope for this ADR

- **Follow**, rebuilding the before text from `structuredPatch`, and attesting creates with
  `before = sha256("")`. All are dropped; ADR-0032's creates rule stays.
- **A shell write** (`sed`, a script) to a file geex doesn't have open makes no row: the hook has no
  content to attest, and nothing watches that file. A recursive watcher would come later.
- **A deleted file** leaves its buffer as it is, not behind, as today.
- A diff view, splitting the editor, resizing panes by hand, tabs, the mouse, and rebuilding the edits
  list from ledgers.
- Per-write groups across sessions while a buffer is held (§1).

### Built: step 1, the hold (2026-10-15)

- `Geex.Buffer.disk_changed/2` marks a buffer behind (`snapshot.behind`, `{:geex_buffer_behind, …}`);
  the watcher calls it instead of reconciling. `Geex.Reconcile.fast_forward/1` and `save/2` run the
  reconcile core; `Buffer.save/1` refuses with `{:error, :behind}` when the disk differs from `synced`,
  read at the write.
- `Geex.Edit.GitMerge` runs `git merge-file` under `sh` so git's stderr never reaches the terminal, and
  `unresolved/1` finds a block that is left. The fallback is `Geex.Edit.Merge` (an `:git_executable` app
  env seam lets a test see it).
- Held attestations replace the pending table. The credit is `Spool.chain` over the spool's lines, then
  the held list.
- **As built, beyond the text above:**
  - the frozen MCP `save_file` goes through `Buffer.save/1`, so on a buffer that is behind it now
    returns the `:behind` error instead of overwriting; it does not merge (no MCP change beyond that);
  - in a conflicting merge, the marker lines carry the group's credit (the `▌` mark), since the whole
    group is credited;
  - a buffer opened and never edited has no ledger entries, so a crash while holding reopens it fresh,
    as ADR-0033 does for any file it never recorded (the payload doesn't spool for it either).

### Built: step 2, more than one buffer (2026-10-15)

- **Re-sequenced:** step 2 shipped the buffers only. `Geex.Layout`, the panes and `Alt+O` move to
  step 3 with the edits pane: with one pane on screen they would have nothing to switch to (the
  named-consumer rule).
- `open PATH` (verb and palette): a relative path is resolved from the **current file's
  directory**, since the working directory is geex's own checkout. A directory is refused with a
  notice. The path keeps its case (the verb parser lowercases everything else).
- `buffers`: the palette's popup over the open buffers, most recent first, with the **previous**
  one highlighted, so `buffers` + Enter goes back. It is fuzzy-filtered by name and path.
- `close`: refuses a buffer with unsaved edits, then shows the previous buffer, or a new empty
  scratch buffer when none is left (`Geex.Session.close_active/0`). The frozen MCP `close_file`
  is unchanged.
- **Each buffer keeps its own cursor** (`Geex.Session`) **and scroll** (`Geex.Loop`) across
  switches. `Geex.run/1` takes a list of paths (the first shown) or a directory (a scratch
  buffer). The scratch buffer is now supervised (`BufferSupervisor.start_scratch/0`).
- **Found while dogfooding:** a typed verb's submit closed the minibuffer *after* running the
  action, so `buffers` opened its picker and closed it at once. Submits now close first.

### Built: step 3, the edits pane (2026-10-15)

- `Geex.Edits` (always on, in memory, 500 rows) gets attestations from the intake
  (`Geex.Attest.submit/1`, open file or not), disk changes from the watcher (when a buffer goes
  behind) and your saves (`Ctrl-O`). A change and its attestation are one row, joined by
  `{path, sha256}` in either order.
- `Geex.Layout` (pure) puts the edits pane in a band under the editor: a title row and up to 8
  rows. It is shown at start from 20 rows and dropped below 12. The editor renders as if the
  terminal ended at its own rectangle, so the frame code is unchanged. The "disk is newer" rows
  come from the buffers' cheap status (`Geex.Buffer.status/1`) at each repaint, not from storage.
- **The root** (`Geex.Session.set_start/1`, from the first path given to `Geex.run/1`) filters
  the pane to files under the git top level. It also fixes a step-2 bug the coordinator found:
  a relative `open` from a pathless buffer resolved against geex's own checkout. It now uses the
  directory geex was started in. Buffer-picker rows show paths relative to the root.
- `Alt+O` moves into the pane (highlighting the newest entry) and back. In the pane, arrows or
  `Alt+W`/`Alt+S` move, Enter acts, and Esc goes back. The minibuffer, the palette and quit still
  work; other keys do nothing. The `edits` verb shows and hides it.
- **Not built:** the tree's left column and its 100-column rule (step 4).

### Built: step 4, the file tree (2026-10-15)

- `Geex.Tree.list/1`: `git ls-files --cached --others --exclude-standard` under the root (less
  files deleted from disk), or a walk that skips dot-directories and symlinks outside a
  repository; at most 10,000 files. `Geex.Tree.rows/2` (pure): directories first, alphabetical,
  the open ones expanded. Git-tracked dot-directories (`.claude/`) are listed: it is what git
  says.
- `Geex.Layout` gains the left column: a quarter of the width, 20 to 36 columns, none below 60.
  It is shown at start from 100 columns once the root is known, and `tree` toggles it. The editor
  renders at its own width and moves right (`Geex.Screen.translate_x/2`). The edits pane sits
  under the editor, beside the tree.
- `Alt+O` cycles the panes on screen: tree · editor · edits. In the tree, arrows or `Alt+W`/`Alt+S`
  move; Enter opens a file (focus goes back to the editor) or opens/closes a directory;
  Right/Left open/close one; Esc goes back. The files are re-read when the tree is shown or
  takes focus.
- **Fixed from step 3** (the coordinator's live test of `8e041a6`): `Alt+M` or `Alt+P` with the
  edits pane focused crashed `Geex.Loop` (no `apply_action/4` clause for the openers). The
  supervisor restarted it, so focus, scrolls and the selection were lost and the next keys went
  to the buffer. Both panels now open them through the editor's own branches.
- **Also fixed:** `Geex.Attest.Discovery` traps exits, so its start-up sweep's `kill -0` ports
  each sent it an `EXIT` with no matching clause, logged as an error whenever stale discovery
  files existed. That predates ADR-0034; it surfaced in this step's dogfood log.

### Built: step 5, "edited by you" (2026-10-15)

- The payload adds `"user_modified": true` when Claude Code's `tool_response.userModified` is
  true, and nothing otherwise, so every other message is byte-identical to before. The intake
  takes `user_modified` as an optional boolean (anything else is refused).
- `Geex.Attest.who/1` builds the agent's actor for the buffer, the edits list and the spool's
  chain: `user_modified: true` is added only when set, so an unedited write's actor is exactly
  as before. A chain is marked if you edited any of its writes. The ledger codec keeps the key,
  so a reopen keeps it.
- The status line reads `✎ claude-code/7ccbf3d1 · turn b60e… · edited by you`, and the edits row
  reads `claude-code/7ccbf3d1, edited by you`.
- **Tree, from the coordinator's live test of step 4:** Left on a file (or a closed directory)
  goes up to the directory it is in, so a long open directory is two keys from closed. Its
  report of an unhighlighted first row turned out to be a `tmux capture-pane -e` artifact: it
  omits a background equal to the end of the line above, which there was the editor's
  current-line tint. With the editor's cursor elsewhere, the row's highlight is emitted.
- **Not live with a real prompt:** this session's Claude Code runs without permission prompts,
  so `userModified: true` was posted by hand. The field path is the one the coordinator found
  in real `toolUseResult` records (always `false` in the captured fixtures).

### Amended 2026-10-16: no cap, and the tree is read in the background

The coordinator's live test of `a64fb05` found that the cap cut the list without saying so, and on the
git path too. Git lists untracked files last, so in a big repository they were the ones dropped. The
maintainer's call: no cap; if a root is too big, let it fail rather than cut it. Measured first, a
root that big didn't fail, it hung: opened in the home directory (937,594 files, not a repository),
the loop read it for 60 s (18 s warm) before drawing, and again whenever the tree took focus, and each
directory open or close rebuilt the rows from every file (14 s).

- **No cap** on either path.
- **Read in a process of its own.** The loop starts a reader (`spawn_monitor`, not linked) when the
  tree is first drawn, shown or focused, one at a time. The rows shown stay until its
  `{:geex_tree, pid, index}` arrives; until the first one, the tree says "reading…". An answer from
  any other process is ignored. If the reader dies first, the loop logs it, says "the file tree
  couldn't be read", and doesn't try again until the tree is shown or focused.
- **In parallel inside the reader.** The walk lists a level of directories at a time, one process
  each (`Task.async_stream`). The git path drops deleted files in batches of 500, in parallel.
  `Geex.Tree.index/1` builds the directories' index, one process per top-level directory.
- **The rows come from the index** (`Geex.Tree.rows/2` takes it, not the file list), visiting only
  the open directories, so opening or closing one costs what is shown.
- **Measured** on the home directory, warm: walk 8.0 s (18 s one at a time), sort 1.5 s, index
  4.1 s (8.5 s in one process). Live, the editor took keys 0.8 s after launch and the tree filled at
  17 s; a directory opened or closed in about 60 ms; the VM held about 500 MB. The geex repository's
  tree still shows within a second of launch.

### Amended 2026-10-18: the tree follows files coming and going

The maintainer, watching an agent add `NOTICE` and `README.md` to geex with `geex .` open, saw
neither appear: the tree was read again only on `Alt+O` or `Alt+T`. Relayed by the coordinator
session.

- **`Geex.Tree.Watcher`**, started with the loop, watches the directories each read found:
  the root, each that holds a listed file, and each one's immediate subdirectories but
  dot-directories. **Not recursive**, so an ignored tree (`_build/`, `deps/`, `.git/`,
  `node_modules/`) is never descended into; its top directory is watched, so a new directory
  beside the files is seen when it is made, and its files from the next read on. The reader
  process hands the directories over (`Geex.Tree.Watcher.watch/4`), so the loop never touches
  the file list.
- **What counts:** a create, delete or move in those directories. A file's edits don't. The
  first event of a burst sends the loop `{:geex_tree_changed, root}` 150 ms later, once. The loop
  reads the files again in the background, as on `Alt+T`; a change during a read reads once more
  after it. The highlight stays on its row's file when rows come or go above it.
- **The watch** is one `:file_system` worker (`inotifywait`, no `-r`) over every directory.
  When the set changes, a new worker starts before the old one stops. A worker that stops (a
  directory gone before `inotifywait` started) asks for a read, which restarts it; after two
  stops in a row with no event between, it waits for the next read. Without `inotify-tools`
  it logs once and the tree is read on `Alt+O`/`Alt+T` as before.
- **Big roots:** past 4096 directories, only the root and its own subdirectories are watched.
  The home directory of the 2026-10-16 measurement stays usable; new files deeper down show on
  `Alt+O`.
- **Reconcile's watch is no longer recursive either.** It watched each open file's directory
  with `inotifywait -r`, so a file at the root put the whole tree, `_build/` and `.git/`
  included, under inotify. Each open file's directory has its own watch, so recursion added
  only noise.
- **A directory made is watched at once, with what's under it.** On a create or move-in of a
  directory, the watcher adds it and every directory below it that isn't a dot-directory or
  ignored by git (`git check-ignore`, level by level, so an ignored subtree is never walked).
  They stay watched while they exist, even empty. The coordinator's live check of the first
  version found the gap this closes: `mkdir -p e1/e2`, then a file in `e1/e2` a second later,
  never showed, because a read lists no file in an empty directory, so `e1/e2` was never
  watched. Agents do exactly this (`mkdir -p` in a shell, a `Write` later).

## Consequences

- An open buffer changes only when you ask: on a fast-forward, on a save, or by your own editing. For
  open buffers, this replaces ADR-0017's adopt-on-every-event and ADR-0032 step b's disk-wins merge.
- Saving never silently overwrites a change made on disk: the save merges first, and a conflicting
  merge doesn't write.
- Attribution is slightly coarser while a buffer is held (§1).
- The frozen MCP surface reads the buffer, so an MCP client sees the held text until a fast-forward.
  Agents that edit natively read the disk and aren't affected.
- geex calls git at runtime (the merge and the tree's file list). Both still work without git.
- The hold needs no payload change. The payload's comment will list `held` as not taken. The optional
  `user_modified` (§8) is a payload and intake change within message `v: 1`.
- Memory stays bounded: 500 edit rows, and 256 held attestations per buffer.

**Build order:**

1. The hold, fast-forward, the git merge, save-while-behind, and "behind disk" on the status line.
   This needs no panes, and the coordinator will live-test it.
2. Panes and buffers: `Geex.Layout`, `Alt+O`, `open`, `buffers`, `close`.
3. The edits pane.
4. The file tree.
5. `user_modified`.

## Decisions for the maintainer

Already decided in the coordinator session (2026-10-15):

- drop follow;
- a plain tree;
- edits pane rows with file · who · when;
- hold even clean buffers;
- selecting the row fast-forwards;
- save-while-behind ships with the hold;
- git merge-file markers, where a conflicting merge doesn't write;
- Enter now, mouse later.

Open, then taken as recommended on 2026-10-15. For J, the maintainer asked whether the no-git
fallback should write git-style markers from `Merge.plan/3`. It isn't worth a second marker
writer, so the fallback stays the existing merge.

| | Question | Decision | Alternatives |
|---|---|---|---|
| A | Layout | **Tree left · editor right · edits pane under the editor**; shown when there's room, toggled with `tree` / `edits` | Three columns: tree · editor · edits; panels only on demand |
| F | Which edits the pane lists | **Agent writes to files under the tree's root (the git top level of the path you opened), your saves, outside changes to open files, "disk is newer" rows** | Every file the hook reports, machine-wide |
| G | Keys | **`Alt+O` next pane, `Alt+L` fast-forward**; verbs `fast-forward`, `tree`, `edits`, `open`, `buffers`, `close` | Other bindings (free Alt keys: I, J, K, T, Y) |
| H | Writes you edited in the permission prompt (`userModified`) | **Record it and show "edited by you"** | Ignore it |
| I | Saving with conflict markers left | **Refuse and name the line; a second `Ctrl-O` saves anyway** | Save without checking; warn and save |
| J | No git on the machine | **Fall back to geex's own merge (disk wins, one undo away) and log a warning** | Refuse to fast-forward a dirty buffer |
| K | Build order | **The hold first** (it changes the save path; no panes needed) | Panes first |

## See

`lib/geex/reconcile.ex` (`reconcile/2`, the watcher's `on_disk_change/1`); `lib/geex/buffer.ex` (the
`synced` baseline, `attest`, the pending table, `save`); `lib/geex/edit/merge.ex`;
`lib/geex/ledger/spool.ex` (the chain rule); `integrations/captainhook/geex-attest.sh` (what counts
as taken); `lib/geex/view.ex`, `lib/geex/rect.ex`, `lib/geex/session.ex`; `lib/geex/loop.ex`,
`lib/geex/loop/keymap.ex`.
