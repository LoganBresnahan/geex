---
name: dogfood
description: Drive the real geex where mix test structurally cannot reach — the interactive TUI through a tmux pty (type keys, read the rendered grid and cursor back), the loopback MCP server through a live JSON-RPC handshake from an external client, and (pending) a real Claude Code honoring the preset. Covers the launch flags and why each exists, the isolated tmux socket that keeps your own sessions safe, the scratch-file sandbox, and logging the result to testing.md's verification log. Use after any change a human or an agent would see.
---

# /dogfood — drive the real geex

`mix test` asserts against **values** (buffer text, history, `Screen` cells) and
never boots a terminal or a listener — `start_terminal`, `start_reconcile` and
`start_highlight` are all off under test. Everything about how geex behaves
with a real pty, real key bytes, a real resize, or a real HTTP client is only
observable here. Every live bug the project has had (the `{cols, rows}` width
swap, swallowed quit keys, log splatter, both flicker bugs) was caught this
way, not by the suite.

## Three rules before running anything

**1. Never touch real files.** Point geex at a scratch copy in the session
scratchpad (or `mktemp -d`), never at a repo file you care about — the TUI
and the MCP tools both *save*. `SB` below is that sandbox.

**2. Never use the default tmux server.** The user may have their own tmux
sessions; `tmux kill-server` on the default socket kills them all. Every tmux
command here uses a **private socket**: `tmux -L geexdf …`. Kill only that.

**3. `pkill -f` matches its own shell.** The agent's Bash wrapper carries the
whole command text in its argv, so `pkill -f "mix geex.serve"` — or even
`pkill -f 'beam.smp.*geex.serve'` — matches the calling shell and kills it
(exit 144). Use the bracket trick, whose regex can't match its own text:
`pkill -f '[b]eam.smp.*geex.serve'`.

```sh
SB=$(mktemp -d)                       # or the session scratchpad
printf 'hello world\nx中yz hello\n' > "$SB/t.txt"   # include a wide glyph — width bugs hide on ASCII
```

## Handle 1 — the TUI through a tmux pty

The loop needs raw-mode `:prim_tty`, which an agent shell lacks ("not a tty");
tmux supplies the pty. The launcher bakes `PATH` in (asdf shims) and the flags:

```sh
cat > "$SB/launch.sh" <<EOF
export PATH="$PATH"
cd /home/oof/geex
exec elixir --erl "-noshell -noinput +Bd" -S mix run --no-start -e 'Geex.run("$SB/t.txt")'
EOF
tmux -L geexdf new-session -d -s g -x 100 -y 30 "bash $SB/launch.sh"
# wait for first paint (compile may run first) — poll, don't sleep blind
for i in $(seq 1 60); do tmux -L geexdf capture-pane -t g -p | grep -q hello && break; sleep 0.5; done
```

Why each flag (don't "simplify" them away):

| flag | why |
| --- | --- |
| `-noshell -noinput` | keep the Erlang shell off stdin so `:prim_tty` owns the terminal |
| `+Bd` | disable the BREAK handler — an outside SIGINT ends the VM instead of opening the BEAM's `BREAK:` menu on the terminal geex owns (`sigint` isn't trappable). Ctrl-C itself sends no SIGINT: `TerminalIO` runs `stty -isig -ixon`, so it reaches the keymap (BUG-3) |
| `--no-start` | `Geex.run/1` redirects `Logger` to `<tmp>/geex.log` *before* the app boots; started early, the inotify warning paints over the alt-screen and the sparse cell-diff never clears it |

Drive and observe:

```sh
tmux -L geexdf send-keys -t g "text"          # literal typing
tmux -L geexdf send-keys -t g Enter BSpace Left  # named keys
tmux -L geexdf send-keys -t g M-m             # Alt+<key> (minibuffer); M-p palette, M-g grid, M-h highlight
tmux -L geexdf capture-pane -t g -p           # the rendered grid as text — READ it
tmux -L geexdf capture-pane -t g -p -e        # with SGR colour (truecolor 38;2;r;g;b / 48;2;…)
tmux -L geexdf display-message -t g -p '#{cursor_x},#{cursor_y}'   # the hardware cursor, 0-based
tmux -L geexdf resize-window -t g -x 60 -y 15 # SIGWINCH path
tail -20 "$(elixir -e 'IO.write System.tmp_dir!()')/geex.log"      # what Logger said
```

Quit and clean up — **Ctrl-X** (Ctrl-Q and Ctrl-C quit too; Ctrl-Z and Ctrl-S do
nothing). It does not save; `Ctrl-O` saves first if the pass needs disk.

```sh
tmux -L geexdf send-keys -t g C-x; sleep 1
tmux -L geexdf kill-server 2>/dev/null        # the PRIVATE server only
```

What to look for, in order: **the cursor** (does `cursor_x,y` sit where the
status bar's `line:col` says — remember the gutter offsets x), **colour
alignment** after an edit (byte-offset spans misalign past the edit point — the
BUG-2 shape), **wide glyphs** (`中` owns two columns; nothing may split it),
**chrome** (status bar, scroll bars, ruler/grid overlay clear on exit), **the
log** (no crash reports). A finding fixed in the same slice; one deferred goes
to `doc/bugs.md` with its verified cause.

## Handle 2 — the MCP server over loopback

`dogfood == production` (ADR-0018): an external client speaks the real wire to
a real `mix geex.serve`. Auto-port + a port file, so nothing collides with 4000:

```sh
(GEEX_MCP_PORT_FILE="$SB/url" setsid mix geex.serve > "$SB/serve.log" 2>&1 &)
for i in $(seq 1 60); do [ -s "$SB/url" ] && break; sleep 0.5; done
U=$(cat "$SB/url")                    # the FULL url, e.g. http://127.0.0.1:19841/mcp — not a bare port
c(){ curl -s -m 5 -X POST "$U" -H 'content-type: application/json' -d "$1"; echo; }

c '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"dogfood","version":"0"}}}'
curl -s -m 5 -o /dev/null -w '%{http_code}\n' -X POST "$U" -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'          # expect 202
c '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -oE '"name":"[a-z_]+"'
c "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"open_file\",\"arguments\":{\"path\":\"$SB/t.txt\"}}}"
# …then the tool under test: insert / replace / edit / line / goto / copy / save_file …

pkill -f '[b]eam.smp.*geex.serve'   # SIGTERM = graceful init:stop, ~2s — poll before declaring it gone
for i in $(seq 1 10); do pgrep -f '[b]eam.smp.*geex.serve' >/dev/null || break; sleep 0.5; done
```

Always pass `curl -m` — a wrong URL otherwise hangs the shell until the tool
timeout. Expected `tools/list` (as of ADR-0027's grid-agent amendment): the
four edit tools, six operation tools, `line`, `goto`, `copy` — a missing
category means `Protocol.tools_list` lost a union.

Proving **provenance** needs the in-process history (the wire only returns
text): run the same edits through `Geex.MCP.Protocol.handle_line/1` (a raw JSON-RPC line in) in an
`iex -S mix` / `mix run -e` script and read `Geex.Buffer.history/1` — every
MCP edit is `meta.actor: {:llm, "unknown"}` until per-connection identity lands.

The **security** checks are cheap; run them when `http.ex` moved:

```sh
curl -s -m 5 -o /dev/null -w '%{http_code}\n' -X POST "$U" -H 'origin: http://localhost.evil.com' -H 'content-type: application/json' -d '{}'   # 403
curl -s -m 5 -o /dev/null -w '%{http_code}\n' "$U"                                                                                         # 405 (GET)
```

## Handle 3 — a real harness honoring the preset (frozen by ADR-0032)

Presets are frozen: this is no longer on the roadmap. Kept for whoever un-freezes
the door. The ledger-track equivalent (an agent editing natively, with the
captAInHook payload attesting each write) gets its own handle when the attestation
intake lands.

The original pending proof: **Claude Code itself**, honoring
`presets/claude-code/` (`.mcp.json` → geex + `permissions.deny` on the
structured writers), routes an edit through geex. curl (Handle 2) proves the
wire, not that the harness obeys the preset — don't conflate them.

Shape: `mix geex.serve --port 4000` → copy `presets/claude-code/.` into a
**scratch project dir** (never geex's own root — it would deny *this*
session's writers) → run `claude` there, approve the project MCP server once,
ask for an edit → confirm the edit landed in geex's history (not straight to
disk) and that a denied `Write`/`Edit` was refused. Needs a human at the
approval prompt; propose it, don't fake it.

## Choosing a handle

| Change touched | Minimum handle |
| --- | --- |
| keymap, verbs, minibuffer, palette, grid, paint, chrome | 1 |
| renderer / `TerminalIO` / input parser / resize | 1, incl. `resize-window` and a wide glyph |
| highlight reactor / theme | 1 with `-e` (read the SGR) after an edit mid-line |
| an MCP tool or category, `Protocol`, `Schema` | 2 |
| `http.ex`, `port.ex`, `runtime.exs` serve gate | 2 + the security checks |
| presets | 2, then propose 3 |
| a shared-path change (agent edit visible to the human) | 2 *while* 1 is open on the same file — watch the agent's edit repaint |

## Log it

A pass that found the thing working is still a result. Append a dated entry to
`doc/testing.md` § Verification log (append-only — never edit past entries):
what was driven, what was seen, the test count, and an explicit **Not tested**
list. That entry is what `/shipshape`'s docs gate and `/orient` look for.

## Report

```
DOGFOOD — geex @ <sha>
  handle      <1 TUI | 2 MCP | 3 harness> — <why that one>
  sandbox     <SB path> · private tmux socket geexdf · serve <url>
  verified    <what was driven → what was seen, one line each>
  failures    <symptom — suspected layer (loop/paint/renderer/protocol/transport)>
  not tested  <what this pass did not reach>
  logged      testing.md entry <added | proposed>
```
