# geex

An **LLM-native text editor on the BEAM**. Human keystrokes, agent edits, extensions and
remote peers all become the same `%Command{}` value, run through one dispatcher into one undo
history, each tagged with who made it. geex records the world; the agent (the brain) is
bring-your-own.

It is early, terminal-only, and built for one machine at a time. [doc/README.md](doc/README.md)
maps the design; [doc/vision.md](doc/vision.md) is the north star; [doc/roadmap.md](doc/roadmap.md)
says what's built and what's next; [CHANGELOG.md](CHANGELOG.md) says what each release changed.

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

In the editor, `Ctrl-X` quits (`Ctrl-Q` and `Ctrl-C` too); with unsaved edits, the first quit
names the files and the second leaves. `Alt+Y` opens the settings: languages, themes, every key,
and general options such as the mouse.

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

In the output pane, a `path:line` (or tsc's `path(line,col)`) that names a file is drawn as a
link: a click on it, or Enter on its line, opens the file there, and `Alt+N` steps through them.
`!` runs the command again and `q` closes the pane; `Ctrl-G` stops a command that's running. The
command runs without a terminal, so a full-screen program (vim, top, ssh) belongs in a terminal
split instead. Up and Down in the command line bring back what you entered before.

Paths are from the project root; an absolute path (`/…`, `~/…`) goes anywhere. In the file tree
(`Alt+T` shows it, `Alt+<` moves into it), `a` adds a file or directory where the highlight is,
`d` deletes the highlighted entry (a directory only when it's empty), and `r` renames it.

`Alt+Q` searches the file, selecting the match as you type; `Alt+Shift+Q` searches the project
(`git grep`, or `grep -r` outside git) into the output pane; `Alt+N` goes to the next match, or
opens the next result. Then, in the command line:

```text
replace TEXT            # replace the file search's matches in this file, after a y/n
replace-all TEXT        # replace the project search's matches in every file it listed, after a y/n
save-all                # write every file with unsaved changes (replace-all leaves them unsaved)
```

Each replace is one undo step per file.

## With an agent

Agents edit files the way they always do. When a file geex has open changes on disk, geex marks
it "behind disk" and leaves your text as it is; `Alt+D`, a click on the mark, or a save takes the
change into that file's undo history beside your own edits, marked as made outside geex, merged
with any unsaved edits of yours. With the captAInHook payload registered, each change is credited
to the agent that made it, each agent session in a colour of its own in the gutter and the edits
pane; registered on `pre-tool-use` too, a change made by an agent's shell command is credited
"changed while" that command ran. See
[doc/install.md](doc/install.md#captainhook-who-wrote-that).

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
