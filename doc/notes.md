# BEAM Editor — Design Notes

Working notes from theorizing about a programming text editor built on the BEAM (Erlang VM). Captured 2026-05-26.

> **Orientation.** This is the original design-space *exploration* — the why-BEAM
> reasoning, the substrate trade-offs, and the road not taken. It is background, not the
> current spec. For the project's settled identity see [vision.md](vision.md); for the
> AI-layer design see [mcp-ai-integration.md](mcp-ai-integration.md); for the decisions
> these notes led to, see [adr/](adr/). Start at [README.md](README.md). Where this file
> and a later doc disagree, the later doc wins.

---

## Touchstones and the design space

The four editors I'm drawing from each sit at a different corner of the design space:

- **nano** — single tiny C binary, always there over SSH, learnable in 30 seconds.
- **vscode** — Electron + marketplace, approachable for web devs, big.
- **zed** — native Rust binary, GPU-accelerated, CRDT collaboration baked in.
- **emacs** — runtime you live inside, Lisp image, infinitely extensible.

The most interesting axes when picking a design:

- **Distribution model** — single binary vs platform vs runtime you live in.
- **Extension substrate** — single biggest long-term lever on what the editor becomes.
- **UI paradigm** — TUI vs native GPU vs DOM; modal vs modeless; buffer/window vs tabs+panes.
- **Concurrency story** — built-in collab vs bolted-on vs none.

The key question that drives everything else: **what's the one thing the editor refuses to compromise on?** zed picked latency, emacs picked extensibility-as-the-product, vscode picked approachability, nano picked "works everywhere."

My non-negotiable, working version: **never lose work, never wedge, always collaborative.**

---

## Extension substrates explained

### emacs — "the editor is a Lisp image"

Small C core wrapping a huge amount of Emacs Lisp. The C provides primitives (display, file I/O, regex, the elisp interpreter); the rest of the editor — buffers, keybindings, modes, every command — is elisp.

"Image" = a running Lisp environment is a live mutable world of objects. You can redefine anything while it's running. Don't like `save-buffer`? Write a new `defun save-buffer`, evaluate it, and from that instant `Ctrl-S` runs your version. No restart, no plugin reload.

Extensions aren't really extensions — they're just more elisp loaded into the same image, with no API boundary.

**Trade:** god-tier flexibility (magit, org-mode, dired exist because elisp reaches everywhere); extensions can silently break each other; security model is "trust every package."

### vscode — extensions as separate processes

Extensions run in a separate Node.js "extension host" process, talking to the editor via JSON-RPC over a defined `vscode.*` API.

**Trade:** stable and safe; extensions can't reach into editor internals. The API surface is the ceiling — if Microsoft hasn't exposed a method, you can't do that thing. LSP came out of this architecture.

### zed — WASM + a deliberately small API

Extensions compile to WebAssembly (usually Rust). The host loads WASM in a sandbox; only host-exported functions are callable.

**Trade:** safe, fast, but the exposed API is intentionally narrow. Heavy reliance on LSP and treesitter rather than exposing internal ASTs.

### nano — essentially none

`.nanorc` lets you set colors, syntax highlight rules, rebind a few keys. No programming extensibility.

### The pattern

**The substrate is the ceiling on what the editor can become.** emacs's choice is why magit exists *and* why your config sometimes breaks. vscode's choice is why it has 60,000 extensions and also why first-class vim mode took years.

---

## Why BEAM for the editor

### Everything as a process

Maps cleanly to OTP: buffer = gen_server, each LSP client = process, each extension = process, each pane = process. With supervision trees, free crash recovery — a syntax highlighter dies, supervisor restarts it, buffer process never notices. The "editor never wedges" property emacs aspires to and never quite achieves comes for free.

**Cost:** per-keystroke latency means hitting the scheduler several times per character. Probably fine if the render path stays tight and hot state lives in ETS; worth measuring early.

### Immutability

Undo/redo collapses to "keep references to old buffer versions." CRDTs for collab basically want to live on BEAM — most CRDT papers assume actor-model semantics anyway. Yjs and Automerge are reinventing what Erlang gives natively.

**Watch out:** raw strings under immutable semantics are quadratic to edit. Need a real structure — rope of refcounted binaries (BEAM's sub-binary slicing is zero-copy), or piece table in ETS.

### Distribution / collab

"Edit my buffer from your laptop" reduces to `{BufferPid, Node@host} ! {insert, Pos, Text}`. Pair programming, remote dev, language-server-on-bigger-machine — all just "spawn the process on a different node." zed's collaboration story took years and a research team; on BEAM a primitive version is a weekend.

### Security — more than you'd think

1. **Process isolation by default.** A process can't read another's heap. Only messages cross the boundary — an extension can't scribble into your buffer; it has to send a message the buffer process chose to accept.

2. **PIDs as capabilities.** This is the unsung gem. In Erlang you can only message a process if you hold its PID. Don't hand an extension the buffer PID, it literally cannot reach that buffer. Capability-based security, accidentally.

**Leaks:** an extension process can still call `file:read_file/1`, open sockets, spawn arbitrary code. Options:
- Restrict the module list available to extension processes.
- Run extensions on a separate hardened node.
- Run them in `wasmex` (WebAssembly inside BEAM) — Zed-style WASM extensions orchestrated by BEAM processes.

### Hot code reload

BEAM was designed to upgrade telecom switches without dropping calls. Modules can be loaded into a running system; gen_servers pick up new code on their next message. Gets the emacs "redefine the editor without restarting" property, with module-boundary discipline.

### Honest weak spots

- **No native UI story.** wxErlang is creaky; don't run a GPU compositor on the BEAM scheduler. Realistic shapes: Phoenix LiveView for browser, native Rust UI talking to BEAM over a port, or TUI.
- **Per-keystroke latency** (see above).
- **Ecosystem.** No native tree-sitter or LSP clients. JSON-RPC over `Port` to language servers works; you build the tooling layer.

---

## Architecture sketch

Decomposition of an OTP-shaped editor:

```
TerminalIO (gen_server)
  - holds prim_tty state
  - handle_info({port, {:data, bytes}}, st) — parse, publish events
  - handle_info({:resize, r, c}, st) — publish resize
  - handle_call({:write, bytes}, ...) — push to prim_tty:write
  - subscribers register interest, receive {:key, :right} etc.

Editor (gen_server)
  - subscribes to TerminalIO for key events
  - maps keys to commands
  - dispatches to buffer processes
  - tells Renderer when something changed

Renderer (gen_server)
  - owns virtual screen (2D cells)
  - on flush: diff against last screen, emit minimum bytes via TerminalIO

Buffer (gen_server per file)
  - owns text data structure (rope/piece-table)
  - handles edit messages
  - notifies Editor when content changes
```

The terminal is one leaf process. Swap it for a LiveView socket later and only `TerminalIO` changes — the editor, buffers, renderer don't know what frontend they're driving. **Frontends are interchangeable.** This is the single biggest architectural payoff.

### Three languages, one app

- **Elixir** for the editor brain — best ergonomics for OTP, supervisors, gen_servers.
- **Gleam** for the extension API surface — typed boundaries are exactly what you want where extensions plug in; the API is the contract.
- **Erlang** for the rare gnarly hot-path or OTP-internals bits.

Most code stays in Elixir; Gleam earns its keep at the extension boundary.

---

## Frontend options

### Phoenix LiveView (doesn't require Electron)

Easiest to heaviest:

1. **Just open a browser tab.** Editor boots, LiveView serves localhost, `xdg-open` the URL. How Jupyter/Streamlit work. Zero packaging until later.
2. **Tauri** (Rust). Wraps the OS's native webview — WebKit on Mac, WebView2 on Windows, WebKitGTK on Linux. ~10MB binaries vs Electron's ~150MB. "Electron without the regret."
3. **Electron.** Familiar, painful, big. Only worth it for Chromium-specific features an editor doesn't need.
4. **LiveView Native.** Renders templates to native UI (SwiftUI, Jetpack Compose). Interesting but immature, desktop is the weakest target.

For v0 with a LiveView frontend, just open a browser. No wrapper.

### Native (Rust/Zig)

Use a library; don't write a GUI toolkit from scratch.

- **GPUI** — framework Zed built, recently released standalone. Editor-specific GPU text rendering. Highest ceiling, steepest curve.
- **egui** — immediate-mode, simple, Rust. Easiest pixels-on-screen, but not specialized for editing.
- **iced** — Elm-inspired, declarative, Rust.
- **Floem** — newer, Rust, by some ex-Zed folks.
- **Zig** ecosystem is thin; more from scratch.

Communication frontend ↔ BEAM = small protocol over a unix socket or pipe. JSON-RPC over a port works.

---

## Frontend decision: TUI on prim_tty (for v0.1+)

Three reasons that compound:

1. **The grid command differentiator is grid-native.** Coordinate commands map directly onto cells in a terminal. In a LiveView frontend that's pixel-to-cell math; in a TUI it's the native unit.
2. **Works over SSH for free.** Programmer's editor → remote dev, edit-on-the-box, tmux pane workflows. vim and emacs rely on SSH-and-run as the killer property. Tauri + browser + tunneled port is a worse story for the same job.
3. **Solo-developer scope.** TUI = Elixir + escape sequences. LiveView+Tauri = Elixir + HTML/CSS/JS + Tauri build pipeline + webview cross-platform pain. Probably doubles time-to-v0.1.

Plus: keystroke latency is naturally good (no DOM diff roundtrip), Burrito + single binary is well-trodden, tiny footprint, no font/DPI bugs.

**Main tradeoff:** giving up rich UI — image previews, smooth animations, embedded markdown render, anything that wants pixels. Fair trade for a programmer's editor; would not be for a Notion/notebook tool.

**Where LiveView would actually win:** if browser-based real-time collaboration was the *headline* feature (Replit/CodeSandbox shape — "send a link, edit together") rather than "single user edits files locally." That's a meaningfully different product.

**This isn't a permanent fork.** `TerminalIO` is one leaf process. Ship the TUI; if a web frontend ever matters later, add it as a second leaf without touching the brain. The decision is "which frontend to build *first*," not "which frontend forever."

---

## Pharos-mcp reuse

Already built `pharos-mcp` — wraps LSP servers (rust-analyzer, gopls, jdtls, pyright, gleam-lsp, etc.) and exposes navigation, refactors, etc. as MCP tools.

Reusable two ways:
1. MCP client over stdio — editor brain talks to it as a port-driven subprocess.
2. Extract the LSP-management internals as a library.

**Sneaky bonus:** keeping LSP behind MCP gets it twice. Editor brain uses it for normal language features. Future AI features use the same layer. Most editors with AI features build *parallel* paths to LSP for their AI tools (Cursor, Zed AI, Continue) — having one path is cleaner.

---

## Commands as the universal interface (macros + LLM tools)

The most important architectural anchor we've landed on. Three layered insights that compose.

### Macros for plugins — the sharp edge

Elixir macros are **compile-time** transformations. They run during compilation, turn AST into other AST, and then they're gone — compiled code is just regular Elixir/BEAM. So macros help with the **API for defining things**, but not with runtime plugin infrastructure:

- ✅ Surface API for plugin authors — macros make plugin code clean and declarative.
- ❌ Loading plugins at runtime — that's `Code.compile_file/1` / `:code.load_file/1`, not macros.
- ❌ Discovery, hooks, event subscription — regular OTP work.
- ❌ Sandboxing untrusted plugin code — separate problem (process isolation, restricted module list, `wasmex`).

The clean combination: plugins are Elixir files dropped into a directory; the editor compiles them on load (running your macros, registering commands); now they're regular BEAM modules and runtime-callable. Macros made writing the plugin pleasant; the loading mechanism made it dynamic. The two are orthogonal.

**Limitation vs emacs:** Elixir macros are compile-time only. Plugins can *use* your DSL freely, but can't `defmacro` new DSL primitives that retroactively reshape already-compiled code. In emacs you can `defmacro` something and it immediately reshapes the runtime. Not in Elixir. Usually not a real-world problem; worth knowing.

### Macro DSL for commands

```elixir
defmodule Geex.Commands.Copy do
  use Geex.Command

  command :copy do
    arg :range, :coord_range, description: "Source range, e.g. 'a1-g3'"
    arg :name, :atom, default: :default, description: "Clipboard entry name"

    description "Copy a range to the internal clipboard"

    run %{range: range, name: name}, state do
      content = Buffer.get_range(state.buffer, range)
      put_in(state.clipboard[name], content)
    end
  end
end
```

At compile time, the macro generates:

- Registration in a central command table (ETS or aggregated module attribute).
- Argument parser (`:coord_range` knows how to parse `a1-g3`).
- The runner function.
- Help text from the declaration.
- **A JSON schema describing the command's inputs.**

The minibuffer becomes a thin shell: parse user input → look up command in registry → call runner. This is the Ecto / Phoenix / Plug / Ash pattern — the idiomatic way Elixir uses macros.

### Commands as data

Instead of `command :copy` generating a function called directly, have it generate a `%Command.Copy{range: ..., name: ...}` struct **plus** a `run(%Command.Copy{}, state)` runner. The minibuffer parser produces structs; a central dispatcher runs them. You get:

- **Undo for free** — every executed command is a recorded struct; keep a list.
- **Command history / replay** — same.
- **Macro recording** (vim sense) — record a sequence of structs, replay it.
- **Programmatic invocation** — plugins compose commands by building structs without going through the minibuffer.
- **Serialization** — for collaboration, scripting, debugging.

This is the inversion many editors converge on (Sublime, vscode, emacs's `command-execute`): the command isn't the *call*, it's the *value*. Macros generate struct + runner; everything else dispatches values.

### The LLM tool payoff (the killer angle)

Because the macro DSL generates structured metadata (name, args, types, description, JSON schema), exposing the editor's commands as **MCP tools for an LLM is nearly free**:

```elixir
defmodule Geex.MCP do
  def tools do
    Geex.CommandRegistry.all()
    |> Enum.map(fn cmd ->
      %{
        name: cmd.name,
        description: cmd.description,
        input_schema: cmd.json_schema
      }
    end)
  end

  def call_tool(name, params) do
    cmd = Geex.CommandRegistry.lookup(name)
    struct = cmd.parse(params)
    Geex.Dispatch.run(struct)
  end
end
```

**The LLM uses the same commands the user types.** No parallel surface — the human types `copy a1-g3 mybuffer` in the minibuffer, the LLM emits `{tool: "copy", range: "a1-g3", name: "mybuffer"}` over MCP, both flow through the same dispatcher. One vocabulary, one set of capabilities, one source of truth.

Most editors with AI features build a *parallel* path to LSP and a *parallel* path to editor primitives just so the LLM can call them. With macros-generate-schema + commands-as-data, both paths fall out of one declaration. Add a new command → user can type it, plugin can build the struct, LLM can call the MCP tool. All three for the price of one DSL block.

### Pairs with pharos-mcp

This composes with the pharos-mcp insight above:

- **LSP** sits behind MCP (pharos-mcp) — used by editor brain for language features *and* by LLM features.
- **Commands** sit behind a macro DSL → struct dispatcher — used by the minibuffer, by plugins, *and* by LLM tools.

Same shape: one surface, used by humans and LLMs. The editor's full vocabulary is uniformly accessible. This is the architectural through-line worth designing the v0 around.

### General note: leverage Elixir's macros

Repeated theme. Wherever there's boilerplate that wants to be declarative (commands, plugins, keybindings, hooks, schema definitions, event handlers, validation, theme definitions, layout rules, ...) — reach for a macro DSL. The Ecto / Phoenix / Plug / Ash / LiveView family of libraries is built this way; it's the Elixir community's standard answer for "make this concept first-class in the language without paying boilerplate every time."

**What macros are bad for:** dynamic runtime behavior, plugin runtime infrastructure, anything that needs to change after compilation. Don't reach for macros to solve those — that's OTP processes + `Code.compile_file/1` territory.

---

## AI integration layer (the loop)

Extends the commands-as-universal-interface insight. The editor itself becomes an MCP server; LLMs become first-class clients of the same dispatcher the user types into.

### MCP tools vs Skills — different granularity

- **MCP tools** = atomic primitives. One tool per macro-generated command. `editor.copy`, `editor.find`, `editor.paste`, `editor.goto_coord`. Auto-generated from the macro DSL → essentially free.
- **Skills** = workflows on top of tools. Markdown documents describing higher-level capabilities that compose atomic tools.

A skill is a recipe, not a tool:

```markdown
---
name: extract-function
description: Extract highlighted code into a new function
---
1. Use `editor.read_selection` to capture the selected range.
2. Use `pharos.find_references` to verify it's an extractable scope.
3. Use `editor.insert_at` to place the new function above current.
4. Use `editor.replace_selection` with a call site.
```

Editor would expose:
- The atomic command surface as **MCP tools** (auto-generated from the macro DSL).
- A `.editor/skills/` directory of markdown files for higher-level workflows.

Both load into the LLM's context when the editor's MCP server is connected. Atomic tools give the model precise control; skills give it pre-baked workflows for common patterns.

### The editor IS an MCP server

Not "has an MCP layer" — IS one. Any LLM (external claude-code, an internal extension, a remote agent over network) connects to the editor as an MCP client and gets:

- The full editor vocabulary (every command as a tool, with schema and description, generated from the same macro declarations the minibuffer parses).
- Pharos-mcp's LSP tools (forwarded or proxied).
- Editor-defined skills (workflows).
- Resources: open buffers, project files, current cursor/selection state.

### Embedded CLI in a pane — two shapes, sharp gotcha

Two different features that get conflated:

**(a) Generic embedded terminal** — "run any CLI in this pane." vim's `:term`, emacs's `term-mode`, vscode's integrated terminal. **This is writing a terminal emulator inside a terminal.** You spawn a process via a pty (BEAM doesn't ship pty support — use `erlexec`), capture its byte stream, parse the escape sequences *it* emits as if you were a real terminal, render its virtual screen as a component, forward keystrokes back. vim's `:term` and emacs's `term-mode` both do this and both have rough edges (running vim *inside* `:term` is famously cursed). **Multi-week project on its own.**

**(b) Programmatic AI integration** — talk to Claude Code (or whatever) via its JSON streaming API; render the conversation as a *native component* in a pane. No terminal emulation. The pane is custom UI: messages, tool calls, diffs, all under your control. This is what Cursor, Zed AI, Continue all do. Much less work, much better UX.

**For the AI use case, (b) is the right path.** (a) is a separate, optional feature for general shell access — and if you have tmux/zellij, you arguably never need it.

### The architectural loop (the payoff)

When the editor exposes its commands as MCP tools **and** an LLM lives in a pane talking to that same editor, you get a tight closed loop:

1. User asks "rename this function across the codebase."
2. LLM uses `pharos.find_references` (LSP via pharos-mcp) to find call sites.
3. LLM uses the editor's MCP tools — `editor.replace_range`, `editor.goto_coord` — to apply edits.
4. Edits flow through the **same dispatcher** the user's minibuffer commands flow through.
5. They land in the **same undo history**.
6. The user sees them happen live in the buffer.

**The LLM is just another typist at the minibuffer.** Its actions are structurally indistinguishable from the user's.

### Why this differs from Cursor / Zed AI

Most editors with AI features build a *parallel* write path: the LLM gets a separate file-modification API, bypassing the editor's own command system. Result: AI edits don't naturally land in undo, don't replay, don't integrate with collab.

Here, because commands-as-data + macros-generate-schema means **the LLM uses the same commands the user types**, you get for free:

- **Undo works** for AI edits — they're recorded structs in the same history.
- **Replay works** — record an LLM session, replay it deterministically.
- **Collab works** — if the editor supports collab (distributed Erlang), the AI is just another participant.
- **Auditability** — every AI action is a recorded struct with arguments.

This is the architectural through-line of the whole project: **one vocabulary, one dispatcher, one history, used by humans and LLMs identically.** It falls out of the macro DSL + commands-as-data design choice. Without that, you're building parallel paths.

### Sequencing

Not for v0.1. The AI integration layer makes sense after:
- The command system exists and has settled.
- The MCP-tool-export from macros is implemented.
- A pane system exists (need somewhere to render the AI conversation component).

So roughly v0.5+ territory — once the editor itself works, then bolt the AI loop on top. But **design the command system with this destination in mind** — that's the part that has to happen early, because retrofitting commands-as-data later is painful.

---

## TTY fundamentals (refresher)

**TTY = teletypewriter.** Historically the literal hardware. Unix was designed in this era; every interactive Unix program is, at the bottom, talking to a TTY.

**What you actually use today is a terminal emulator** — software pretending to be a VT100. iTerm2, Alacritty, Windows Terminal, GNOME Terminal, the VS Code integrated terminal, phone SSH clients — all emulators. They draw the pixels.

### The terminal emulator draws pixels, not your program

Your program writes bytes to stdout. Bytes flow through the OS to the terminal emulator, which decides what to do:

- Most bytes are characters: byte 65 → look up "A" in font → draw "A".
- A few are commands: `0x0A` newline → move cursor down, etc.
- `0x1B` (ESC) starts an *escape sequence* — next several bytes are an instruction:
  - `\e[31m` — red
  - `\e[2J` — clear screen
  - `\e[10;20H` — move cursor to row 10, col 20

That's the entire terminal protocol: text in, with embedded commands.

### TTY APIs give you interactivity, not visuals

You don't need TTY APIs to see characters. `IO.puts/1` works. What TTY APIs get you:

**Cooked mode (default):** kernel line-buffers input; you only see lines after Enter. Handles backspace, Ctrl-C, echo automatically. Great for `cat`; useless for an editor.

**Raw mode (TTY API):** every keystroke arrives immediately, byte by byte. No echo unless you write it. Ctrl-C is just byte `0x03`.

Plus: ask terminal its size, detect resize, query capabilities, restore cleanly on exit.

**Without TTY APIs you can:** print characters, print colored characters (write escape codes), move cursor, clear screen, build a progress bar with `\r`.

**Without TTY APIs you cannot:** read individual keystrokes, capture arrow/F-keys, disable echo, know terminal size, react to resize.

### Input ≠ output

Two independent streams. User presses Right Arrow → terminal sends you `\e[C` → you parse → you update buffer/cursor state → you write *different* bytes back (move cursor, redraw region). Input bytes and output bytes are usually not the same. Mentally separate **input parsing** from **output rendering**. They share a terminal but are otherwise independent.

### `isatty()` matters

If someone pipes or redirects your program, stdout isn't a terminal. Editors check `isatty()` on startup and refuse to run — otherwise they'd vomit escape sequences into a file.

---

## TUI landscape on BEAM (honest verdicts)

- **Ratatouille** (Elixir) — closest equivalent to ratatui/bubbletea. Elm-architecture. Built on `ex_termbox`. Maintained quietly, not getting bubbletea-level attention. First thing to reach for.
- **ex_termbox** — NIF wrapper around termbox2 C library. Lower-level than Ratatouille. Handles the painful part: parsing terminal escape sequences into clean key events.
- **Owl** — terminal *output* helpers (boxes, tables, progress bars). Not a TUI framework. Wrong tool for an editor.
- **cecho** — Erlang ncurses binding (Mazen Harake). 155 stars, last push April 2024, BSD-2. Stable but old-shape — exposes C-style global-state ncurses model, fights everything good about Erlang.
- **wxErlang** — wxWidgets binding, ships with OTP. Powers `observer`. Has `wxStyledTextCtrl` (Scintilla) which is a real editor widget, BUT Scintilla owns its own buffer in C++ — defeats the buffer-as-OTP-process architecture. OK for tool windows, wrong for the editor itself.
- **Raw `:io` + `IO.ANSI` + raw mode** — direct ANSI escape codes, write the terminal layer yourself. The standard library is genuinely enough.
- **`prim_tty`** — OTP 26+ internal terminal primitive. Modern. Undocumented but usable.

### Verdict

For an editor: the widget-tree abstractions of ratatui-style libraries are sized for dashboards, not editors. vim/kakoune/helix/nano don't use TUI frameworks — they write directly to the terminal because an editor's screen model is custom.

Path: use **`ex_termbox` or `prim_tty` for input parsing + raw mode plumbing** (the gnarly part on any platform), and write own rendering. Ratatouille is a fine v0 to prove the architecture, then drop a layer.

---

## ncurses, in one paragraph

ncurses = "new curses." C library for building text-mode UIs in terminals. Origin in late-1970s BSD `curses`, renamed in 1993, maintained by Thomas Dickey since 1996. Abstracts terminal differences via the **terminfo** database, provides cursor positioning, double-buffered screen updates (it computes minimum escape sequences to make real terminal match virtual screen — that's what stops flicker), input parsing, modes. Used by vim, less, htop, top, tmux, screen, mc, mutt. Old in style: C API, global state, awkward color, Unicode bolted on as `ncursesw`, poor threading. Modern alternatives (termbox, crossterm, notcurses) skip terminfo and write escape sequences directly.

---

## prim_tty in particular

The lower-level terminal primitive added in OTP 26 (May 2023) as part of a shell rewrite. NIF-backed. Handles raw mode/cooked mode switching properly on Linux/macOS/BSD/Windows (including Windows ConPTY). Cross-platform without external dependencies.

**Surface (verify against `lib/kernel/src/prim_tty.erl` source — it's undocumented):**
- `prim_tty:init/1` — set up
- `prim_tty:read/...` — pull bytes
- `prim_tty:write/2` — push bytes
- `prim_tty:handles/1` — file descriptors
- Operations for window-size queries and mode changes

The `prim_` prefix is OTP's convention for "internal, may change." In practice it's stable enough; people use it directly because there's no higher-level public API for raw terminal control. Track the source rather than docs.

**What it does:** raw mode setup, low-level byte I/O, window size, resize delivery (as a message), bracketed paste, terminal capability detection (own minimal terminfo).

**What it does NOT do:** parse escape sequences, double-buffered rendering, widget trees. All on you.

---

## Layers above prim_tty (the component architecture)

`prim_tty` is the bottom of a layer cake. Everything visual lives in layers built above it. Bottom to top:

| Layer | What it does | Shape |
|---|---|---|
| 0. `prim_tty` | OS bridge: bytes in/out, mode, size, resize | NIF + port |
| 1. Input parser | Bytes → key/mouse/resize events; buffers partial escape sequences; UTF-8 decode | Pure functions over a bytestring accumulator |
| 2. Virtual screen | 2D cell grid `{char, fg, bg, attrs}`; primitives like `set_cell`, `draw_text`, `fill_rect` | Pure data + pure functions |
| 3. Renderer | Diffs next screen vs current, emits minimum escape sequences via `prim_tty:write` | gen_server |
| 4. Layout | Rectangles + splits (horizontal/vertical/grid) + constraint solving | Pure functions |
| 5. Components | Reusable visual elements (Box, Tabs, Tree, MiniBuffer, ...) | Mostly pure render functions over (props, rect, screen) |
| 6. State (backend) | Buffers, history, project, LSP clients, key bindings, config | OTP processes |
| 7. Controllers | Map key events → commands → state mutations; publish change events | gen_server / message dispatch |

### Components — the "look" layer

Each component:
- Knows its preferred size.
- Has `render(state, rect, screen) → screen` that draws itself into a rectangle on the virtual screen.
- Optionally receives input events.

Style is configurable: border characters, color palette, padding, nerd-font icon toggle.

**Component library a real editor would ship:**

- `Box` — bordered panel using `╭ ╮ ╰ ╯ │ ─`, `┌ ┐ └ ┘ │ ─`, `╔ ╗ ╚ ╝ ═ ║`, etc. Optional title in top edge.
- `StatusBar` — single-line strip with left/center/right zones.
- `Tabs` — horizontal tab strip with active highlight.
- `MiniBuffer` — single-line input at bottom with prompt, cursor, completion list.
- `ListView` / `Tree` — scrollable list / collapsible tree (file tree builds on this).
- `BufferView` — actual text-editing region with line numbers, scroll, cursor, syntax-styled cells.
- `Modal` / `Popup` — floating box with simulated shadow (offset dim cells).
- `Toast` — transient notification.

These can be coherent Elixir libraries — others would use them for unrelated TUIs (CLIs, dashboards, REPLs). Parallels: textual (Python), ratatui (Rust), bubbletea (Go).

**Sketch:**

```elixir
defmodule Components.Box do
  defstruct title: nil, style: :rounded, fg: nil, bg: nil

  def render(%__MODULE__{} = box, %Rect{x: x, y: y, w: w, h: h}, screen) do
    {tl, tr, bl, br, hl, vl} =
      case box.style do
        :rounded -> {"╭", "╮", "╰", "╯", "─", "│"}
        :square  -> {"┌", "┐", "└", "┘", "─", "│"}
        :double  -> {"╔", "╗", "╚", "╝", "═", "║"}
      end

    screen
    |> Screen.set_cell(x, y, tl)
    |> Screen.set_cell(x + w - 1, y, tr)
    |> Screen.set_cell(x, y + h - 1, bl)
    |> Screen.set_cell(x + w - 1, y + h - 1, br)
    |> draw_horizontal(x + 1, y, w - 2, hl)
    |> draw_horizontal(x + 1, y + h - 1, w - 2, hl)
    |> draw_vertical(x, y + 1, h - 2, vl)
    |> draw_vertical(x + w - 1, y + 1, h - 2, vl)
    |> maybe_draw_title(box.title, x, y, w)
  end
end
```

Stateless. Same shape as React/Elm components, just rendering into a cell grid instead of a DOM.

### Backend pieces (no direct visual representation)

OTP processes with supervisors. Expose message APIs. Publish change events.

- **Buffer processes** — one per file. Own text data structure (rope, piece table, or list of binary lines for v0).
- **File watcher** — detects external changes.
- **LSP clients** — one process per language server, talking to pharos.
- **Project state** — cwd, git status, recent files, gitignore.
- **History / undo** — per-buffer operation log or immutable snapshots.
- **Search / index** — fuzzy finder data; ripgrep-shelled or in-process.
- **Key binding tables** — current mode + mapping.
- **Configuration** — loaded once, hot-reloadable.
- **Extension runtime** — if/when added.
- **Collaboration / CRDT** — if/when.

### The split, in OTP terms

```
backend (state, processes)        frontend (rendering, mostly pure)
─────────────────────────         ─────────────────────────────────
Buffer processes        ─events→  BufferView component
TreeState process       ─events→  Tree component
LSP clients             ─events→  Diagnostics / hints
ProjectState            ─events→  StatusBar
                                  ↓
                                  Layout
                                  Virtual screen
                                  Renderer
                                  ↓
                                  prim_tty:write
                                  ↑ (input direction)
                                  Input parser
                                  ↑
                                  prim_tty (port messages)
```

Interface is messages. When a buffer changes, it publishes `{:buffer_changed, id, change}`. Renderer subscribes to whatever components are visible and re-runs their render functions with new state.

Components are mostly stateless functions of (props, state, rect) → screen. State lives in backend processes; components receive snapshots and render. Visual layer is testable in pure Elixir without any terminal involved — assert against the resulting cell grid in tests.

**This is the elm-architecture / React-with-Redux pattern, mapped onto OTP processes.** Pure rendering at the top, stateful messages at the bottom, message-based interface between.

### What you ship — suggested library decomposition

One application, logically a few libraries:

- `terminal_io` — `prim_tty` wrapper + input parser. **Reusable.**
- `screen` — virtual screen + renderer. **Reusable.**
- `layout` — rectangle splits + constraint solver. **Reusable.**
- `components` — the widget library. **Reusable.**
- `editor_core` — buffer, history, commands, keybindings. Editor-specific.
- `editor_app` — the wiring; glues the others together.

First four are publishable as standalone hex packages. Real ecosystem contribution alongside the editor itself.

---

## Concrete example — raw mode editor loop

### Stty-shellout version (works on Unix)

```elixir
defmodule TinyTui do
  def run do
    :os.cmd(~c"stty raw -echo")
    IO.write(["\e[?1049h", "\e[?25l", "\e[2J"])

    try do
      loop(%{row: 12, col: 40})
    after
      IO.write(["\e[?25h", "\e[?1049l"])
      :os.cmd(~c"stty sane")
    end
  end

  defp loop(state) do
    render(state)
    case read_key() do
      :quit  -> :ok
      :up    -> loop(%{state | row: max(1, state.row - 1)})
      :down  -> loop(%{state | row: state.row + 1})
      :left  -> loop(%{state | col: max(1, state.col - 1)})
      :right -> loop(%{state | col: state.col + 1})
      _      -> loop(state)
    end
  end

  defp read_key do
    case IO.binread(:stdio, 1) do
      "q" -> :quit
      "\e" ->
        case IO.binread(:stdio, 1) do
          "[" ->
            case IO.binread(:stdio, 1) do
              "A" -> :up
              "B" -> :down
              "C" -> :right
              "D" -> :left
              _   -> :unknown
            end
          _ -> :esc
        end
      other -> {:char, other}
    end
  end

  defp render(%{row: r, col: c}) do
    IO.write([
      "\e[2J", "\e[1;1H",
      "Move with arrows, q to quit",
      "\e[#{r};#{c}H", "*"
    ])
  end
end

TinyTui.run()
```

Run with `elixir tiny_tui.exs` (not iex — iex owns stdin).

### prim_tty version (illustrative — verify against OTP source)

```elixir
defmodule TinyTui do
  def run do
    {:ok, tty} =
      :prim_tty.init(%{tty: true, input: true, output: true, canon: false})

    :prim_tty.write(tty, ["\e[?1049h", "\e[?25l", "\e[2J"])

    try do
      loop(tty, %{row: 12, col: 40}, _esc_buf = "")
    after
      :prim_tty.write(tty, ["\e[?25h", "\e[?1049l"])
      :prim_tty.close(tty)
    end
  end

  defp loop(tty, state, esc_buf) do
    render(tty, state)

    receive do
      {_port, {:data, bytes}} ->
        {events, new_buf} = parse(esc_buf <> bytes, [])
        case apply_events(events, state) do
          :quit -> :ok
          new_state -> loop(tty, new_state, new_buf)
        end

      {:resize, _rows, _cols} ->
        loop(tty, state, esc_buf)
    end
  end

  defp parse("", acc),                  do: {Enum.reverse(acc), ""}
  defp parse("q" <> r, acc),            do: parse(r, [:quit | acc])
  defp parse("\e[A" <> r, acc),         do: parse(r, [:up | acc])
  defp parse("\e[B" <> r, acc),         do: parse(r, [:down | acc])
  defp parse("\e[C" <> r, acc),         do: parse(r, [:right | acc])
  defp parse("\e[D" <> r, acc),         do: parse(r, [:left | acc])
  defp parse("\e" <> _ = p, acc) when byte_size(p) < 3,
    do: {Enum.reverse(acc), p}
  defp parse(<<_, r::binary>>, acc),    do: parse(r, acc)

  defp apply_events([], s),             do: s
  defp apply_events([:quit | _], _),    do: :quit
  defp apply_events([:up    | r], s),   do: apply_events(r, %{s | row: max(1, s.row - 1)})
  defp apply_events([:down  | r], s),   do: apply_events(r, %{s | row: s.row + 1})
  defp apply_events([:left  | r], s),   do: apply_events(r, %{s | col: max(1, s.col - 1)})
  defp apply_events([:right | r], s),   do: apply_events(r, %{s | col: s.col + 1})

  defp render(tty, %{row: r, col: c}) do
    :prim_tty.write(tty, [
      "\e[2J", "\e[1;1H",
      "Move with arrows, q to quit",
      "\e[#{r};#{c}H", "*"
    ])
  end
end
```

### Key differences

- **No shellout.** `prim_tty:init/1` handles raw mode + Windows ConPTY.
- **Message-driven input.** No blocking `IO.binread` — bytes arrive as messages in the mailbox. Fits OTP `receive` naturally; keystrokes are "just another message" alongside `{:save, file}` etc.
- **Buffered escape parsing.** Bytes arrive in arbitrary chunks (might be `"q\e[Ahello"` or just `"\e["` with `A` in the next message). Parser keeps `esc_buf` of unparsed leftover.
- **Resize is a message.** Just another `receive` clause.
- **Windows works.** stty version is Unix-only.

### Trace: user presses Right Arrow

1. Terminal emulator translates keypress to bytes `\e[C` (27, 91, 67).
2. Bytes travel through the pty into your program's stdin.
3. Because we're in raw mode, kernel doesn't buffer or echo.
4. Parser reads `\e`, then `[`, then `C` → emits `:right`.
5. Loop updates `state.col`.
6. Render writes output bytes: clear, move-cursor, status text, move-to-new-position, `*`.
7. Terminal emulator interprets, redraws.
8. Loop blocks waiting for the next bytes.

**That's the full input → parse → state → render cycle.** Everything else is more elaborate versions of these four steps.

### What the toy skips

- **Diff rendering.** Real editors keep a virtual screen, diff vs previous, emit only changed regions. The toy clears and redraws every frame.
- **ESC timeout.** Parser blocks waiting after `\e` — would hang on Escape alone. Real parsers use ~50ms timeout.
- **More keys.** F-keys, modifier combos, mouse, bracketed paste.
- **UTF-8.** `é` is two bytes — treated as separate keys here.
- **Process structure.** In the real editor, decompose into `TerminalIO`, parser, buffer, renderer.

---

## Sizing

Honest estimates, focused work, solid on Elixir:

- **v0.1 (single buffer, basic movement, grid commands):** ~1-2 weeks.
- **Full described scope (multi-pane + file tree + grid):** ~3-5 weeks.
- **Add 1-2 weeks** if learning OTP idioms or terminal-control along the way.

| Layer | Tiny version | Notes |
|---|---|---|
| Terminal plumbing | 3-5 days | Don't get sucked into the parser long-tail. |
| Buffer + text model | 3-4 days | `:array` of binary lines is fine for v0. Resist rope/piece-table. |
| Pane/split system | 3-5 days | Layout tree of splits — consistently underestimated. |
| File tree | 3-5 days | Recursive read + collapsible render + open-file. |
| Grid command system | 3-5 days | The differentiator. Ship in v0.1. |
| Minibuffer | 1-2 days | Captures grid commands. |

---

## Phased plan

- **v0.1 (1-2 wk):** single buffer, prim_tty + virtual-screen renderer + escape parser + minibuffer + grid commands. Goal: validate grid feel.
- **v0.2 (+1 wk):** multiple buffers + buffer-switch via minibuffer.
- **v0.3 (+1-2 wk):** pane splits + real file tree pane.
- **v0.4 (+1 wk):** Burrito packaging.

### v0.1 explicit non-goals (scope discipline)

- No undo/redo (add later; immutable snapshots make it nearly free).
- No syntax highlighting.
- No LSP / pharos wiring.
- No search.
- No mouse.
- No config file.
- No themes.

Editors are the most notorious scope-creep projects in software. Every step reveals five "must-have" features. Discipline is **defining what v0.1 doesn't include in writing, and refusing it.**

---

## Grid command system (the differentiator)

> **The coordinate model is now settled in [ADR-0027](adr/0027-grid-command-addressing.md).**
> Short version: notation is **numeric `x5 y7`** (letters dropped — they only return as
> easy-motion *jump labels*, not coordinates); the canonical axis is **grapheme-`x` +
> logical-line-`y` with display width excluded** (a width bug can mis-render but never
> mis-address); absolute vs viewport is a **sigil**, not a notation change; mutating
> commands **bake the resolved span before recording** (replay-safety). The original sketch
> below is kept for the brainstorm trail; the open questions are answered there.

Emacs-style minibuffer where the user types coordinates and the cursor jumps / selection happens.

Examples (original sketch — superseded by ADR-0027's numeric form):
- `a1` — jump cursor to a1
- `a1-g6` — select linear range from a1 to g6
- `a1:g6` — select rectangular block (spreadsheet convention)
- `a1-g6,b3-h8` — multiple selections (multi-cursor / non-contiguous)

### Open design questions

1. **Coordinates: viewport-relative or buffer-absolute?**
   - Viewport-relative: `a1` is top-left of currently visible region. Best for "jump to that thing I see." Vim-easymotion-style.
   - Buffer-absolute: `a1` is line 1, col 1 of file. Best for scripting / muscle memory.
   - Probably support both, sigil-distinguished (e.g. `:a1` vs `a1`).

2. **Columns past 26?**
   - Spreadsheet style: `a..z`, `aa..zz`, `aaa..` — unwieldy.
   - Two-character base-26: always two letters, `aa..zz` covers 676. Uniform but verbose.
   - **Cleanest: viewport-relative, relabel on scroll.** Only need 26.

3. **Linear vs block ranges**
   - Both are useful — different operations.
   - Suggested: `a1-g6` linear, `a1:g6` block. Paralleling spreadsheets.

4. **Syntax grammar**
   - Push toward `-` for ranges, `,` for lists, `:` for blocks.
   - `a1-g6,b3-h8` (two linear selections) easier to parse and read aloud than space-separated.
   - **Pin the grammar on paper before parser code.**

5. **Pane targeting** — commands can be prefixed with `:N/` where `N` is a pane number to target a specific pane (`:1/copy a1-g3`, `:2/paste`). Without a prefix the command targets the active pane. Numeric prefixes (over named or positional like `:left/`) chosen for terseness and stability — pane numbers don't change as splits resize.

### Render

When grid mode is triggered, optionally overlay coordinate labels on visible region (easy-motion-style). Toggle off after the command runs.

---

## Potential names

Candidates (no decision yet):

- **a1** — references the grid command system directly; top-left coordinate as a nod to the spreadsheet-style addressing.
- **steak**
- **cake** — could be read as a nod to the layer cake architecture (prim_tty up through components), if a meaning is wanted.

---

## Open questions still to resolve

- Text data structure: list of binary lines for v0; rope vs piece table later?
- Undo: immutable snapshots (cheap given BEAM) vs explicit operation log?
- Minibuffer command grammar beyond grid: command palette? vim-style ex commands? — **the shell model is settled in [ADR-0028](adr/0028-editor-shell-and-minibuffer.md)** (minibuffer = the command surface, modal: grid / search / palette / fuzzy finder; opened by `Alt+M`; command palette *instead of* a menu bar; no small file cap; tabs + file tree deferred behind the pane system).
- Config: file-based, code-based (like xmonad/emacs), or runtime commands?
- Theme/color: 256-color, true color, or both detected?
- Extension API design: pin much later, not v0.1.
- Eventually: pharos-mcp integration shape (MCP-client over stdio vs extracted library).
- **Persistence:** a durable store *outside* ERTS? (crash recovery / session restore / a durable command-log audit) — see "Persistence & durable state".
- **Agent integration:** adopt ACP (bring-your-own-agent) alongside the MCP-connect model? — see "Agent integration".
- **Scroll bars** (vertical + horizontal, when applicable) — see "Scroll bars".

---

## Persistence & durable state (open question)

Everything geex holds lives in **ERTS memory**: the buffers, each buffer's undo history,
and the recorded command stream. A crash or restart loses all of it — the files on disk are
the only durable truth today (the disk-truth stance, [ADR-0010](adr/0010-disk-truth-lsp-v05.md)
/ [ADR-0017](adr/0017-reconcile-file-watch.md)).

Question: **does geex need a persistent store *outside* ERTS?** What it would buy —
**crash recovery / session restore** (reopen the buffers, cursors, scroll you had); **durable
undo** across restarts (today history is ephemeral by design,
[ADR-0014](adr/0014-editor-state-and-dispatch-ownership.md)); an **audit log** of every
command (provenance is already on every command, [ADR-0005](adr/0005-provenance-on-every-command.md);
persisting the stream makes "who changed what, when" durable).

The natural thing to persist is **the command stream itself**: commands are serializable
values ([ADR-0002](adr/0002-commands-as-values.md) + the neutral field-spec
[ADR-0004](adr/0004-neutral-field-spec.md)), and the §15c cassette already serializes recorded
command lists and replays them via `Dispatch.replay/2`. So a durable store = an **append-only
command log (event-sourcing)**, replayable into state — *not* a snapshot blob. Candidate
backends (no decision): a plain file (the cassette format extended), `:dets`, SQLite
(`exqlite` / `ecto_sqlite3`), `CubDB`, or `mnesia`. This is the same axis as the existing
"undo: immutable snapshots vs operation log" question — a *persisted* operation log **is**
event-sourcing. Decide before v1; it touches the buffer/history model and the replay contract.

---

## Agent integration: MCP-connect vs ACP (bring-your-own-agent)

geex already speaks **MCP two ways**: as a **server** (an external harness — Claude Code,
Codex — connects in over loopback HTTP to drive edits, [ADR-0018](adr/0018-mcp-transport-streamable-http.md))
and as a **client** (it consumes capability providers like pharos LSP,
[ADR-0021](adr/0021-capability-connections.md)).

**ACP — the Agent Client Protocol** (open-source/Apache, by Zed;
[zed.dev/blog/bring-your-own-agent-to-zed](https://zed.dev/blog/bring-your-own-agent-to-zed))
— is a *different axis*. It's "LSP for coding agents": the **editor is the client**, the
**agent runs as a subprocess**, they speak a **minimal set of JSON-RPC endpoints**, and the
editor renders the agent's responses. The editor provides edit visualization, multi-buffer
review, syntax highlighting, LSP, and tool/MCP access-control; the agent provides the
reasoning. Zed ships it with **Gemini CLI** (reference) and **Claude Code** (beta); nothing
routes through Zed's servers. (Note: it's "Agent **Client** Protocol", not "agent context
protocol".)

These are the **two directions of "bring your own brain"** (geex owns the world, not the
brain — [ADR-0007](adr/0007-world-not-brain.md)):

- **MCP-connect (have):** *I'm in Claude Code; my edits flow OUT to geex.* geex is the world a
  foreign harness reaches into.
- **ACP-host (consider):** *I'm in geex; I summon an agent INTO a geex panel.* geex hosts the
  agent's UI and runs it as a supervised subprocess.

For an LLM-native editor the **in-editor agent panel is arguably the native experience**, and
ACP-host is how you get it without writing an agent. Open questions before adopting:

- Does geex become an **ACP client/host** — a third protocol seam alongside MCP-server and
  MCP-client?
- How does ACP's edit/permission/diff flow map onto **the one shared command path** +
  **provenance** ([ADR-0003](adr/0003-one-shared-path.md) / [ADR-0005](adr/0005-provenance-on-every-command.md))?
  An ACP agent's edits should still land as `%Command{}` on the spine, tagged with agent
  provenance — the same discipline as the MCP path, so reconcile/replay/undo all still hold.
- Where does the **enforcement ladder** ([ADR-0016](adr/0016-external-harness-integration.md))
  sit for an agent geex itself launches (vs one that connects in)?
- ACP is **stdio/subprocess**; geex's MCP transport is **connect-to-running HTTP**
  ([ADR-0018](adr/0018-mcp-transport-streamable-http.md)) — a different lifecycle (geex
  *spawns + supervises* the agent vs the harness spawning geex).

### Port DeepSeek Moby as an ACP agent

Moby (DeepSeek) already informed geex once — the `edit` tool ports **Moby's tiered
search/replace matcher** ([ADR-0020](adr/0020-diff-edit-tool.md)). Next idea: **port Moby to
an ACP agent** (today a VS Code extension, `~/deepseek-vscode-extension`). An ACP agent runs
**unchanged in both Zed (BYO-agent) and geex** if geex speaks ACP-host — one agent, two
editors. That makes Moby the **named first consumer** justifying ACP-host in geex (the
named-consumer rule, vision §3), and gives geex a first-party in-editor agent.

---

## Scroll bars (vertical + horizontal)

Show a scroll bar when content overflows the viewport, on each axis independently:

- **Vertical** — a thumb in the **rightmost column**, length/offset proportional to `scroll` /
  total line count. Reserve one column on the right (another inset, like the gutter on the left).
- **Horizontal** — a thumb proportional to `hscroll` / longest-visible-line width, tucked with
  the status row (or a reserved row above it).

They're **chrome like the gutter and status line** — each reserves space from the text rect, so
they ride the same viewport-region math (left inset = gutter, right inset = vertical bar, bottom
row = status + horizontal bar). The vertical bar reserves the rightmost **column only when the
buffer overflows** (line count is stable, so no flicker); the horizontal bar reserves a **row above
the status line permanently** (decided 2026-06-08 — horizontal overflow toggles as you scroll, so a
permanent row avoids reflow), drawing into it only when a visible line overflows. The thumbs track
the **viewport** (scroll / hscroll), not the cursor, and move proportionally — on a long file the
vertical thumb shifts ~1 row per N lines scrolled, so small cursor moves won't visibly move it.

### Driving them — keybindings + mouse (follow-ups, not built)

- **Scroll keybindings** belong in the keymap ([ADR-0026](adr/0026-terminal-input-model.md)): vertical
  (PageUp/PageDown, half-page, line-scroll à la `Ctrl-E`/`Ctrl-Y`, jump-to-top/bottom) **and**
  horizontal (scroll-left/right, jump-to-line-start/end). Today only arrow-key cursor motion scrolls
  the view indirectly (via `scrolloff`); there are no view-scroll commands yet.
- **Mouse** is not implemented at all, so the scroll bars **cannot be dragged or clicked** yet. A mouse
  layer (SGR mouse mode `\e[?1006h`, parsed in `Geex.Input.Parser`) would enable: drag the thumb to
  scroll, click the trough to page, click text to position the cursor, wheel to scroll. Mouse reuses the
  same `scrollbar_thumb`/region math in reverse (pixel/cell → scroll offset). A real slice of its own.
