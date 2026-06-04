# MCP & AI Integration — Design Notes

Design notes for geex's AI integration layer: how an LLM drives the editor,
how the editor drives an LLM, and the transport/security model underneath.
Captured 2026-05-28.

Fed by a deep read of [`pharos-mcp`](https://github.com/LoganBresnahan/pharos-mcp)
(a production Gleam/BEAM MCP server by the same author) and a survey of
[Jido](https://github.com/agentjido/jido), [`balance_beam`](../../balance_beam)
("Ecto for LLMs"), [`instructor_ex`](https://github.com/thmsmlr/instructor_ex),
and distributed-Erlang RPC.

This extends — does not replace — the "Commands as the universal interface"
and "AI integration layer" sections of [notes.md](notes.md). Read those first;
this document makes the decisions those sections deferred.

> **Status:** design-locked, unimplemented. The AI loop is v0.5+ territory
> (see notes.md sequencing). The *command system* it sits on must be designed
> now, because retrofitting commands-as-data later is painful. This doc exists
> so the command DSL is built with its destination in mind.

---

## 0. The four locked decisions

Everything below elaborates these. Stated up front so the rest can reference them.

1. **The command macro emits a serialization-neutral field-spec**, not
   JSON-Schema directly. Renderers project that spec to JSON-Schema (MCP), the
   minibuffer parser, and the argument validator. One source, no drift.
2. **All four transport layers are specified**; v0.5 *ships* layers 1–2 (in-VM
   dispatch + stdio MCP). Layers 3–4 (distributed Erlang, HTTP/WS+TLS) are
   documented as the target architecture, gated on a named consumer + security
   model.
3. **Direction B (geex-calls-LLM) is backed by `balance_beam`** — which *owns* the
   schema→reask structured-output technique on a thin transport (`req_llm`/`Req`);
   **`instructor_ex` is dropped**. Wrapped behind a thin `Geex.AI` editor-glue
   boundary. balance_beam is BYO/external, driven by its own consumer; geex adopts a
   thin slice when Direction B lands (§6, §13, [adr/0011](adr/0011-direction-b-balance-beam.md)).
4. **Every command carries provenance metadata** (`actor`, timestamp,
   prompt-hash) from the start. The LLM is just another typist; its keystrokes
   carry a name tag.

---

## 0.5 What geex is (and is not)

See [vision.md](vision.md) for the north star. In one line: **geex owns the editor
*world* — buffers, the one shared command path, undo/replay/collab/provenance — and
the *brain* (agent orchestration, planning, context, cost) is bring-your-own.** Every
party (human, LLM, extension, remote peer) is just a typist whose input becomes a
`%Command{}` through the one dispatcher. That boundary is the test for every decision
below ([adr/0007](adr/0007-world-not-brain.md)).

---

## 1. The core idea: the Operation

The single most important realization from the research. Four projects
independently arrived at the same object:

| Project | Calls it | Shape |
|---|---|---|
| **geex** | Command | struct + `run(struct, state)` + generated schema |
| **Jido** | Action | struct + NimbleOptions schema + `run/2` |
| **balance_beam** | typed LLM operation | schema drives prompt + validation + types |
| **instructor_ex** | Ecto schema | embedded_schema + changeset + derived JSON-Schema |

They are four views of one abstraction — a **typed, schema-bearing, runnable
operation**:

```
Operation = {
  name,
  param-schema,     # what inputs it accepts (typed, documented)
  runner,           # how it executes against editor state
  metadata          # description, help text, provenance
}
```

That Jido and instructor_ex converged on the same shape is strong external
validation that geex's commands-as-data bet is correct — we are not inventing,
we are recognizing a pattern the ecosystem already found.

### Five projections from one definition

geex defines the Operation **once** (the macro DSL block) and *derives* every
surface, rather than maintaining parallel definitions:

```
                         ┌─ (1) minibuffer parser:  "copy a1-g3" → %Command.Copy{}
                         │
                         ├─ (2) MCP tool export:    schema → JSON-Schema inputSchema
   %Command.Copy ────────┤                          (LLM-calls-geex / Direction A)
   (one macro block)     │
                         ├─ (3) inbound arg validation: JSON args → %Command.Copy{}
                         │                          (reuses the SAME parser as #1)
                         │
                         ├─ (4) in-editor LLM result typing: schema → response_format
                         │                          (geex-calls-LLM / Direction B)
                         │
                         └─ (5) undo/replay/collab/provenance:
                                Operations are values — record and re-run them
```

The minibuffer (human) and the MCP arg-decoder (LLM) call **the same parser**
and run **the same dispatcher**, landing in **the same undo history**. That is
the one-vocabulary payoff from notes.md, made concrete.

### The trap: two schema *roles*, not one

The decisive subtlety. There are two different schemas and conflating them is
the mistake:

- **Param schema** — a command's *inputs*. Owned by the macro. Shared by the
  minibuffer (#1) and MCP tool export + validation (#2, #3).
- **Result schema** — an in-editor AI feature's *output*. Owned by the
  `instructor_ex`/Ecto layer (#4). Per-feature, not per-command.

> **One abstraction (the Operation), two schema roles (params vs result).**
> Inputs are macro-generated and shared by minibuffer + MCP; outputs are
> per-AI-feature and belong to the Direction-B layer. Keep them separate.

---

## 2. The two directions of the AI loop

The AI loop is **two distinct problems** with different machinery. Most of the
confusion in editor-AI design comes from treating them as one.

### Direction A — LLM-calls-geex

An external LLM (claude-code) or an in-pane agent drives the editor.

- **Mechanism:** the ported pharos-style MCP server (§4). Each macro-defined
  command auto-exports as an MCP tool. Inbound tool-call arguments are validated
  into a `%Command{}` and run through the **same dispatcher + undo history** as
  human minibuffer input.
- **Status:** the v0.5 headline deliverable.
- **Payoff:** "an LLM edits my buffer" with undo, replay, collab, and audit all
  free — because the LLM uses the same vocabulary the human types.

### Direction B — geex-calls-LLM

In-editor AI features: explain-this, rename-suggestion, commit-message,
structured refactors.

- **Mechanism:** an `instructor_ex`-style structured-output layer (§6). Define
  the desired result as a schema; the model returns JSON validated/coerced into
  a struct, with automatic re-ask on validation failure. `balance_beam`'s design
  is the architectural frame (supervised, schema-driven, provenance-tracked).
- **Status:** spec'd here; built after Direction A.

### The composition rule (load-bearing)

> When a Direction-B feature decides to **mutate the buffer**, it must emit
> `%Command{}` structs and run them through the Direction-A dispatcher — **never
> write to buffers directly.**

This is the whole game. It's why AI edits land in undo/replay/collab exactly
like human and external-LLM edits. The moment a feature bypasses the dispatcher
to "just edit the file," the one-history property breaks and you're back to the
parallel-path architecture (Cursor/Zed AI) that notes.md is built to avoid.

```
  Direction B (geex-calls-LLM)              Direction A (LLM-calls-geex)
  ───────────────────────────               ────────────────────────────
  in-editor AI feature
    → instructor_ex (typed result)
    → decides on edits
    → emits %Command{} structs ───────────→ Geex.Dispatch.run/1
                                              → Buffer process
                                              → undo history (tagged :llm)
```

---

## 3. Transport: four layers

Every transport is an **adapter over the same pure dispatcher**. The dispatcher
(`Geex.Dispatch.run(%Command{})`) does not know or care which transport a
command arrived on. Add a transport only when a named consumer exists.

| Layer | Transport | Consumer | When | Security |
|---|---|---|---|---|
| **1** | In-VM direct dispatch | minibuffer, in-pane AI, Gleam extension, co-located pharos | **now (free)** | process isolation; PID-as-capability |
| **2** | stdio JSON-RPC (MCP) | Mode-1 headless tool; **CI / conformance harness** | **v0.5 (CI)** | local process, inherits user's trust |
| **3** | Distributed Erlang (`:erpc`) | remote BEAM agents, multi-node collab | later | **capability/auth gate required** |
| **4** | HTTP (Streamable HTTP, MCP) | **external harness attaches to the running geex (Mode 2)**; browser/remote later | **v0.5 (loopback)** / remote later | loopback-bind + `Origin` (TLS+auth when remote) |

> **Transport choice for harnesses — [adr/0018](adr/0018-mcp-transport-streamable-http.md):**
> production = a harness *connects* to the long-running geex, so the v0.5 dogfood/production
> transport is **loopback Streamable HTTP (Layer 4)**, *not* stdio. stdio (Layer 2) is
> demoted to a hermetic CI/conformance harness. Both are adapters over the same pure
> dispatcher — a transport-ordering change, not a spine change.

### Layer 1 — in-VM direct dispatch (the privileged path)

Any BEAM-resident caller reaches the command system by calling
`Geex.Dispatch.run(%Command{})` directly — no serialization, no protocol. This
is free and already covers co-located AI panes and extensions.

**This is why geex does not need pharos's planned WebSocket editor-bridge.**
pharos must build a WebSocket+TLS+per-language-plugin stack (`pharos-vscode`,
`pharos-neovim`, …) so that *out-of-VM* editors can push buffer/cursor/selection
state into pharos. geex is a **first-party BEAM editor** — it delivers that same
state as native Erlang messages to a co-located pharos's LSP pool. We want the
bridge's *semantic contract*, not its transport (§8).

### Layer 2 — stdio JSON-RPC (the CI / conformance harness)

A single-process, newline-delimited JSON-RPC server exposing commands as MCP
tools. Port pharos's pure `handle_line/1` seam and its stdout-cleanliness
discipline (§4, §7). This is **Mode 1** — the harness *spawns* a throwaway
headless geex (§15b); useful as a hermetic CI/conformance + cassette-replay
harness, **but it is not the production path** (it never attaches to the running
editor's live session). Live dogfood uses Layer 4 — see
[adr/0018](adr/0018-mcp-transport-streamable-http.md).

### Layer 3 — distributed Erlang (collab / remote agents)

For trusted multi-node editing and BEAM-resident remote agents, expose the
**dispatcher** (not raw buffer PIDs) over `:erpc` to nodes that pass a capability
check. Free in OTP, but distributed Erlang's trust model is all-or-nothing: a
connected node can run arbitrary code via `:rpc`. **Must** sit behind an
auth/capability boundary before exposure. See §9.

The notes.md collab primitive — `{BufferPid, Node@host} ! {insert, Pos, Text}` —
works literally, but route it through `Geex.Dispatch` on the remote node so it
inherits undo/provenance, rather than messaging buffer PIDs raw.

### Layer 4 — HTTP (MCP Streamable HTTP)

**The v0.5 harness transport (loopback).** This is **Mode 2** — the harness
*connects* to the long-running geex, so edits land in the live session with
provenance ([adr/0018](adr/0018-mcp-transport-streamable-http.md)). It is a clean
adapter over the same pure core (`handle_line/1`), served from a `Bandit`+`Plug`
child (geex's first dependency — "own the technique, rent the transport",
[adr/0011](adr/0011-direction-b-balance-beam.md)). v0.5 scope is **loopback only**
(bind `127.0.0.1`, validate `Origin`, no auth); remote exposure, WS, TLS, and
multi-client are deferred to when a browser/remote-collab consumer exists. The
enforced-sandbox rung ([adr/0016](adr/0016-external-harness-integration.md))
requires exactly this connect transport (geex outside the sandbox, harness
connects in over loopback).

> **The dual axis (§14):** these four layers are *inbound* — who reaches geex's
> dispatcher. geex is also an MCP *client* that connects **outbound** to
> independently-shipped MCP servers (pharos and others) to consume capabilities.
> That outbound axis, plus the WASM and native extension tiers, is §14.

---

## 4. The MCP server (Direction A) — module shape

Written in **Elixir** (§5 argues why), under `lib/geex/mcp/`, slotting into the
existing `Geex.Application` tree alongside `TerminalIO`/`Renderer`/`Session`/
`BufferSupervisor`. Ported 1:1 from pharos's architecture, translated to OTP.

```
lib/geex/mcp/
  protocol.ex     # PURE. the heart. handle_line/1 → {:reply|:noreply|:protocol_error}
  dispatch.ex     # method routing: initialize / tools/list / tools/call / ping
  stdio.ex        # GenServer: owns the stdin port (input side)
  writer.ex       # GenServer: single-writer frame funnel (output side)
  supervisor.ex   # feature-gated subtree
```

### `Geex.MCP.Protocol` — the pure core

The single highest-value thing to port from pharos: **the protocol logic is a
pure function**, unit-testable with plain strings.

```elixir
@spec handle_line(String.t()) ::
        {:reply, iodata()} | :noreply | {:protocol_error, iodata()}
def handle_line(line) do
  case JSON.decode(line) do                          # built-in, Elixir 1.18
    {:error, _} ->
      {:protocol_error, error_frame(nil, -32700, "Parse error")}

    {:ok, msg} ->
      if Map.has_key?(msg, "id"),                     # request vs notification
        do: dispatch_request(msg),                    # → {:reply, _}
        else: dispatch_notification(msg)              # → :noreply
  end
end
```

Three outcomes, all load-bearing JSON-RPC truths:
- `{:reply, json}` — a request; write this frame back.
- `:noreply` — a notification (no `id`); notifications **never** get a response.
- `{:protocol_error, json}` — malformed input still needs an error frame (with
  `id: null` when no id could be recovered).

### `Geex.MCP.Dispatch` — method routing

```elixir
defp dispatch_request(%{"id" => id, "method" => method} = msg) do
  result =
    case method do
      "initialize"  -> initialize_result(msg["params"])   # negotiate version
      "tools/list"  -> tools_list()
      "tools/call"  -> tool_call(msg["params"])
      "ping"        -> %{}                                 # pharos OMITS this — don't
      other         -> {:error, -32601, "Method not found: #{other}"}
    end
  encode_reply(id, result)
end
```

`tools/list` and `tools/call` are the notes.md sketch, now grounded:

```elixir
def tools_list do
  %{tools:
      Enum.map(Geex.CommandRegistry.all(), fn cmd ->
        %{name: cmd.name, description: cmd.description, inputSchema: cmd.json_schema}
      end)}
end

def tool_call(%{"name" => name, "arguments" => args}) do
  case Geex.CommandRegistry.lookup(name) do
    nil -> {:error, -32602, "Unknown tool: #{name}"}
    cmd ->
      case cmd.parse(args) do                 # ← the SAME parser the minibuffer uses
        {:error, why}   -> {:error, -32602, "Invalid params: #{why}"}
        {:ok, struct}   ->
          struct = put_provenance(struct, :llm)        # §7
          result = Geex.Dispatch.run(struct)           # ← the SAME dispatcher humans hit
          %{content: [%{type: "text", text: render(result)}], isError: failed?(result)}
      end
  end
end
```

### How a `%Command{}` becomes a tool (the macro seam)

The crux of the "nearly free" claim. The `Geex.Command` macro
([notes.md lines 220–246](notes.md)) already plans to emit struct + runner +
help + schema. Per **Decision 1**, each `arg` declaration generates, from one
source, a *neutral field-spec* entry (§3 below), from which we render:

1. a JSON-Schema property (for MCP `inputSchema`),
2. a clause in the generated `parse/1` (for both minibuffer and MCP),
3. the struct field.

```elixir
command :copy do
  arg :range, :coord_range, description: "Source range, e.g. 'a1-g3'"
  arg :name,  :atom, default: :default, description: "Clipboard register name"
  description "Copy a range to the clipboard"
  run %{range: range, name: name}, state do
    Geex.Clipboard.push(name, EditorState.read_range(state, range))
    {:ok, state}   # copy reads the doc; it does not mutate EditorState
  end
end
```

> The runner operates on the buffer's **`EditorState`** ([ADR-0014](adr/0014-editor-state-and-dispatch-ownership.md)),
> not a bare `Doc`. `copy` is the one case that targets the **clipboard subsystem**
> ([ADR-0015](adr/0015-clipboard-subsystem.md)) rather than the document, so it returns
> the state unchanged — its ring push is applied by `Geex.Dispatch.run/1`'s scatter step;
> `cut`/`paste` resolve into *recorded* edits. (`:coord_range` / `:atom` are v0.2 arg
> types; v0.1 ships `:integer` / `:string`.)

**The inversion of pharos's #1 documented bug:** in pharos a tool name appears in
*four* hand-synced places (definition, allow-list, dispatch case, registry
category) and schema/decoder/handler drift silently. In geex the name appears
**once**; registry, schema, parser, and dispatcher all key off the one generated
struct module. They *cannot* drift because they share one source.

### `Geex.MCP.Stdio` and `Geex.MCP.Writer` — the two Port gotchas

The only non-trivial runtime code, both BEAM-knowledge that ports verbatim from
pharos:

- **Stdin** — `Port.open({:fd, 0, 0}, [:binary, :eof, {:line, 65535}])`. The
  `{:fd, 0, 0}` line-mode trick dodges the `:user` group-leader buffering that
  would otherwise stall input under a release.
- **Stdout** — a **single-writer GenServer** (the same role `TerminalIO` already
  plays for `prim_tty`). All frames go through it; it writes each via a raw fd-1
  port (`Port.open({:fd, 1, 1}, [:binary])`, `command`, then close to force a
  synchronous flush).

> **The Burrito gotcha, known up front:** a Burrito-packaged binary with
> `-noshell` buffers stdout until stdin EOF — which would hang `initialize` past
> an MCP host's ~30s timeout. The raw fd-1 close-per-write is the fix. v0.4 ships
> Burrito packaging; knowing this now saves a multi-hour debug session.

### Supervision

Add `Geex.MCP.Supervisor` to `Geex.Application.start/2`, **feature-gated exactly
like the existing `terminal_io_child/0` pattern**
([application.ex:23](../lib/geex/application.ex#L23)):

```elixir
defp mcp_child do
  if Application.get_env(:geex, :start_mcp, false), do: [Geex.MCP.Supervisor], else: []
end
```

It supervises `Writer`, `Stdio`, and (optionally) a `Task.Supervisor` for
per-request dispatchers. Default-off until v0.5. Request cancellation
(`notifications/cancelled`) reuses the existing `Geex.Registry` keyed by JSON-RPC
id; most geex commands are fast synchronous edits, so cancellation is wire-now,
implement-`send_exit`-later (only LSP-fanout commands are slow).

---

## 3a. The neutral intermediate field-spec (Decision 1)

The macro does **not** emit JSON-Schema directly. It emits a plain Elixir term
describing fields, types, docs, and defaults. Renderers project that term to each
consumer.

```elixir
# what `arg :range, :coord_range, description: "..."` contributes to the spec:
%Geex.Command.Field{
  name: :range,
  type: :coord_range,
  required: true,
  default: nil,
  description: "Source range, e.g. 'a1-g3'"
}
```

```
                                  ┌─ JSON-Schema renderer  → MCP inputSchema
  [%Field{}, ...]  (neutral) ─────┤─ parser renderer       → parse/1  (minibuffer + MCP)
                                  ├─ validator renderer    → arg coercion/validation
                                  └─ (future) Gleam extension contract, :erpc spec
```

Type → JSON-Schema mapping lives in **one** table so adding a new arg type is one
edit:

| geex arg type | JSON-Schema | notes |
|---|---|---|
| `:coord_range` | `"string"` | description carries the grammar (`a1-g3`, `a1:g6`) |
| `:atom`, `:string` | `"string"` | |
| `:integer` | `"integer"` | |
| (has `default:`) | — | omitted from `required[]`; default documented in description |

**Why neutral over direct JSON-Schema** (Decision 1 rationale): "define once,
derive many" is the whole thesis. A neutral term keeps the macro independent of
MCP, lets the same spec drive the minibuffer parser *and* a future Gleam
extension contract *and* a distributed-Erlang argument spec, and avoids welding
the command system to JSON-Schema. Cost: one small rendering module. Payoff:
every future surface.

---

## 5. Why Elixir, not Gleam (the decision)

pharos is Gleam — deliberately, because JSON-RPC is a spec and Gleam's decoders
make the envelope type-safe. The natural question: should geex's MCP boundary
also be Gleam, consistent with notes.md's "Gleam for the extension API surface"?

**Decision: write geex's MCP boundary in Elixir.** The deciding argument is the
*location of the source of truth*.

geex's entire value proposition is that **one Elixir macro declaration** generates
the struct, runner, help, registry entry, and schema — and the LLM uses the
**same Elixir dispatcher** (`Geex.Dispatch.run/1`) and the **same `parse/1`** the
human's minibuffer uses, landing in the **same undo history**. The MCP server's
job is almost entirely glue: *take the schema the macro already produced, list
it; take the params, call the same parser, run the same dispatcher.*

That glue sits directly on Elixir data structures (a `%Command{}` struct, a
registry map, a generated schema term). Putting it in Gleam forces a language
boundary across the **one seam where it hurts most**:

- the schema is generated by an Elixir macro at Elixir compile time,
- the registry is an Elixir process/ETS table,
- the dispatcher and undo history are Elixir,
- the commands themselves are Elixir.

A Gleam MCP layer would receive Elixir-generated schemas as opaque dynamic terms,
marshal params back into Elixir, and call Elixir dispatch via FFI —
**re-introducing exactly the untyped boundary Gleam was supposed to remove**, plus
a build-system and ABI seam, all to type-check a ~80-line JSON envelope of ~6
fields.

### What we give up, and how we get it back

Gleam would buy compile-time exhaustiveness on the request/notification split, a
sum type making result-XOR-error unrepresentable, and decode-to-`Result` instead
of crash. We re-acquire these at runtime, cheaply, because the envelope is tiny
and stable:

1. Classify request-vs-notification with an explicit `Map.has_key?(msg, "id")`
   guard; funnel any `JSON.decode` failure to a `-32700`/`-32602` frame via a
   `with` pipeline instead of letting it raise.
2. Write dispatch as a `case` on method with an explicit catch-all `-> -32601`
   (the compiler won't warn on a forgotten method — tests must).
3. Cover the envelope with property tests + typespecs/Dialyzer.

Critically, **the macro recovers most of the safety Gleam's compiler would give**:
the schema, parser, and handler are all *generated from one arg-list*, so geex
structurally *cannot* have pharos's #1 bug (schema/decoder/handler drift). The
interesting typing — the per-command arg shapes — lives on the Elixir side and is
already protected by the macro.

### Where Gleam still earns its keep

Reserve Gleam for the **third-party extension API** (per notes.md). That is a
genuinely different boundary: a typed contract with *external, untrusted* authors,
where the typed boundary *is the product feature*. The MCP server is not that —
it is an internal adapter over geex's own command system.

> A hybrid (Gleam envelope codec, Elixir everything else) is possible but not
> worth it: it adds a Gleam build target + an FFI hop to type-check ~6 fields,
> while the interesting typing lives on the Elixir side already.

---

## 6. Direction B — geex-calls-LLM (via `balance_beam`)

Per **Decision 3**. In-editor AI features that need a *typed result* from a model
(rename-suggestion, commit-message, structured refactor). Narrow, single-shot
features — **not** agent orchestration ([vision.md](vision.md) §3: that's the brain,
which is bring-your-own).

> **Decision (2026-05-28): `instructor_ex` is dropped.** It is quiet (last release
> Feb 2025, last commit Jun 2025) and a near-rewrite successor exists. Rather than
> depend on it, `balance_beam` **owns the structured-output *technique*** — schema →
> JSON-Schema → validate → reask — on a **thin, maintained transport** (`req_llm` /
> `Req` + the few provider APIs we use). "Own the technique, rent the transport": own
> the bounded part, rent the provider-matrix churn that stalls these libraries. See
> §13 and [adr/0011](adr/0011-direction-b-balance-beam.md).

### The flow

```elixir
# 1. define the desired result as a schema — the technique balance_beam owns;
#    Ecto embedded_schema is the shape, balance_beam derives JSON-Schema + reask.
defmodule Geex.AI.RenameSuggestion do
  use BalanceBeam.Schema

  @llm_doc "A suggested identifier rename with rationale."
  embedded_schema do
    field :new_name, :string
    field :rationale, :string
  end

  def validate(cs), do: Ecto.Changeset.validate_format(cs, :new_name, ~r/^[a-z_][a-z0-9_]*$/)
end

# 2. ask; get a validated struct, auto-retried on validation failure
{:ok, %Geex.AI.RenameSuggestion{new_name: n}} =
  Geex.AI.complete(prompt, into: Geex.AI.RenameSuggestion, max_retries: 2)
```

balance_beam derives the JSON-Schema / `response_format` from the schema, calls the
model over a thin transport, validates the result, and re-asks with the validation
errors on failure (the one portable idea worth owning outright).

### A thin `Geex.AI` boundary

`Geex.AI` is editor glue, not a second framework: it wraps `balance_beam` so the
editor never talks to a model adapter directly and the dependency stays swappable.
balance_beam carries the production wedge geex wants:

- **Supervised execution** — model calls are nondeterministic, slow, and fail; the
  BEAM (OTP) *is* supervised execution — balance_beam runs calls under it with
  timeouts/retries, never inline.
- **Provenance** — tag results with which prompt / model produced them; feeds §7's
  `%Command.Meta{}`.
- **Capability / trust boundaries** — buffer contents fed into a prompt are
  *untrusted input* (prompt-injection surface); §9.

**The composition rule still governs (§2):** when a Direction-B feature decides to
mutate the buffer it emits `%Command{}` structs through `Geex.Dispatch.run/1` — never
writing the buffer directly. balance_beam produces the *typed result*; geex turns
that result into *commands*.

### Keep the two schema roles separate

`instructor_ex` schemas (Ecto, **result** role) are a *different system* from
command param schemas (macro, **input** role). Do not try to unify them — that's
the §1 trap. A Direction-B feature *produces* an Ecto-validated result, then (if
it edits) *emits* macro-defined `%Command{}` structs.

---

## 7. Provenance (Decision 4)

Every command carries provenance metadata from the start. One field on the
struct; cheap now, expensive to retrofit.

```elixir
%Command.Insert{
  line: 0,
  col: 4,
  text: "foo do\n  :ok\nend",
  meta: %Geex.Command.Meta{
    actor: {:llm, "claude-opus-4-8"},   # | :human | {:agent, id} | {:extension, id} | :external
    at:    ~U[2026-05-28 18:40:00Z],
    prompt_hash: "ab12…",               # nil for :human
    origin: %{turn_id: "t_7f3a", seq: 2} # links a sequence of commands to one
  }                                      # agent turn; nil for ad-hoc human input (§13)
}
```

`origin` (turn_id + seq) is what makes composite-agent edits revertable as a unit
without a second ledger — see §13 "Provenance for composite commands". It rides on
the value, so it survives remote dispatch (§3 layer 3) exactly as `actor` does.

`:external` tags an edit geex did **not** mediate — an out-of-band disk write reconciled
back into the buffer ([adr/0017](adr/0017-reconcile-file-watch.md)). geex never fabricates
authorship it can't back: a write it didn't see through the door is `:external`, never
`{:llm, _}` or `:human` ([adr/0012](adr/0012-trust-and-enforcement.md)).

A history slice is then self-describing:

```elixir
[%Command.Insert{meta: %{actor: :human}, ...},
 %Command.Insert{meta: %{actor: {:llm, _}}, ...},
 %Command.Delete{meta: %{actor: :human}, ...}]
```

What this unlocks, all called out in notes.md, none of it changing the
"same dispatcher" property:

- **Audit** — every AI action is a recorded struct with arguments and authorship.
- **Selective undo** — "undo the last AI edit" / "revert everything the agent did".
- **Replay analysis** — record an LLM session, replay deterministically, diff.
- **Collab attribution** — distributed-Erlang participants carry identity.
- **Render-time distinction** — `BufferView` can tint LLM-authored cells (a pure
  query against authorship metadata).

> The LLM is still just another typist. Its keystrokes simply carry a name tag.

---

## 8. The editor-state contract (in-VM, not WebSocket)

pharos's v0.3 plan includes a WebSocket "bridge" (ADR-028, *proposed, unbuilt*):
editor plugins push live state (open buffers, cursor, selection, focus) to pharos
so its LSP tools can answer questions disk state can't reach (unsaved edits, "what
is the user looking at?"). It requires a WebSocket server, capability
negotiation, a versioned wire spec, per-language plugins (`pharos-vscode` ~200
LOC, `pharos-neovim` ~150 LOC, …), a conformance harness, and eventually TLS.

**geex needs none of that transport.** As a first-party BEAM editor co-located
with pharos, geex delivers the same state as native Erlang messages /
`GenServer.call`s to pharos's LSP pool processes — no JSON encoding, no WebSocket
frame, no handshake, no TLS, no `pharos-geex` plugin repo. The pool is already a
shared in-VM resource keyed by workspace; geex attaches to the same warm LSP
servers.

**Take the contract, skip the transport.** The set of editor-state messages the
bridge defines is the useful part:

- live document mirroring: `didOpen` / `didChange` / `didSave` / `didClose`
- focus context: active URI + cursor + selection + viewport + open-file list
  (the `editor_focus` shape)
- reverse channel: render-a-WorkspaceEdit-as-diff, diagnostics, progress

Realize these as a native geex ↔ pharos in-VM API. This is also a clean
validation of geex's frontend-agnostic design (notes.md): the "editor state" the
bridge ships over WebSocket is, for geex, just process state already in the VM.

> **Amended (§14): this whole contract assumes co-location.** v0.5 runs pharos as
> an *external* stdio MCP-client child (§14, §13-Q4), which cannot read geex's
> in-VM state — so **v0.5 LSP is disk-truth-only** and this contract is *not built*.
> It is retained as the target end-state, unlocked later by an optional co-location
> transport swap (§3 Layer 1), not by pushing state over the link. See §14 "the
> cost of un-bundling pharos."

---

## 9. Security model

Three boundaries, increasing in exposure.

### Enforcement: who can bypass the door

geex provides the door (the dispatcher) and the ledger (provenance + undo history);
it **cannot** force an external agent through them. claude-code with raw file-write
tools can edit disk directly, bypassing the buffer — those edits get no provenance and
the buffer goes stale. The shared-path guarantee covers edits that *enter through
geex*; it is not imposable on the outside world. Enforcement is a property of the
agent's **capability grant**, in two regimes:

- **Cooperative** (external agent): scope its tools (geex's MCP tools, no raw file
  write) so the door is the only way in. geex's duty is **honest provenance**
  (out-of-band edits are `external`, never fabricated) and **reconcile** (file-watch →
  surface divergence; an escape is *detected*, not silent).
- **Enforced** (in-VM agent / wasmex extension, §14 tiers 2–3): no other door exists —
  the wasmex host surface and PID-as-capability make the path structural.

See [vision.md](vision.md) §5 and [adr/0012](adr/0012-trust-and-enforcement.md).

### In-VM (layers 1–2) — process isolation + PID-as-capability

Inherited free from BEAM (notes.md "Security"). An extension or in-pane agent
can't scribble into a buffer's heap; it must send a message the buffer process
chose to accept. Don't hand an extension a buffer PID and it cannot reach that
buffer. The MCP server runs in the user's own trust domain (a local subprocess
the user launched), so layer 2 adds no new trust boundary beyond "the user ran an
LLM against their editor."

### Distributed Erlang (layer 3) — the dangerous one

Distributed Erlang's trust model is **all-or-nothing**: a connected node can run
arbitrary code via `:rpc`. The shared-cookie auth is not a capability model.
Before exposing the dispatcher over `:erpc`:

- never auto-trust a connected node; require an explicit capability/auth check,
- expose **the dispatcher**, not raw buffer PIDs — preserve the
  PID-as-capability discipline,
- consider hidden nodes + a restricted module allow-list for any
  partially-trusted participant,
- a remote command still flows through `Geex.Dispatch` so it inherits
  undo/provenance/audit.

### Prompt content as untrusted input (Direction B)

`balance_beam` Strategy 10. Buffer contents fed into a prompt are an injection
surface — a file can contain "ignore previous instructions and …". Treat
prompt-embedded buffer text as untrusted: keep it in clearly delimited regions,
never let it escalate the model's tool permissions, and (with provenance)
audit what an AI-driven session actually did.

---

## 10. What we port / adapt / skip from pharos

Condensed from the research.

### Port directly (translate Gleam → Elixir 1:1)

- The pure-core / thin-transport seam (`handle_line/1` → three-outcome result).
- stdout-cleanliness + the two Port gotchas (stdin `{:fd,0,0}` line-mode; fd-1
  close-per-write flush).
- JSON-RPC envelope conventions: id is string-or-int, echoed with original type;
  `-32700` parse / `-32601` method-not-found / `-32602` invalid-params;
  notifications never get a response.
- Tool-result contract: tool outcomes ride a JSON-RPC **success** whose result is
  `{content: [block], isError: bool}`; only protocol faults use the JSON-RPC
  `error` object.
- Supervision shape: root supervisor, `DynamicSupervisor` for per-resource
  children, monitor-not-link, single-writer stdout funnel.

### Adapt

- Tool registry: pharos hand-writes `{name, description, inputSchema}` + a
  parallel decoder + handler per tool. geex *derives* all of it from one macro
  block (§4, §3a).
- `initialize`: **negotiate** `protocolVersion` against the client (don't
  hardcode-and-echo like pharos); advertise `capabilities.tools.listChanged:
  true` and emit `notifications/tools/list_changed` when plugins add commands —
  geex's command set is *dynamic*, pharos's is static.
- Two-stage `tools/call` decode: parse the `{name, arguments}` envelope
  generically, then hand raw `arguments` to the command's generated `parse/1`
  (the same one the minibuffer uses).

### Skip

- All LSP-server machinery (pool, spawn workers, readiness probes, timeouts,
  `lsp_request_raw`). geex *consumes* pharos as a subprocess; it does not front
  language servers.
- HTTP/SSE transport, sessions, `Mcp-Session-Id`, origin validation, port-file
  discovery (until layer 4 has a consumer).
- The `pollux` dependency / "typed JSON-RPC library" hunt — pharos declares
  `pollux` but doesn't actually import it; it hand-rolls the envelope. Elixir 1.18
  ships built-in `JSON`; the envelope is ~80 lines. Adding a framework is
  over-engineering.
- Burrito meta-flags / dual entry points / `--doctor` / config-precedence chain /
  orphan-LSP reaping. geex's MCP server is an in-process subtree, not a separately
  launched binary.

---

## 11. MCP spec compliance checklist

- **Protocol version:** negotiate against the client's requested version; store
  geex's supported versions as a module attribute (echo a supported requested
  version, else fall back to the preferred one). geex implements **`2025-11-25`
  (current/preferred)** and keeps **`2025-06-18`** for back-compat. (`2025-03-26`
  removed JSON-RPC batching, which geex doesn't need; pharos still advertises
  `2024-11-05`.) *Implemented in `Geex.MCP.Protocol`.*
- **Transport (stdio):** newline-delimited JSON (NDJSON), one message per `\n`,
  **no** `Content-Length` framing (that's LSP, not MCP). stdout reserved
  exclusively for frames; all logs to stderr.
- **Message classification:** `id` present → request (gets a response); absent →
  notification (never). Preserve id type on the way out.
- **Methods to implement:** `initialize`, `notifications/initialized` (ack, no
  reply), `tools/list`, `tools/call`, `ping` (return `{}` — pharos omits this and
  returns `-32601`, a compliance gap geex should *not* copy),
  `notifications/cancelled` (no reply; cancel or no-op).
- **Error codes:** `-32700` parse (id null) / `-32600` invalid request / `-32601`
  method not found / `-32602` invalid params / `-32603` internal error. The
  protocol boundary funnels **any handler fault** (a raise, or a dependency process
  being down) to `-32603` so `handle_line/1` never crashes the process running it.
  `error.data` (optional) is not yet emitted.
- **Tool errors vs protocol errors (SEP-1303):** a *found* tool whose **arguments**
  fail validation returns a **tool result with `isError: true`** (the model sees it
  and self-corrects), *not* `-32602`. `-32602` is reserved for an **unknown tool** or
  a **malformed call** (missing/non-string `name`, non-object `arguments`); a tool
  that runs and fails (or crashes — contained via `Dispatch.apply_command/2`) is also
  `isError: true`.
- **Content blocks:** `{content: [block], isError}`; text block is
  `{type: "text", text}`. Model the block as a tagged struct so `image` /
  `resource` can be added later without reshaping the encoder. v0.5 needs text
  only.
- **Capabilities:** advertise a capability **only when geex honors it**. v0.5 ships
  bare `{tools: {}}` (tools supported; no `listChanged`), because the debounced
  `notifications/tools/list_changed` emission (§13) is not yet wired — advertising
  `listChanged: true` while never emitting it is worse than omitting it. Flip to
  `{tools: {listChanged: true}}` in the same change that lands the emission.

---

## 12. Sequencing

Aligned with notes.md (AI loop is v0.5+; design the command system now).

1. **Command system (v0.1–0.2, the foundation).** The `Geex.Command` macro,
   the neutral field-spec (§3a), `parse/1`, `Geex.CommandRegistry`,
   `Geex.Dispatch`, the `%Command.Meta{}` provenance field (§7). The minibuffer
   consumes these. *This is the load-bearing work that must be right early.*
2. **MCP tool export (the projection).** `tools_list/0` + JSON-Schema renderer
   over the field-spec. Free once the macro emits the neutral spec.
3. **MCP server / Direction A (v0.5).** `Geex.MCP.{Protocol,Dispatch,…}` — the
   transport-agnostic protocol core first (`handle_line/1`, `tools/list`,
   `tools/call → Dispatch.run/1`, provenance), then the **loopback Streamable HTTP
   transport** (Layer 4) as the live dogfood — a real harness *attaches* to the
   running geex (Mode 2), so dogfood == production
   ([adr/0018](adr/0018-mcp-transport-streamable-http.md)). The stdio slice (Layer
   2, Mode 1) is demoted to a hermetic CI/conformance harness. Same spine, two
   adapters; the live one is HTTP.
4. **Direction B (post-0.5).** `Geex.AI` wrapping `instructor_ex`; in-editor AI
   features that emit commands through the Direction-A dispatcher. The
   balance_beam wrapper slice (`Geex.AI.BB.*`: supervised exec, replay/eval) is
   built here — see §13 balance_beam decision.
5. **MCP-client connection to pharos (v0.5, tier 1 of §14).** geex spawns pharos
   as an external stdio MCP child and consumes its LSP tools (disk-truth only).
   Feeds Direction B.
6. **Editor-state contract with pharos (post-0.5).** In-VM `didChange`/`focus`
   API (§8) — only when co-location is built (§14 trigger).
7. **Extension tiers 2–3 (post-0.5, §14).** wasmex sandbox; Gleam extension API.
   Each gated on a named (untrusted/third-party) extension author.
8. **Layers 3–4 (when a consumer + security model exist).** Distributed-Erlang
   collab; HTTP/WS+TLS.

### v0.5 explicit non-goals

- HTTP is **loopback Streamable HTTP only** (bind `127.0.0.1`, `Origin` check, no
  auth) — no *remote* HTTP, no WS, no TLS, no multi-client sessions
  ([adr/0018](adr/0018-mcp-transport-streamable-http.md)).
- No distributed-Erlang exposure.
- No cancellation `send_exit` (wire the registry; no-op the kill).
- No `image`/`resource` content blocks.
- No LSP-tool proxying through geex's MCP server (geex is an MCP *client* of
  pharos separately; one unified surface is deferred).
- **No unsaved-state LSP** — pharos runs external/disk-truth only (§14, §8).
- **No WASM extension host and no third-party extension API** (§14 tiers 2–3).

---

## 13. Resolved decisions (formerly open questions)

Decided 2026-05-28 via a grounded re-read of the doc + the research in
[research/](research/), each recommendation adversarially verified against the
sources. Three resolved outright; two are *deferred-with-default* — a low-commitment
baseline plus the precise trigger that should later force the call.

- **Result-schema reuse — RESOLVED: separate by role; one optional shared leaf, deferred.** A Direction-B result schema (§6, Ecto/instructor_ex, *result* role) and a command param field-spec (§3a, macro, *input* role) **never share a renderer or schema abstraction** — that is the §1 trap (two schema *roles*, not one). Authorities differ (macro-DSL command-as-value vs Ecto schema), inputs differ (`:coord_range` vs Ecto types/embeds/enums), and dialects differ: §3a emits **accurate** `required[]`; instructor_ex's `from_ecto_schema/1` marks every field required and uses `$defs`/`$ref` — the divergence §6/§10 already say *not* to copy. Unifying them forces one role to own the other's source of truth, breaking either commands-as-value or §3a's single-authority guarantee. The pipelines overlap at exactly **one** point: both bottom out in JSON-Schema scalar atoms (`"string"`/`"integer"`/`"number"`/`"boolean"`). That — and only that — is a legitimate shared primitive: a pure, role-agnostic `jsonschema_scalar/1` leaf that knows nothing of fields, requiredness, nesting, or provenance, callable by the §3a renderer and by any geex-side mirror of instructor_ex's `for_type/1` without either becoming the other's authority. **Do not extract the leaf in v0.5** — §6 is post-0.5 (§12 step 4) with nothing yet to deduplicate. **Trigger to extract:** Direction B is built *and* its result-schema JSON-Schema is generated natively (not delegated wholesale to instructor_ex's emitter) *and* the §3a scalar table and that path hard-code the same atoms twice. Until then: separate, by role.

- **`listChanged` granularity — RESOLVED: debounce, in the registry.** geex *will* advertise `tools.listChanged: true` (§11) **once this emission path ships** — v0.5 advertises bare `tools: {}` until then — over a *dynamic* command set (§10), so bursty registration — the compile-time set at `Geex.Application` start, or a directory of plugins `Code.compile_file`'d in one load pass (notes.md "Macros for plugins") — must not fan out to one `notifications/tools/list_changed` per command. The notification is payload-free; its only meaning is "re-fetch via `tools/list`", so an un-debounced burst of N registrations is N redundant full re-lists through the single-writer `Writer` (§4). Decision: (1) `Geex.CommandRegistry` owns a monotonic `generation` counter and a trailing-window debounce (one re-armed `Process.send_after`, default ~250 ms, tunable); a burst bumps `generation` once and schedules at most one `{:registry_changed, generation}` broadcast. (2) The registry does **not** know about MCP — per §3 transport is an adapter over the pure core. The MCP server, when started (default-off, §4) and past `notifications/initialized`, *subscribes* to `{:registry_changed, _}` and emits `notifications/tools/list_changed` only when the broadcast generation differs from the one it last advertised; the counter makes the notification idempotent (a coalesced-away or duplicate emit self-heals on the host's next `tools/list`). (3) Emission is suppressed until Application start completes — the initial command set is the baseline that `initialize`/`tools/list` already answer, not a change. Cost: one timer field + one pub/sub topic, no dependency; the latency is irrelevant (registration is startup/plugin-load, never per-keystroke). The same generation-stamped event also serves any Layer-1/3 in-VM or remote agent (§3) without the registry learning about it. A per-bulk-load transaction bracket is deliberately deferred — it layers cleanly over this debounce if zero-spurious-notification precision is ever wanted.

- **Provenance for composite commands — RESOLVED: both; one storage location.** When an agent emits a *sequence* of commands, provenance is **per-command *and* per-turn**, but the turn linkage lives **on `%Command.Meta{}`, not in a separate ledger** (Decision 1: one source, no drift). §7's `Meta` gains an `origin` field: `origin: %{turn_id: "t_7f3a", seq: 2}` (turn_id nil for ad-hoc human input), alongside `actor` / `at` / `prompt_hash`.
  - **What `turn_id` is keyed on:** one *agent turn*. In Direction A (§4) that is one `tools/call` — minted at the existing `put_provenance/2` seam in `tool_call/1`, so a single tool call is a degenerate one-command turn. In Direction B (§§2, 6) it is one feature invocation, which the `Geex.AI` boundary stamps before emitting its N `%Command{}` structs through the Direction-A dispatcher. `turn_id` generalizes over both directions; `seq` orders commands within a turn.
  - **Why on `Meta`, not a ledger:** a ledger is a second source of truth (Decision 1) and is node-local — it does **not** survive External Term Format, so a command routed through a remote `Geex.Dispatch.run/1` (§3 layer 3) would lose its turn linkage. Carrying `origin` on the value lets collab/replay/remote dispatch inherit it for free, exactly as `actor`/`prompt_hash` do (§7 collab attribution, replay analysis). Mirrors `balance_beam`'s value-level, append-only provenance — the frame §6 adopts.
  - **How selective undo reads it (§7):** "undo the last AI edit" filters the single undo history by `meta.actor`; "revert everything the agent did this turn" filters by `meta.origin.turn_id`. Both stay pure queries over the *same* history — no parallel path.
  - **Deliberately deferred:** grouping several `tools/call`s into one logical multi-call turn (a client-supplied correlation token) and a session-spanning `session_id` over many turns. **Trigger:** an agent harness that issues N tool calls as one user-visible action needing atomic revert, *or* a "revert this whole AI session" UX. Until then `turn_id` = per-`tools/call` / per-feature-invocation; session-scoped revert is a query over `actor` + time-range, not a new id.

- **pharos co-location vs subprocess — DECIDED (2026-05-28): external subprocess for v0.5; pharos is NOT bundled.** Run pharos as an MCP-client-over-stdio child — geex is its *client*, pharos ships/versions independently as one capability connection among many (§14 tier 1). The consequence, now explicit: an external pharos cannot read geex's in-VM state, so **v0.5 LSP is disk-truth-only** (§8/§14). In-VM co-location (§3 Layer 1) unlocks the §8 editor-state contract (unsaved-buffer / focus) and warm-pool sharing, but couples release builds and needs an in-VM entry point pharos does not expose today (`pool.get/5`). It remains reachable later as a **transport swap, not a rewrite. Trigger to build co-location:** §12 item 6 is scheduled — a feature needs unsaved-state answers AND stdio/warmup is a *measured* bottleneck. This question generalized into the §14 extension/capability model (geex as MCP client + WASM + native tiers, all funnelling through the one dispatcher).

- **Jido revisit trigger — DEFER, default do not adopt for the command system.** Per §1 Jido's Action == geex Command, but Jido passes a validated **map** to `run/2` and does not `defstruct` the args — which breaks command-as-value (undo/replay/collab determinism, §7, Decision 4). So `jido_action`/`jido_mcp` are a **blueprint** for the macro and MCP export, not the command system itself (§3a, §4); whether to take a *narrow* `jido_action` dependency purely for JSON-Schema generation is a separate build-vs-buy question, not this trigger. Every Jido capability that merely touches dispatch is **cheaply home-grown** on existing OTP and so is *not* a trigger: **scheduled/cron runs** = `Process.send_after` → `Geex.Dispatch.run/1`; **sensors** = a watcher `GenServer`; **single-session pub/sub** = `Geex.Registry` + OTP messaging; **retries/async/timeout** = the `Task.Supervisor` already in §4 plus instructor_ex's reask loop (§6, Decision 3). The **only** trigger is the one thing OTP + commands-as-data does *not* give for free: a **durable, resumable, multi-step autonomous-agent runtime** — a persisted agent "mind" that survives a crash and resumes with accumulated decision-state, effect-directive interpretation, and typed (CloudEvents) wildcard routing across **many independent** agents. Concretely, revisit `jido` + `jido_signal` (the agent/signal slice **only**, never `jido_action` for the command macro) when **all three** hold: (1) agents run long-lived, multi-turn plans that must survive process crash/restart mid-plan (not a single synchronous in-pane request — that's just a BEAM process calling `Dispatch.run/1`, §3 layer 1); (2) **multiple** independent agents need a shared typed signal bus with wildcard routing, beyond what `Geex.Registry` fan-out handles; (3) a Direction-B feature (§12 step 4) actually schedules such agents. Even then, Jido is a **sidecar that emits `%Command{}` through `Geex.Dispatch.run/1`** (§2 composition rule) — never the write path.

- **balance_beam packaging & Direction-B backing — RESOLVED (2026-05-28).** Direction
  B is backed by **`balance_beam`**, which *owns* the schema→reask structured-output
  technique on a thin transport (`req_llm`/`Req`); **`instructor_ex` is dropped** (quiet
  since Feb 2025; a near-rewrite successor exists). The Jido collision that previously
  blocked co-development dissolves: balance_beam's *core* is **Jido-free** (its own
  May-8 `elixir_only_architecture.md` already scoped exactly that —
  `instructor`/`req`/`telemetry`/`nimble_options`/`jason`); the Jido ReAct agent-runtime
  stays a *Tier-2 optional* slice its healthcare consumer adds, which geex never pulls.
  **Co-development:** geex needs only a *thin, late* slice of balance_beam (the
  Direction-B helper, post-0.5, §12 step 4) — orchestration/cost/agent-runtime live
  *above* geex ([vision.md](vision.md) §3) and are not geex's concern. balance_beam is
  driven by its own consumer on its own clock; geex stays focused on the editor and
  adopts the extraction helper when Direction B arrives. The shared *concepts* geex
  needs (provenance, supervised execution, replay) are already **native** (BEAM/OTP +
  commands-as-data), not imports. See [adr/0011](adr/0011-direction-b-balance-beam.md).

---

## 14. Extension & capability model (three tiers, one chokepoint)

geex is not only an MCP *server* (Direction A, §4). It is also an MCP *client* /
capability host: it connects OUT to independently-shipped MCP servers (pharos and
others) to *consume* capabilities (LSP, etc.). **pharos is not bundled** — it is
one user/config-supplied connection among many, shipped and versioned on its own.
This cashes out notes.md:197 ("keeping LSP behind MCP gets it twice") as a real
boundary, and adds the MCP-client axis §3 was missing.

Three tiers of extension/capability, all funnelling to the same dispatcher:

| Tier | What | Trust / isolation | How it reaches the dispatcher |
|---|---|---|---|
| **1. MCP-client connection** | out-of-process capability provider (pharos LSP, other MCP servers) | process boundary IS the sandbox (§9); returned content is *untrusted input* (§9, balance_beam Strat. 10) | a *capability provider*, not a writer. Direction-B features (§6) call its tools, then emit `%Command{}` through `Geex.Dispatch.run/1` (§2 rule) |
| **2. WASM / wasmex extension** | untrusted in-process extension code (Zed model, notes.md:90) | strong in-VM sandbox: guest calls only host exports — no File/sockets/`Code.eval`/raw PIDs | host export surface **bottoms out at `Dispatch.run/1`**; extension emits `%Command{}`, host validates+runs |
| **3. Native BEAM extension** | trusted first-party, Gleam-typed API (notes.md:137) | full trust; Layer-1 process (§3) | builds `%Command{}` values, calls `Dispatch.run/1` directly |

**Invariant (unchanged):** no tier writes buffers. Each produces a
schema-validated `%Command{}` value and runs it through the one dispatcher into
the one undo history (§2, Decision 1, §7 provenance — `actor` distinguishes
`{:extension, id}` / `{:llm, _}` / `:human` / `:external`). The trust ladder gates
*code execution*; the dispatcher gates *capability* — they compose (survey: wasmex
host export bottoming out at `Dispatch.run/1`; dispatcher-as-chokepoint).

> **An external pre-built harness (Claude Code, Codex, …) is *not* one of these
> three tiers.** The tiers are capabilities geex hosts or connects *out* to; an
> external CLI drives geex *inbound* as an MCP client and is governed by the
> cooperative regime + enforcement ladder of
> [adr/0012](adr/0012-trust-and-enforcement.md) / [adr/0016](adr/0016-external-harness-integration.md)
> — scoped by a per-harness preset, optionally OS-sandboxed (Rung 2), with reconcile
> as the floor. Do not file Claude Code as tier 1 (tier 1 is the *outbound* MCP-client
> axis to pharos).

### geex as MCP client (the outbound axis, amends §3)

§3's four layers answer "who reaches the dispatcher" (inbound, geex-as-server).
The MCP-client connection is the dual: geex spawns pharos as a stdio JSON-RPC
child and consumes its tools. Reuse the pure `handle_line`-style seam in reverse
(encode requests, decode replies); supervise one process per connection;
negotiate `protocolVersion` against the server and tolerate version skew / missing
tools (§11, mirrored client-side). Layer-1 "co-located pharos" (§3) is the in-VM
end-state of this same outbound connection.

### The cost of un-bundling pharos (makes §8/§13-Q4 explicit)

§8's in-VM editor-state contract (live `didChange` mirroring + `editor_focus`)
assumed co-location: geex hands pharos buffer/cursor/focus as native Erlang
terms. **An external stdio pharos cannot read geex's in-VM state**, so
unsaved-buffer-aware LSP answers are not free over the link. v0.5 decision:
**LSP is disk-truth-only**; unsaved-state mirroring is deferred, not built. The §8
semantic contract is retained as the *target end-state*, unlocked by a later
co-location transport swap (Layer 1) — **not** by rebuilding pharos's ADR-028
WebSocket bridge over the link (that resurrects the exact transport §8 exists to
avoid, and pharos has no such ingest today — bridge verified unbuilt). **Trigger
to build co-location:** §12-step-5 — a feature needs unsaved-state answers AND
stdio/warmup is a *measured* bottleneck. (§13-Q4 already defaults to external
stdio and calls co-location "a transport swap, not a rewrite" — this section does
not reverse it, it makes the unsaved-state loss explicit and affirms
external-subprocess as the v0.5 baseline.)

### Sequencing (amends §12)

v0.5 ships tier 1 as a stdio MCP-client to an external pharos (disk-truth LSP),
feeding Direction B. Tiers 2 (wasmex) and 3 (Gleam extension API) are post-0.5,
each gated on a named consumer (an actual untrusted/third-party extension author).

---

## 15. Testing & dogfooding

Two parts: the test pyramid for what §4/§3a build, and the dogfood loop that
falls out of geex being its own MCP server.

### 15a. Test pyramid

The design is testable bottom-up because its hot paths are **pure** and its
write path is a **value** (a `%Command{}`), not a side effect. Mirror the
existing `async: true` pure-function tests (`ScreenTest`, `Input.ParserTest`)
and the already-pure `Renderer.diff/2` discipline — *assert against the value
(buffer text / cursor / command history), never against rendered bytes.*

1. **Pure unit (highest-value, most portable — §4).** `Geex.MCP.Protocol.
   handle_line/1` is a pure `String.t() -> {:reply|:noreply|:protocol_error}`
   function; unit-test it with plain JSON strings (pharos proves this is the
   single best thing to port). Same for the macro-generated `parse/1`, the pure
   `Geex.Dispatch` over `%Command{}`, and the §3a field-spec→JSON-Schema
   renderer (assert the projected schema as data).
2. **Property + Dialyzer (§5 mandates this).** Property-test the JSON-RPC
   envelope (id-type echo, request-vs-notification, the three outcomes) and the
   **§1 round-trip the compiler cannot enforce**: for every command,
   `minibuffer-string → %Command{}` and `MCP-args → %Command{}` must yield the
   *same* struct, and re-rendering its args must re-parse. "Same parser" (§1) is
   an architectural claim, not a typed one. Dialyzer + typespecs cover the
   envelope; the `case`-with-catch-all on method needs a test (§5: the compiler
   won't warn on a forgotten method).
3. **Integration.** `Dispatch.run → Session/Buffer → undo history` (provenance
   `actor`/`origin` present and correct); and the feature-gated
   `Geex.MCP.Supervisor` subtree (§4) starts/stops cleanly under `start_mcp`,
   exactly like the existing `terminal_io_child/0` gate (application.ex:23).
4. **End-to-end dogfood-replay** — §15b.

### 15b. The dogfood loop — geex driven headlessly by an LLM

Because geex **is** an MCP server (Direction A, §2/§4) and the write path is
`Dispatch.run/%Command{}` into `Session`/`Buffer` (the renderer is downstream
and optional), geex is drivable by an external LLM. **There are two modes, and
they are not the same dogfood** ([adr/0018](adr/0018-mcp-transport-streamable-http.md)):

- **Mode 2 — the real dogfood (loopback HTTP).** A harness *connects* to the
  **running** geex; edits land in the live session the human is looking at, with
  provenance, in the real undo history. This is the production path, so **dogfood ==
  production**. It is the Streamable HTTP transport (Layer 4) served from `geex
  --serve`, and it is also the enforced-sandbox path
  ([adr/0016](adr/0016-external-harness-integration.md)). Build the
  transport-agnostic protocol core first (`handle_line/1` + `tools/list` +
  `tools/call`), then this transport — ahead of stdio.
- **Mode 1 — headless tool (stdio), demoted to CI.** The harness *spawns* a
  throwaway headless geex (`start_terminal: false, start_mcp: true`). Hermetic,
  single-client, dies with the client — great as a conformance + cassette-replay
  harness, **but it never tests the live-session path**, so it is the regression
  net, not the dogfood. No cancellation, no `listChanged`, loopback HTTP and
  multi-client are out (§12).
- **Do not build a geex-native stdio→HTTP shim.** All target harnesses speak HTTP
  (connect directly); the two with flaky Streamable-HTTP builds (Cline, OpenCode)
  are covered by co-hosting a legacy SSE endpoint and/or the off-the-shelf
  `mcp-remote` proxy. A geex relay would just re-create the Mode-1 throwaway
  topology ([adr/0018](adr/0018-mcp-transport-streamable-http.md)).
- **Headless-buffer assertions without the renderer (the gotcha).** The LLM
  needs deterministic, inspectable buffer state. The `%Command{}` value
  invariant delivers it: add a thin **read-only** query surface
  (`Session.snapshot/0`, `Buffer.get_text/1`) returning buffer text + cursor +
  the provenance-tagged command history *as data*. Tests assert on that value,
  never on screen bytes. (Buffer is a v0.1 stub today; these queries are built
  with the command system. They are queries only — they never write, so the §2
  chokepoint stands.)

### 15c. Two cassette layers — keep them separate (the trap)

Conflating these re-creates the §2 parallel-path mistake.

- **(i) LLM-response cassette** — `balance_beam` Strategy 20: records the model's
  nondeterministic `{prompt → response}`. Lets Direction B (`Geex.AI`/
  `instructor_ex`, §6) replay model output with **no API key**. Depends on the
  §13 balance_beam-packaging decision.
- **(ii) `%Command{}`-sequence cassette (geex-native, the spine)** — the LLM-
  tagged command list lifted straight off the undo history (each carrying
  `actor=:llm`, `origin.turn_id`/`seq`, §7/§13). Replaying it through
  `Dispatch.run/1` and diffing buffer state is a **deterministic, free, no-key,
  no-balance_beam** regression test — available at §12 step 1, before any model
  call. The high-value early win; build it first. **Two requirements make it
  sound:** (1) the fixture is a *pair* — the recorded `%Command{}` list **and** a
  recorded **golden** final buffer state; the test re-runs the list and diffs
  against the golden, *not* against a state the same replay regenerated
  (otherwise a runner-logic regression passes silently). (2) Bit-stable replay
  requires freezing dispatch-time nondeterminism: `Meta.at` is stamped at
  dispatch and any clipboard-slot-id / random inputs must be injected/frozen, or
  replay diverges — a build prerequisite, not free.

A recorded *live* dogfood session is the **composition**: capture model I/O with
(i) and snapshot the resulting commands + golden state with (ii); CI replays (i)
to regenerate the same `%Command{}` sequence and asserts buffer state via §15b.
balance_beam Strategy-18 eval layers on top (gated on the §13 balance_beam
decision). Every replayed edit still flows through the one dispatcher — the
harness obeys the §2 composition rule exactly as the product does, and any
WASM/extension-authored command in the dogfood surface enters the same way (its
capability boundary is per §14).

> **"geex editing geex"** is the north-star dogfood (the LLM building geex uses
> geex's own MCP tools on geex's files), but it is a *milestone*, not a v0.5 gate:
> it needs a self-hosting-grade file-edit command surface, which is post-0.5.
