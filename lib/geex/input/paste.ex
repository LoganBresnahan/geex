defmodule Geex.Input.Paste do
  @moduledoc """
  A bracketed paste on its way in ([ADR-0026](../../../doc/adr/0026-terminal-input-model.md)'s
  2026-11-09 amendment, roadmap item 19): the bytes after `ESC [ 200 ~`, gathered until
  `ESC [ 201 ~` arrives, however many reads it takes.

  `Geex.Input.Parser` reads a paste that arrives whole; one that doesn't is handed here by
  `Geex.TerminalIO`, which feeds it each read. Each read is searched for the end only with the
  last few bytes before it (a marker split across reads), never the whole paste again, and the
  chunks are kept as a list joined once, so a paste costs what its size does. Past `@chunk` bytes
  with no end, what came is handed on as a paste of its own (cut where no character or CRLF is
  split), so the rest of a huge paste is never typed as keys. Pure.
  """

  @end_marker "\e[201~"
  # Bytes of a paste handed on at once when its end hasn't come.
  @chunk 1024 * 1024

  defstruct chunks: [], size: 0, tail: <<>>

  @type t :: %__MODULE__{chunks: [binary()], size: non_neg_integer(), tail: binary()}
  @type result :: {:more, t(), [{:paste, String.t()}]} | {:done, [{:paste, String.t()}], binary()}

  @doc """
  Start from a parser leftover that is a paste's start (`Geex.Input.Parser.paste?/1`).

      iex> {:more, p, []} = Geex.Input.Paste.start("\\e[200~half")
      iex> Geex.Input.Paste.feed(p, " a line\\e[201~x")
      {:done, [{:paste, "half a line"}], "x"}
  """
  @spec start(binary()) :: result()
  def start(<<"\e[200~", body::binary>>), do: feed(%__MODULE__{}, body)

  @doc """
  Feed the bytes of a read: `{:done, events, rest}` once the end came (`rest` is what followed
  it, input as usual), else `{:more, paste, events}` (`events` a chunk handed on early, or none).

      iex> {:more, p, []} = Geex.Input.Paste.start("\\e[200~ab\\e[2")
      iex> Geex.Input.Paste.feed(p, "01~")
      {:done, [{:paste, "ab"}], ""}
  """
  @spec feed(t(), binary()) :: result()
  def feed(%__MODULE__{} = p, bytes) do
    window = p.tail <> bytes

    case :binary.match(window, @end_marker) do
      {at, len} ->
        full = IO.iodata_to_binary(Enum.reverse([bytes | p.chunks]))
        # The marker starts `byte_size(window) - at` bytes before `full`'s end.
        body = binary_part(full, 0, byte_size(full) - (byte_size(window) - at))
        rest = binary_part(window, at + len, byte_size(window) - at - len)
        {:done, events(body), rest}

      :nomatch ->
        p = %__MODULE__{
          chunks: [bytes | p.chunks],
          size: p.size + byte_size(bytes),
          tail: last(window, byte_size(@end_marker) - 1)
        }

        if p.size > @chunk, do: hand_on(p), else: {:more, p, []}
    end
  end

  @doc """
  The paste so far, its end never having come (a stalled or broken terminal).

      iex> {:more, p, []} = Geex.Input.Paste.start("\\e[200~half")
      iex> Geex.Input.Paste.finish(p)
      [{:paste, "half"}]
  """
  @spec finish(t()) :: [{:paste, String.t()}]
  def finish(%__MODULE__{chunks: chunks}),
    do: chunks |> Enum.reverse() |> IO.iodata_to_binary() |> events()

  # Past @chunk with no end: hand on all but the last few bytes, cut before a UTF-8 continuation
  # byte and after a lone CR, so neither a character nor a CRLF is split.
  defp hand_on(p) do
    full = p.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    cut = safe_cut(full, byte_size(full) - byte_size(@end_marker))
    kept = binary_part(full, cut, byte_size(full) - cut)
    p = %__MODULE__{chunks: [kept], size: byte_size(kept), tail: last(kept, 5)}
    {:more, p, events(binary_part(full, 0, cut))}
  end

  defp safe_cut(_full, cut) when cut <= 0, do: 0

  defp safe_cut(full, cut) do
    cond do
      Bitwise.band(:binary.at(full, cut), 0xC0) == 0x80 -> safe_cut(full, cut - 1)
      :binary.at(full, cut - 1) == ?\r -> safe_cut(full, cut - 1)
      true -> cut
    end
  end

  defp events(""), do: []
  defp events(body), do: [{:paste, String.replace_invalid(body)}]

  defp last(bin, n) when byte_size(bin) <= n, do: bin
  defp last(bin, n), do: binary_part(bin, byte_size(bin) - n, n)
end
