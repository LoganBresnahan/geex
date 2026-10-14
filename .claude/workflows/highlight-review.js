export const meta = {
  name: 'highlight-review',
  description: 'Adversarial review of the tree-sitter highlighter slice (NIF + theme/render + cache)',
  phases: [
    { title: 'Review', detail: 'multi-lens find over the new surface' },
    { title: 'Verify', detail: 'adversarially refute each finding against the real code' },
  ],
}

// The surface added this session (NIF caching/deadline + geex highlight/theme/ansi).
const PKG = '/home/oof/tree_sitter_wasm'
const GEEX = '/home/oof/geex'

const DIMENSIONS = [
  {
    key: 'rust-nif',
    label: 'Rust NIF safety & concurrency',
    files: [`${PKG}/native/tree_sitter_wasm/src/lib.rs`],
    focus: `This is a Rustler NIF that caches a tree-sitter Parser+WasmStore+Query in a
ResourceArc<Grammar> behind a Mutex, and bounds parse with a wall-clock deadline via a
ParseOptions progress callback (ControlFlow::Break). A cancelled/failed parse calls parser.reset().
Hunt for REAL defects: panic-across-the-NIF-boundary (indexing names[cap.index], mat.captures[*idx],
unwrap), Instant + Duration::from_millis(timeout_ms) overflow for huge timeout_ms, mutex poisoning
behavior, resource Drop / leak, Send/Sync soundness, the None->timeout misattribution (a genuine
parse error past the deadline reported as :timeout), whether reset() is sufficient/necessary,
unbounded memory, UTF-8/byte assumptions. Ignore style. tree-sitter 0.26.9, rustler 0.38.`,
  },
  {
    key: 'elixir-cache',
    label: 'Elixir caching & concurrency',
    files: [
      `${GEEX}/lib/geex/highlight.ex`,
      `${GEEX}/lib/geex/highlight/grammars.ex`,
      `${PKG}/lib/tree_sitter_wasm.ex`,
    ],
    focus: `Geex.Highlight.Grammars memoizes a compiled grammar handle in :persistent_term keyed by
{module, language}; Geex.Highlight.spans/3 resolves the handle + calls TreeSitterWasm.highlight with
a deadline. Hunt REAL defects: the persistent_term double-compile race and whether it's truly
harmless, :persistent_term.put on a hot path (global GC) implications, unbounded cache growth,
errors accidentally cached, the with/else tagging in compile/1 (does {:error, posix} vs
{:error, binary} ever collide or mis-tag?), guard clauses, default timeout, what happens if the NIF
returns an unexpected shape. Ignore style.`,
  },
  {
    key: 'render',
    label: 'Render correctness (color / theme / ansi)',
    files: [
      `${GEEX}/lib/geex/ansi.ex`,
      `${GEEX}/lib/geex/color.ex`,
      `${GEEX}/lib/geex/theme.ex`,
      `${GEEX}/lib/geex/theme/birds_of_paradise.ex`,
      `${GEEX}/lib/geex/theme/style.ex`,
      `${GEEX}/lib/geex/theme/palette.ex`,
      `${GEEX}/lib/geex/highlight/span.ex`,
    ],
    focus: `Geex.Ansi.highlight/3 paints per-byte styles (widest span first, ties by dot-count so
more-specific wins), chunk_by + binary_part to emit truecolor SGR. Geex.Color parses hex + flattens
alpha. Geex.Theme does longest-prefix capture resolution. Hunt REAL defects: binary_part on byte
offsets that could split a multibyte UTF-8 grapheme (can a tree-sitter capture range end mid-codepoint
given valid UTF-8 source?), off-by-one in start..end-1 painting, chunk_by correctness when styles are
equal-by-value, SGR code correctness (38;2 fg / 48;2 bg / attrs), alpha-flatten rounding/clamping,
longest-prefix edge cases (capture "", trailing dot, single segment), Color.from_hex on malformed
input (does it raise cleanly or silently mis-parse?). Ignore style.`,
  },
  {
    key: 'edge-task',
    label: 'API, edge cases & the mix task',
    files: [
      `${GEEX}/lib/mix/tasks/geex.highlight.ex`,
      `${GEEX}/lib/geex/highlight.ex`,
      `${GEEX}/lib/geex/highlight/grammars.ex`,
    ],
    focus: `mix geex.highlight runs Mix.Task.run("app.config") (loads, does NOT start the app) then
Geex.Highlight.spans -> Grammars.handle -> :persistent_term + TreeSitterWasm.load_grammar (a NIF).
Hunt REAL defects: does spans actually work when the app is loaded-but-not-started (persistent_term
needs no process; the NIF needs :tree_sitter_wasm loaded — is it?)? File.read! on a missing path,
language detection by extension, error message paths (Mix.raise), timeout=0 semantics at the geex
layer, negative/huge timeout, empty file. Ignore style.`,
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
      `You are reviewing geex's syntax-highlighting slice, dimension "${d.label}".
Read these files and report ONLY real, in-scope defects (correctness, safety, concurrency,
crashes, resource leaks) — not style, not speculative future work:
${d.files.map((f) => `  - ${f}`).join('\n')}

Focus: ${d.focus}

For each defect give file, line (best effort), severity, a rationale with a concrete trigger, and a
concrete fix. If you find nothing real, return an empty findings list. Be precise; read the code.`,
      { label: `review:${d.key}`, phase: 'Review', schema: FINDINGS, agentType: 'Explore' },
    ),
  (review, d) => {
    const findings = (review && review.findings) || []
    if (findings.length === 0) return { dimension: d.key, confirmed: [] }
    return parallel(
      findings.map((f) => () =>
        agent(
          `Adversarially verify this claimed defect in geex's highlighter. Read the actual file and
REFUTE it if you can. Default to real=false if it is style-only, out of scope, speculative, already
handled by the code, or you cannot concretely confirm the trigger. Only real=true with a concrete,
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
