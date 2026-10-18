defmodule Geex.Catalog.Package do
  @moduledoc """
  A catalog package's file ([ADR-0040](../../../doc/adr/0040-bare-geex-and-the-catalog.md) §4): a
  zip of a grammar's `parser.wasm`, `highlights.scm`, `manifest.json` and licence, or a theme's
  JSON, `manifest.json` and licence. Pure.

  The zip is **deterministic**: entries sorted by name, each with the same fixed time, so the
  same files always make the same bytes, the same sha256 and the same asset name. Rebuilding
  a package that didn't change names the asset already uploaded.
  """

  # Every entry's modification time: zip keeps local time with two-second precision.
  @mtime {{2026, 1, 1}, {0, 0, 0}}

  @doc """
  Zip `files` (`{name, bytes}`) into a binary.

      iex> alias Geex.Catalog.Package
      iex> a = Package.zip([{"b.txt", "2"}, {"a.txt", "1"}])
      iex> a == Package.zip([{"a.txt", "1"}, {"b.txt", "2"}])
      true
  """
  @spec zip([{String.t(), binary()}]) :: binary()
  def zip(files) do
    entries =
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, bytes} -> {String.to_charlist(name), bytes, info(bytes)} end)

    {:ok, {_name, zip}} = :zip.create(~c"package.zip", entries, [:memory])
    zip
  end

  defp info(bytes) do
    %File.Stat{
      size: byte_size(bytes),
      type: :regular,
      access: :read_write,
      atime: @mtime,
      mtime: @mtime,
      ctime: @mtime,
      mode: 0o100644,
      links: 1,
      major_device: 0,
      minor_device: 0,
      inode: 0,
      uid: 0,
      gid: 0
    }
    |> File.Stat.to_record()
  end

  @doc """
  The sha256 of `bytes`, as 64 lowercase hex characters.

      iex> Geex.Catalog.Package.sha256("")
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  """
  @spec sha256(binary()) :: String.t()
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc """
  A package's asset name: its kind, its name and the first 12 hex of its sha256, so a changed
  package never takes an older one's name.

      iex> Geex.Catalog.Package.asset_name(:grammar, "rust", String.duplicate("ab", 32))
      "grammar-rust-abababababab.zip"
  """
  @spec asset_name(:grammar | :theme, String.t(), String.t()) :: String.t()
  def asset_name(kind, name, sha256), do: "#{kind}-#{name}-#{binary_part(sha256, 0, 12)}.zip"

  @doc """
  The tree-sitter language ABI a grammar's generated `parser.c` declares, or `:error`.

      iex> Geex.Catalog.Package.abi("#define TREE_SITTER_X\\n#define LANGUAGE_VERSION 14\\n")
      {:ok, 14}
  """
  @spec abi(String.t()) :: {:ok, pos_integer()} | :error
  def abi(parser_c) do
    case Regex.run(~r/^#define LANGUAGE_VERSION (\d+)$/m, parser_c) do
      [_, n] -> {:ok, String.to_integer(n)}
      nil -> :error
    end
  end
end
