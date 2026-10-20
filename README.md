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

You need Elixir 1.18+ on OTP 27+, a Rust toolchain (the first build compiles wasmtime and
takes minutes), `git`, and on Linux `inotify-tools` to notice files changed on disk.

```sh
# the editor, in a real terminal
elixir --erl "-noshell -noinput +Bd" -S mix run --no-start -e 'Geex.run("path")'
# or build this checkout and install it as ~/.local/bin/geex, the way a release installs
mix geex.deploy
```

To install a release instead (Linux x64/arm64 with glibc 2.35+, or a Mac, Apple silicon or Intel
from 0.3.1; on Windows, use WSL; no Erlang needed), see [doc/install.md](doc/install.md):

```sh
curl -fsSL https://github.com/LoganBresnahan/geex/releases/latest/download/install.sh | sh
```

From 0.3.2, an installed geex manages itself: `geex self update`, `geex self rollback`,
`geex self prune` and `geex self uninstall`. See [doc/install.md](doc/install.md).

## Using it

```sh
geex                    # the current directory: its file tree and a scratch buffer
geex a.txt sub/b.ex     # open both files, show the first
geex DIR                # DIR's file tree
geex -- -odd-name       # paths after -- are never options
geex highlight FILE     # print FILE highlighted, with no editor
geex --help             # every command
```

In the editor, `Ctrl-X` quits. `Alt+Y` opens the settings: languages, themes, every key, and
general options such as the mouse.

Files are made, deleted and renamed from the editor. `Alt+M` opens the command line:

```text
new lib/thing.ex        # create a file and open it (asks before making a missing directory)
new lib/util/           # a trailing / makes a directory; so does `mkdir lib/util`
rename lib/other.ex     # move this file, keeping its unsaved edits and undo history (also `mv`)
delete                  # delete this file, after a y/n
```

The command line also runs shell commands, in the project root:

```text
!mix test               # run it; its output shows in a pane below the editor
!!                      # run the last one again
|sort                   # pipe the selection through a command and replace it (Alt+Z undoes it)
```

In the output pane, Enter on a `path:line` opens the file there, `!` runs the command again and
`q` closes the pane; `Ctrl-G` stops a command that's running. The command runs without a terminal,
so a full-screen program (vim, top, ssh) belongs in a terminal split instead. Up and Down in the
command line bring back what you entered before.

Paths are from the project root; an absolute path (`/…`, `~/…`) goes anywhere. In the file tree
(`Alt+T` shows it, `Alt+P` moves into it), `a` adds a file or directory where the highlight is,
`d` deletes the highlighted entry (a directory only when it's empty), and `r` renames it.

## Languages and themes

geex ships with no grammar and no theme: out of the box it draws in your terminal's own colours
and highlights nothing. Each release pins a catalog of tree-sitter grammars and themes, each
package checked by its sha256. Install what you use, from the editor (`Alt+Y`) or the shell:

```sh
geex install elixir json      # or javascript, typescript, python, rust, go, …
geex install --list           # what the catalog has, and what's installed
geex install ./my-grammar     # a package of your own
```

geex goes to the network only for an install you ask for; installed packages work offline
([ADR-0040](doc/adr/0040-bare-geex-and-the-catalog.md)).

## License

[Apache-2.0](LICENSE). Third-party material in the tree (the catalog's theme, and the test
fixtures: a theme and two grammars) keeps its own licence, as does each catalog package; see
[NOTICE](NOTICE).
