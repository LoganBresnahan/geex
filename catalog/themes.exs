# The catalog's themes (ADR-0040 §2), read by `mix geex.catalog`. A theme is data: its JSON (the
# native format, `Geex.Theme`) and its licence, both kept here in `catalog/themes/`. Each licence
# file names where its palette and its highlight mapping came from, at which commit, and carries
# the upstream licence text verbatim.
mit = fn name, display ->
  %{
    name: name,
    display: display,
    file: "themes/#{name}.json",
    license: "MIT",
    license_file: "themes/#{name}.LICENSE"
  }
end

[
  %{
    name: "birds-of-paradise",
    display: "Birds of Paradise",
    file: "themes/birds-of-paradise.json",
    # Joe Bergantine's 2010 scheme, by way of the Zed port.
    license: "BSD-3-Clause",
    license_file: "themes/birds-of-paradise.LICENSE"
  },
  # catppuccin/catppuccin's palette, mapped after catppuccin/nvim.
  mit.("catppuccin-latte", "Catppuccin Latte"),
  mit.("catppuccin-mocha", "Catppuccin Mocha"),
  # dracula/dracula-theme's palette, mapped after dracula/vim.
  mit.("dracula", "Dracula"),
  # morhetz/gruvbox's palette, mapped after ellisonleao/gruvbox.nvim.
  mit.("gruvbox-dark", "Gruvbox Dark"),
  mit.("gruvbox-light", "Gruvbox Light"),
  # rebelot/kanagawa.nvim, the wave variant.
  mit.("kanagawa", "Kanagawa"),
  # nordtheme/nord's palette, mapped after nordtheme/vim: no GPL port.
  mit.("nord", "Nord"),
  # Atom's own one-dark-syntax and one-light-syntax, at atom/atom's final commit.
  mit.("one-dark", "One Dark"),
  mit.("one-light", "One Light"),
  # rose-pine/rose-pine-palette, mapped after rose-pine/neovim.
  mit.("rose-pine", "Rosé Pine"),
  mit.("rose-pine-dawn", "Rosé Pine Dawn"),
  # altercation/solarized's 16 colours, mapped after its vim-colors-solarized.
  mit.("solarized-dark", "Solarized Dark"),
  mit.("solarized-light", "Solarized Light"),
  # The MIT VS Code theme (tokyo-night/tokyo-night-vscode-theme); the Apache-2.0 Neovim port is
  # not used.
  mit.("tokyo-night", "Tokyo Night")
]
