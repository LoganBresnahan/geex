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
  ledger: config_env() != :test
