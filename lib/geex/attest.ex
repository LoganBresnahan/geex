defmodule Geex.Attest do
  @moduledoc """
  The attestation intake (ADR-0032): a hook payload, outside geex and in the agent's loop
  (captAInHook), tells geex which agent made a write, and geex upgrades the matching
  `:external` reconcile group's actor.

  The message, version 1 (unknown fields are ignored):

      {"v": 1, "path": "/abs/file",
       "before": "<sha256>", "sha256": "<sha256>",
       "harness": "claude-code", "session": "…",
       "turn": "…", "tool_use": "…"}

  `before` and `sha256` are **exactly 64 lowercase hex characters** (what `sha256sum`
  prints). `before` is the file's contents before the call; it is absent only for a file the
  call created, which can't match. `turn` and `tool_use` are optional. Anything else is
  rejected rather than accepted as a hash that could never match.

  `parse/1` is pure; `submit/1` routes a parsed attestation to the buffer open on `path`
  (`Geex.Buffer.attest/2`). A path geex doesn't have open is not geex's to record.
  """

  alias Geex.{Buffer, BufferSupervisor}

  require Logger

  @type t :: %{
          path: String.t(),
          before: String.t() | nil,
          sha256: String.t(),
          harness: String.t(),
          session: String.t(),
          turn: String.t() | nil,
          tool_use: String.t() | nil
        }

  @hex ~r/\A[0-9a-f]{64}\z/

  @doc """
  Validate a decoded JSON message into an attestation.

      iex> {:ok, a} = Geex.Attest.parse(%{"v" => 1, "path" => "/f", "sha256" => String.duplicate("a", 64),
      ...>   "before" => String.duplicate("b", 64), "harness" => "claude-code", "session" => "s1"})
      iex> {a.path, a.turn}
      {"/f", nil}

      iex> Geex.Attest.parse(%{"v" => 1, "path" => "/f", "sha256" => "ABC"})
      {:error, "sha256 must be 64 lowercase hex characters"}
  """
  @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
  def parse(%{"v" => 1} = msg) do
    with {:ok, path} <- required_string(msg, "path"),
         :ok <- absolute(path),
         {:ok, sha256} <- hash(msg, "sha256", :required),
         {:ok, before} <- hash(msg, "before", :optional),
         {:ok, harness} <- required_string(msg, "harness"),
         {:ok, session} <- required_string(msg, "session"),
         {:ok, turn} <- optional_string(msg, "turn"),
         {:ok, tool_use} <- optional_string(msg, "tool_use") do
      {:ok,
       %{
         path: path,
         before: before,
         sha256: sha256,
         harness: harness,
         session: session,
         turn: turn,
         tool_use: tool_use
       }}
    end
  end

  def parse(%{"v" => v}), do: {:error, "unsupported version #{inspect(v)}"}
  def parse(_), do: {:error, "expected a JSON object with \"v\": 1"}

  @doc """
  Hand a parsed attestation to the buffer open on its path. Returns the buffer's answer
  (`:attested` / `:held` / `:ignored`) or `:not_open`. The payload spools `held` and `not_open`
  (ADR-0034): neither has been recorded yet.
  """
  @spec submit(t()) :: :attested | :held | :ignored | :not_open
  def submit(%{path: path} = attestation) do
    case BufferSupervisor.whereis(Path.expand(path)) do
      {:ok, pid} -> pid |> Buffer.attest(attestation) |> log(attestation)
      _ -> :not_open
    end
  catch
    # The buffer can close between lookup and call; that's the same as not open.
    :exit, _ -> :not_open
  end

  defp log(:attested = result, a) do
    Logger.info("geex attest: #{a.path} attributed to #{a.harness} session #{a.session}")
    result
  end

  defp log(result, a) do
    Logger.debug("geex attest: #{a.path} #{result}")
    result
  end

  defp required_string(msg, key) do
    case msg[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} must be a non-empty string"}
    end
  end

  defp optional_string(msg, key) do
    case msg[key] do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} must be a non-empty string when present"}
    end
  end

  defp absolute(path) do
    if Path.type(path) == :absolute, do: :ok, else: {:error, "path must be absolute"}
  end

  defp hash(msg, key, presence) do
    case {msg[key], presence} do
      {nil, :optional} -> {:ok, nil}
      {value, _} when is_binary(value) -> check_hex(value, key)
      _ -> {:error, "#{key} must be 64 lowercase hex characters"}
    end
  end

  defp check_hex(value, key) do
    if Regex.match?(@hex, value),
      do: {:ok, value},
      else: {:error, "#{key} must be 64 lowercase hex characters"}
  end
end
