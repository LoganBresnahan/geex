# The catalog's grammars (ADR-0040 §2): one recipe each, read by `mix geex.catalog`.
#
#   name        the language, and the `tree_sitter_<name>` export inside its parser.wasm
#   display     how it's shown
#   repo        upstream; `tag` is pinned to `commit`, and a tag that moved stops the build
#   path        the grammar's directory in the repository
#   extensions  file-name endings it highlights (".app.src" works as well as ".rs")
#   filenames   whole file names it highlights
#   license     SPDX id; `license_files` are copied into the package from the repository root
#   highlights  the query files merged into one highlights.scm, as {grammar, path}: a query
#               inherited from another grammar names that grammar's recipe, so every package
#               stands alone
#
# Injections (HEEx inside ~H, JavaScript inside <script>) aren't used (ADR-0040 §9).
[
  %{
    name: "bash",
    display: "Bash",
    repo: "https://github.com/tree-sitter/tree-sitter-bash",
    tag: "v0.25.1",
    commit: "a06c2e4415e9bc0346c6b86d401879ffb44058f7",
    path: ".",
    extensions: [".sh", ".bash"],
    filenames: [".bashrc", ".bash_profile", ".profile"],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"bash", "queries/highlights.scm"}]
  },
  %{
    name: "css",
    display: "CSS",
    repo: "https://github.com/tree-sitter/tree-sitter-css",
    tag: "v0.25.0",
    commit: "dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f",
    path: ".",
    extensions: [".css"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"css", "queries/highlights.scm"}]
  },
  %{
    name: "elixir",
    display: "Elixir",
    repo: "https://github.com/elixir-lang/tree-sitter-elixir",
    tag: "v0.3.5",
    commit: "e2d9e6e0e76b0c436fa48a0b8c32a031d0cbdf49",
    path: ".",
    extensions: [".ex", ".exs"],
    filenames: [],
    # Apache-2.0; its generated parser is MIT (its NOTICE says which is which).
    license: "Apache-2.0 AND MIT",
    license_files: ["LICENSE", "NOTICE"],
    highlights: [{"elixir", "queries/highlights.scm"}]
  },
  %{
    name: "erlang",
    display: "Erlang",
    repo: "https://github.com/WhatsApp/tree-sitter-erlang",
    tag: "0.21.0",
    commit: "0386a11c835950f5e1ebfbcbf49863d8495de4e0",
    path: ".",
    extensions: [".erl", ".hrl", ".app.src", ".escript"],
    filenames: ["rebar.config"],
    license: "Apache-2.0",
    license_files: ["LICENSE"],
    highlights: [{"erlang", "queries/highlights.scm"}]
  },
  %{
    name: "go",
    display: "Go",
    repo: "https://github.com/tree-sitter/tree-sitter-go",
    tag: "v0.25.0",
    commit: "1547678a9da59885853f5f5cc8a99cc203fa2e2c",
    path: ".",
    extensions: [".go"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"go", "queries/highlights.scm"}]
  },
  %{
    name: "heex",
    display: "HEEx",
    repo: "https://github.com/phoenixframework/tree-sitter-heex",
    tag: "v0.9.0",
    commit: "5842537f734d7c12685bf27d6005313e3e5a47a0",
    path: ".",
    extensions: [".heex"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE.md"],
    highlights: [{"heex", "queries/highlights.scm"}]
  },
  %{
    name: "html",
    display: "HTML",
    repo: "https://github.com/tree-sitter/tree-sitter-html",
    tag: "v0.23.2",
    commit: "5a5ca8551a179998360b4a4ca2c0f366a35acc03",
    path: ".",
    extensions: [".html", ".htm"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"html", "queries/highlights.scm"}]
  },
  %{
    name: "javascript",
    display: "JavaScript",
    repo: "https://github.com/tree-sitter/tree-sitter-javascript",
    tag: "v0.25.0",
    commit: "44c892e0be055ac465d5eeddae6d3e194424e7de",
    path: ".",
    extensions: [".js", ".mjs", ".cjs", ".jsx"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [
      {"javascript", "queries/highlights.scm"},
      {"javascript", "queries/highlights-jsx.scm"},
      {"javascript", "queries/highlights-params.scm"}
    ]
  },
  %{
    name: "json",
    display: "JSON",
    repo: "https://github.com/tree-sitter/tree-sitter-json",
    tag: "v0.24.8",
    commit: "ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24",
    path: ".",
    extensions: [".json"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"json", "queries/highlights.scm"}]
  },
  %{
    # The block grammar only: inline markup is a second grammar reached by injection.
    name: "markdown",
    display: "Markdown",
    repo: "https://github.com/tree-sitter-grammars/tree-sitter-markdown",
    tag: "v0.5.3",
    commit: "f969cd3ae3f9fbd4e43205431d0ae286014c05b5",
    path: "tree-sitter-markdown",
    extensions: [".md", ".markdown"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"markdown", "tree-sitter-markdown/queries/highlights.scm"}]
  },
  %{
    name: "python",
    display: "Python",
    repo: "https://github.com/tree-sitter/tree-sitter-python",
    tag: "v0.25.0",
    commit: "293fdc02038ee2bf0e2e206711b69c90ac0d413f",
    path: ".",
    extensions: [".py", ".pyi"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"python", "queries/highlights.scm"}]
  },
  %{
    name: "rust",
    display: "Rust",
    repo: "https://github.com/tree-sitter/tree-sitter-rust",
    tag: "v0.24.2",
    commit: "77a3747266f4d621d0757825e6b11edcbf991ca5",
    path: ".",
    extensions: [".rs"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"rust", "queries/highlights.scm"}]
  },
  %{
    name: "toml",
    display: "TOML",
    repo: "https://github.com/tree-sitter-grammars/tree-sitter-toml",
    tag: "v0.7.0",
    commit: "64b56832c2cffe41758f28e05c756a3a98d16f41",
    path: ".",
    extensions: [".toml"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"toml", "queries/highlights.scm"}]
  },
  %{
    # TypeScript's queries add to JavaScript's (its tree-sitter.json says so).
    name: "typescript",
    display: "TypeScript",
    repo: "https://github.com/tree-sitter/tree-sitter-typescript",
    tag: "v0.23.2",
    commit: "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
    path: "typescript",
    extensions: [".ts", ".mts", ".cts"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [
      {"typescript", "queries/highlights.scm"},
      {"javascript", "queries/highlights.scm"}
    ]
  },
  %{
    name: "tsx",
    display: "TSX",
    repo: "https://github.com/tree-sitter/tree-sitter-typescript",
    tag: "v0.23.2",
    commit: "f975a621f4e7f532fe322e13c4f79495e0a7b2e7",
    path: "tsx",
    extensions: [".tsx"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [
      {"tsx", "queries/highlights.scm"},
      {"javascript", "queries/highlights-jsx.scm"},
      {"javascript", "queries/highlights.scm"}
    ]
  },
  %{
    name: "yaml",
    display: "YAML",
    repo: "https://github.com/tree-sitter-grammars/tree-sitter-yaml",
    tag: "v0.7.2",
    commit: "7708026449bed86239b1cd5bce6e3c34dbca6415",
    path: ".",
    extensions: [".yml", ".yaml"],
    filenames: [],
    license: "MIT",
    license_files: ["LICENSE"],
    highlights: [{"yaml", "queries/highlights.scm"}]
  }
]
