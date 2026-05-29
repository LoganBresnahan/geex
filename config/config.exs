import Config

# `:prim_tty` needs exclusive ownership of the terminal — don't try to
# grab it during `mix test`.
config :geex,
  start_terminal: config_env() != :test
