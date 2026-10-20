import Config

# `:prim_tty` needs exclusive ownership of the terminal — don't try to
# grab it during `mix test`.
#
# The reconcile file-watcher (ADR-0017) is the always-on Rung 0 floor in dev/prod,
# but off under `mix test`: tests start their own isolated, named `Geex.Reconcile`
# and inject `:file_event` messages directly, so they exercise the watcher glue and
# the reconcile core without the global singleton or a platform inotify backend.
# The highlight reactor (ADR-0022) fires off the command stream in dev/prod; off
# under `mix test` so existing buffer/session tests don't spin up reactors +
# tree-sitter passes on every open. Highlight tests start a reactor explicitly.
#
# The reconcile quiet period (ADR-0032) is 0 under test: tests inject `:file_event`s and
# assert right after, so a delayed read would make "nothing changed" assertions pass
# vacuously. Settle tests pass `settle_ms:` explicitly.
config :geex,
  reconcile_settle_ms: if(config_env() == :test, do: 0, else: 50),
  # The attestation intake (ADR-0032): its listener + discovery file. Tests start their own.
  start_attest: config_env() != :test,
  start_terminal: config_env() != :test,
  start_reconcile: config_env() != :test,
  start_highlight: config_env() != :test,
  # The durable ledger (ADR-0033): each path-backed buffer's history is appended to
  # ~/.local/state/geex/ledger/ (`ledger_dir` overrides). Tests opt in per buffer.
  ledger: config_env() != :test,
  # The edits list kept across restarts (ADR-0034 §6, amended 2026-10-18), in
  # ~/.local/state/geex/edits.jsonl (`edits_file` overrides). Tests pass a file of their own.
  edits_log: config_env() != :test,
  # The minibuffer's history kept across restarts (ADR-0042), in
  # ~/.local/state/geex/history.json (`history_file` overrides). Tests keep it in memory.
  minibuffer_history: config_env() != :test,
  # Compiled grammars kept in $XDG_CACHE_HOME/geex/wasm (ADR-0040 §8). Tests leave the user's
  # cache alone.
  wasm_cache: config_env() != :test,
  # Installed grammars and themes (ADR-0040 §4): $XDG_DATA_HOME/geex, unless this is set. Tests
  # get an empty directory of their own, never the user's; a test that installs sets its own.
  # Named for this run's OS process, so two suites at once (two checkouts) never share it.
  data_dir:
    if(config_env() == :test,
      do: Path.join(System.tmp_dir!(), "geex-test-data-#{System.pid()}")
    ),
  # What the settings view keeps (ADR-0040 §7): $XDG_CONFIG_HOME/geex/settings.json, unless this
  # is set. Tests never read or write the user's.
  settings_path:
    if(config_env() == :test,
      do: Path.join(System.tmp_dir!(), "geex-test-settings-#{System.pid()}.json")
    )
