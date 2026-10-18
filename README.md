# geex

An **LLM-native text editor on the BEAM**. Human keystrokes, agent edits, extensions and
remote peers all become the same `%Command{}` value, run through one dispatcher into one undo
history, each tagged with who made it. geex records the world; the agent (the brain) is
bring-your-own.

It is early, terminal-only, and built for one machine at a time. [doc/README.md](doc/README.md)
maps the design; [doc/vision.md](doc/vision.md) is the north star; [doc/roadmap.md](doc/roadmap.md)
says what's built and what's next.

## Building

geex depends on [tree_sitter_wasm](https://github.com/LoganBresnahan/tree_sitter_wasm) (a Rust
NIF) by path, so **clone both side by side**:

```sh
git clone https://github.com/LoganBresnahan/geex
git clone https://github.com/LoganBresnahan/tree_sitter_wasm
cd geex
mix deps.get
mix test
```

You need Elixir 1.18+ on OTP 26+, a Rust toolchain (the first build compiles wasmtime and
takes minutes), `git`, and on Linux `inotify-tools` to notice files changed on disk.

```sh
# the editor, in a real terminal
elixir --erl "-noshell -noinput +Bd" -S mix run --no-start -e 'Geex.run("path")'
# or build one executable and install it as ~/.local/bin/geex (Linux, this machine only)
mix geex.deploy
```

## License

[Apache-2.0](LICENSE). Third-party material in the tree (a theme, two grammars) keeps its own
licence; see [NOTICE](NOTICE).
