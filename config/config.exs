import Config

# `:prim_tty` needs exclusive ownership of the terminal — don't try to
# grab it during `mix test`.
#
# The reconcile file-watcher (ADR-0017) is the always-on Rung 0 floor in dev/prod,
# but off under `mix test`: tests start their own isolated, named `Geex.Reconcile`
# and inject `:file_event` messages directly, so they exercise the watcher glue and
# the reconcile core without the global singleton or a platform inotify backend.
config :geex,
  start_terminal: config_env() != :test,
  start_reconcile: config_env() != :test
