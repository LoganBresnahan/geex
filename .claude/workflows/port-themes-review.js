export const meta = {
  name: 'port-themes-review',
  description: 'Adversarial review of the dynamic-port + themes-as-data slices',
  phases: [
    { title: 'Review', detail: 'multi-lens find' },
    { title: 'Verify', detail: 'adversarially refute each finding against the real code' },
  ],
}

const GEEX = '/home/oof/geex'

const DIMENSIONS = [
  {
    key: 'port',
    label: 'Dynamic MCP port',
    files: [
      `${GEEX}/lib/geex/mcp/port.ex`,
      `${GEEX}/lib/geex/application.ex`,
      `${GEEX}/config/runtime.exs`,
      `${GEEX}/lib/mix/tasks/geex.serve.ex`,
    ],
    focus: `Geex.MCP.Port.resolve(0) asks the host for a free loopback port (gen_tcp.listen 0 ->
inet:port -> close), N stays N; announce/1 logs the URL + writes GEEX_MCP_PORT_FILE if set.
Geex.Application resolves the requested port (default 0) and announces before starting Bandit on the
concrete port. runtime.exs maps GEEX_MCP_PORT (unset/""=0=auto, else 0..65535) -> http_mcp_port; the
serve task allows 0. Hunt REAL defects: the pre-bind TOCTOU window (is it handled/acceptable + does a
collision fail loudly?), gen_tcp option correctness (ip/active/reuseaddr), resolve/1 guard coverage
(what about a port outside 0..65535 reaching resolve? a non-integer from config?), announce called at
supervisor-build time (side effects + does resolve run exactly once?), write_file error handling,
the GEEX_MCP_PORT range/parse, default_http_mcp_port now meaning "preset port" not "app default"
(any stale assumption / presets_test drift?), socket leak if inet:port fails. Ignore style.`,
  },
  {
    key: 'themes',
    label: 'Theme loader + Zed importer (untrusted data)',
    files: [
      `${GEEX}/lib/geex/theme.ex`,
      `${GEEX}/lib/geex/color.ex`,
      `${GEEX}/lib/geex/theme/import/zed.ex`,
    ],
    focus: `Geex.Theme.load/from_json validate a JSON theme (untrusted file): name (string), appearance
(dark/light), palette (bg+fg required, others optional, #RRGGBBAA flattened against bg), syntax (map
of capture -> bare hex | object{fg,bg?,attrs}). Geex.Color.parse/2 is the safe parser (#RRGGBB /
#RRGGBBAA, hex-validated, never raises). Geex.Theme.Import.Zed reshapes a Zed theme onto the native
map + reuses from_json (font_style italic->:italic, font_weight 700->:bold, palette from editor.* +
players[0]). Hunt REAL defects: a malformed file that still CRASHES instead of erroring (non-map JSON
top-level, syntax not a map, a style object whose fg is a number/missing, palette not a map, appearance
non-string, attrs value not boolean), Color.parse edge cases (uppercase, "#abcdeg" non-hex, leading/
trailing junk, byte_size other than 6/8, integer/negative), alpha-flatten math/rounding, the reduce_while
over syntax, bundled/1 app_dir raising when :geex unloaded, the Zed importer on missing editor.background
(no bg -> error?) / missing players / font_weight as float / a syntax entry that's a bare string / a
capture mapping to null. Confirm from_json's contract "never raises on a bad file" actually holds.
Ignore style.`,
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
          line: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low'] },
          rationale: { type: 'string', description: 'why it is a real defect + concrete trigger' },
          fix: { type: 'string' },
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
    real: { type: 'boolean' },
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
      `Review geex's "${d.label}" slice. Read these files and report ONLY real, in-scope defects
(correctness, crashes on bad input, leaks, concurrency) — not style, not speculative future work:
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
          `Adversarially verify this claimed defect in geex. Read the actual file and REFUTE it if you
can. Default to real=false if style-only, out of scope, speculative, already handled, or you cannot
concretely confirm the trigger. Only real=true with a concrete, confirmed trigger.

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
