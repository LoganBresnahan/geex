export const meta = {
  name: 'reactor-review',
  description: 'Adversarial review of the highlight reactor + display-wiring slice',
  phases: [
    { title: 'Review', detail: 'multi-lens find over the reactor/display surface' },
    { title: 'Verify', detail: 'adversarially refute each finding against the real code' },
  ],
}

const GEEX = '/home/oof/geex'

const DIMENSIONS = [
  {
    key: 'reactor-concurrency',
    label: 'Reactor process & concurrency',
    files: [
      `${GEEX}/lib/geex/highlight/reactor.ex`,
      `${GEEX}/lib/geex/highlight/reactor_supervisor.ex`,
      `${GEEX}/lib/geex/buffer.ex`,
    ],
    focus: `Geex.Highlight.Reactor is one GenServer per buffer. It subscribes to the buffer's
post-dispatch emit ({:geex_buffer_change, buffer, version}), and runs an async, coalesced,
latest-wins highlight pass: start_pass spawns an UNlinked process that sends {:pass_result, id,
version, result}; the reactor Process.monitors it; pass_result for the current in_flight.id is
accepted (and demonitor(ref,[:flush])), others ignored as stale; a buffer-monitor :DOWN stops the
reactor; a task :DOWN drops the pass. Geex.Buffer gained subscribe/2 (monitors the subscriber,
returns version), notify_change after a successful dispatch (plain send), and a :DOWN handler to
drop dead subscribers. Hunt REAL defects: the spawn-then-Process.monitor race (could a :pass_result
or :DOWN be missed/mis-handled?), pass_counter/id correlation correctness, whether a stuck in_flight
can ever wedge (pending set but never re-run), demonitor flush correctness, the buffer's NEW
handle_info clause now swallowing messages a buffer might receive, subscribe on a dead buffer, double
notify, unbounded growth, ordering of monitor vs subscribe in init. Ignore style.`,
  },
  {
    key: 'render-sgr',
    label: 'Renderer SGR + projection correctness',
    files: [
      `${GEEX}/lib/geex/renderer.ex`,
      `${GEEX}/lib/geex/sgr.ex`,
      `${GEEX}/lib/geex/highlight/paint.ex`,
      `${GEEX}/lib/geex/ansi.ex`,
    ],
    focus: `Geex.Renderer now groups x-adjacent changed cells by identical style and emits one
cursor-move + Sgr.escape + chars + reset per run; a PLAIN run (escape == "") must stay byte-identical
to before (move + chars, no reset). Geex.Sgr encodes :default/{:ansi,0..15}/{:xterm,0..255}/{:rgb}.
Geex.Highlight.Paint.to_screen walks graphemes tracking byte offset (multibyte) + line/col, projects
styled cells, scroll selects first visible line, off-screen clipped by Screen.set_cell. Hunt REAL
defects: a plain run accidentally emitting SGR (would break byte-identity), wrong SGR codes (ansi
bright 8..15, bg vs fg base), same_style? correctness (attrs order), iodata correctness, the
grapheme/byte walk drift on multibyte or CRLF, byte->style misalignment when a span ends mid-codepoint,
Map.get on a byte that is the start of a multibyte grapheme vs interior, integer overflow/negative
scroll, an off-by-one in start..end-1 painting, whether the Ansi refactor changed its output. Ignore
style.`,
  },
  {
    key: 'lifecycle-edge',
    label: 'Lifecycle, gating & integration edges',
    files: [
      `${GEEX}/lib/geex/highlight/reactor.ex`,
      `${GEEX}/lib/geex/session.ex`,
      `${GEEX}/lib/geex/application.ex`,
      `${GEEX}/lib/geex/highlight.ex`,
    ],
    focus: `Geex.Highlight.Reactor.watch/2 is called from Session.open_file after Reconcile.watch;
gated by :start_highlight (off under mix test). It starts a reactor via ReactorSupervisor when the
language is supported and none is running (for_buffer check). A reactor whose grammar fails to load,
or an unsupported language, or an empty buffer, or a buffer that dies mid-pass — all must degrade
cleanly. Hunt REAL defects: the watch/2 with-chain logic (does it actually start only when gated on +
supported + not-already-running? what does for_buffer returning {:ok,_} do inside the with?), a
reactor started for a buffer that has no extension/unsupported language, the gate default, reactors
leaking when a buffer is reused (open_file find-or-start returns an existing buffer — is a duplicate
reactor avoided?), Session coupling/crash risk if watch raises, language_for_path edge cases. Ignore
style.`,
  },
]

const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          title: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'string', description: 'line number or range, best effort' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          rationale: { type: 'string', description: 'why it is a real defect + concrete trigger' },
          fix: { type: 'string', description: 'concrete suggested fix' },
        },
        required: ['title', 'file', 'severity', 'rationale', 'fix'],
      },
    },
  },
  required: ['findings'],
}

const VERDICT = {
  type: 'object',
  properties: {
    real: { type: 'boolean', description: 'true only if a genuine in-scope defect confirmed against the code' },
    severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
    reason: { type: 'string' },
  },
  required: ['real', 'reason'],
}

phase('Review')
const results = await pipeline(
  DIMENSIONS,
  (d) =>
    agent(
      `Review geex's highlight-reactor + display slice, dimension "${d.label}". Read these files and
report ONLY real, in-scope defects (correctness, concurrency, crashes, leaks) — not style, not
speculative future work:
${d.files.map((f) => `  - ${f}`).join('\n')}

Focus: ${d.focus}

For each defect give file, line (best effort), severity, a rationale with a concrete trigger, and a
concrete fix. Empty findings list if nothing real. Read the code carefully.`,
      { label: `review:${d.key}`, phase: 'Review', schema: FINDINGS, agentType: 'Explore' },
    ),
  (review, d) => {
    const findings = (review && review.findings) || []
    if (findings.length === 0) return { dimension: d.key, confirmed: [] }
    return parallel(
      findings.map((f) => () =>
        agent(
          `Adversarially verify this claimed defect in geex's reactor/display slice. Read the actual
file and REFUTE it if you can. Default to real=false if it is style-only, out of scope, speculative,
already handled, or you cannot concretely confirm the trigger. Only real=true with a concrete,
confirmed trigger.

Claim: ${JSON.stringify(f)}`,
          { label: `verify:${d.key}:${f.file.split('/').pop()}`, phase: 'Verify', schema: VERDICT, agentType: 'Explore' },
        ).then((v) => ({ finding: f, verdict: v })),
      ),
    ).then((vs) => ({
      dimension: d.key,
      confirmed: vs.filter(Boolean).filter((x) => x.verdict && x.verdict.real),
    }))
  },
)

const confirmed = results
  .filter(Boolean)
  .flatMap((r) => r.confirmed)
  .map((x) => ({ ...x.finding, severity: x.verdict.severity || x.finding.severity, verify_reason: x.verdict.reason }))

const order = { critical: 0, high: 1, medium: 2, low: 3 }
confirmed.sort((a, b) => (order[a.severity] ?? 9) - (order[b.severity] ?? 9))

log(`confirmed defects: ${confirmed.length}`)
return { confirmed, total_raw: results.filter(Boolean).reduce((n, r) => n + r.confirmed.length, 0) }
