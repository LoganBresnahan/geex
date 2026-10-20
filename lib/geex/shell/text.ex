defmodule Geex.Shell.Text do
  @moduledoc """
  What a shell command's output becomes before the output pane shows it
  ([ADR-0042](../../../doc/adr/0042-shell-commands.md)). Pure.

  The command runs without a terminal (`TERM=dumb`), but programs still print escape sequences:
  colours, cursor moves, titles. In v1 they are removed, not interpreted (`clean/1`). A program
  that switches to the alternate screen wants a real terminal, and is stopped
  (`alt_screen?/1`). A line naming `path:line[:col]` can be opened from the pane
  (`location/1`).
  """

  # The switches to the alternate screen: xterm's 1049, and the older 47 and 1047.
  @alt_screen ["\e[?1049h", "\e[?1047h", "\e[?47h"]

  @doc """
  Whether `bytes` switch to the alternate screen. Give it the previous chunk's last
  `overlap/0` bytes too: a switch can be split across two chunks.

      iex> Geex.Shell.Text.alt_screen?("vim\\e[?1049h\\e[H")
      true
      iex> Geex.Shell.Text.alt_screen?("\\e[31mred\\e[0m")
      false
  """
  @spec alt_screen?(binary()) :: boolean()
  def alt_screen?(bytes), do: String.contains?(bytes, @alt_screen)

  # Programs that take over a terminal. Under `TERM=dumb` most never send the alternate-screen
  # switch (the dumb terminal has none), and wait for keys they can't get: vim draws a frame and
  # sits. So these aren't started at all.
  @full_screen ~w(vi vim nvim view vimdiff nano pico emacs top htop btop atop watch tmux screen
                  ssh mosh mc ranger nnn fzf tig lazygit)

  @doc """
  Whether `cmd` runs a program that takes over the terminal (an editor, a monitor, a
  multiplexer, `ssh`, `fzf`), judged by its first word, after any `NAME=value` settings.

      iex> Geex.Shell.Text.full_screen?("EDITOR=x vim notes.txt")
      true
      iex> Geex.Shell.Text.full_screen?("git log --oneline | head")
      false
  """
  @spec full_screen?(String.t()) :: boolean()
  def full_screen?(cmd) do
    cmd
    |> String.split()
    |> Enum.drop_while(&String.match?(&1, ~r/^[A-Za-z_][A-Za-z0-9_]*=/))
    |> case do
      [program | _] -> Path.basename(program) in @full_screen
      [] -> false
    end
  end

  @doc "The alternate-screen switches as a compiled pattern, for `:binary.match/2` on a stream."
  @spec alt_screen_pattern() :: :binary.cp()
  def alt_screen_pattern, do: :binary.compile_pattern(@alt_screen)

  @doc "How many bytes of a chunk to keep for `alt_screen?/1` on the next one."
  @spec overlap() :: pos_integer()
  def overlap, do: byte_size("\e[?1049h") - 1

  # Every byte below a space, and DEL: a line without them needs no cleaning.
  @controls Enum.map(Enum.to_list(0..31) ++ [127], &<<&1>>)

  @doc """
  One line of output as text to show: escape sequences removed (CSI, OSC, and two-byte ones), a
  carriage return keeping only what was written after it (a progress bar's last state), tabs
  expanded to every 8 columns, other control characters dropped, and bytes that aren't UTF-8
  replaced. `line` has no newline.

      iex> Geex.Shell.Text.clean("\\e[1;31merror\\e[0m: bad")
      "error: bad"
      iex> Geex.Shell.Text.clean("10%\\r55%\\r100% done")
      "100% done"
      iex> Geex.Shell.Text.clean("\\e]0;title\\aa\\tb")
      "a       b"
  """
  @spec clean(binary()) :: String.t()
  def clean(line) do
    # Most lines are plain: no control byte at all, and UTF-8. They are what they show.
    if :binary.match(line, controls()) == :nomatch and String.valid?(line),
      do: line,
      else: clean_up(line)
  end

  # The control bytes as a compiled pattern, made once: compiling it on every line cost more
  # than cleaning the line (measured 2026-10-19: 18.7 ms against 0.5 ms for 5,000 lines).
  defp controls do
    case :persistent_term.get({__MODULE__, :controls}, nil) do
      nil ->
        cp = :binary.compile_pattern(@controls)
        :persistent_term.put({__MODULE__, :controls}, cp)
        cp

      cp ->
        cp
    end
  end

  defp clean_up(line) do
    line
    |> strip_escapes()
    |> String.trim_trailing("\r")
    |> last_overwrite()
    |> String.replace_invalid()
    |> expand_tabs()
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F]/, "")
  end

  # CSI (ESC [ … final), OSC (ESC ] … BEL or ESC \), a charset or other ESC + intermediates +
  # final, and a lone ESC left at the end.
  @escapes ~r/\e\[[0-?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\|$)|\e[ -\/]*[0-~]|\e$/

  defp strip_escapes(line), do: String.replace(line, @escapes, "")

  defp last_overwrite(line), do: line |> String.split("\r") |> List.last()

  defp expand_tabs(line) do
    if String.contains?(line, "\t") do
      line
      |> String.split("\t")
      |> Enum.reduce(fn part, acc ->
        acc <> String.duplicate(" ", 8 - rem(String.length(acc), 8)) <> part
      end)
    else
      line
    end
  end

  @doc """
  The first `path:line` or `path:line:col` in a line of output, as compilers, test runners and
  grep print them: `{path, line, col}`, `col` nil when absent. Lines and columns are 1-based as
  printed. A URL's `host:port` is not one.

      iex> Geex.Shell.Text.location("** (CompileError) lib/geex/loop.ex:120:5: undefined")
      {"lib/geex/loop.ex", 120, 5}
      iex> Geex.Shell.Text.location("test/a_test.exs:12")
      {"test/a_test.exs", 12, nil}
      iex> Geex.Shell.Text.location("listening on http://localhost:4000")
      nil
  """
  @spec location(String.t()) :: {String.t(), pos_integer(), pos_integer() | nil} | nil
  def location(line) do
    ~r"(?<![\w./~-])((?:~|\.{1,2})?/?[\w.\-+@]+(?:/[\w.\-+@]+)*):(\d+)(?::(\d+))?"
    |> Regex.scan(line)
    |> Enum.find_value(fn
      [whole | [path, l | col]] ->
        if url?(line, whole) or path in [".", ".."] do
          nil
        else
          {path, String.to_integer(l), col_of(col)}
        end
    end)
  end

  defp col_of([c]) when c != "", do: String.to_integer(c)
  defp col_of(_), do: nil

  # `host:port` after `//`.
  defp url?(line, whole), do: String.contains?(line, "//" <> whole)
end
