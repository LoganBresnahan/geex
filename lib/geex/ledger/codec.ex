defmodule Geex.Ledger.Codec do
  @moduledoc """
  The durable ledger's line format (ADR-0033 §2): one history transition per JSON line.

  An entry, in memory:

    * `{:open, %{path, base, geex, at}}` — the first line: the base text the history starts from
    * `{:cmd, command}` — a dispatched command
    * `{:group, commands, baseline}` / `{:gap, commands, baseline}` — an atomic group, or the
      group reopening recorded for a disk change made while geex was closed. `baseline` is
      `:none` (no re-sync), `:result` (disk equals the text after the group), or the disk text
      itself (a merge that left the buffer dirty)
    * `:undo` / `:redo`
    * `{:attest, group, actor}` — an attestation took effect
    * `{:sync, sha256}` — disk now matches the buffer; the sha256 of the bytes written
    * `{:rename, path}`
    * `{:close, %{text_sha256, synced_sha256}}` — a clean close

  On disk every line is `{"v": 1, "t": <type>, "at": <ISO-8601>, …}`. Commands are values
  (ADR-0002/0004): `args` are the struct's field-spec fields, and decoding goes through the
  command's real `parse/1`. A string that isn't valid UTF-8 (a file's raw bytes can be
  anything) is stored as `{"$b64": …}` so every byte survives. Pure.
  """

  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.Commands.{Delete, Edit, Insert, Replace}

  @version 1

  @commands Map.new([Insert, Delete, Replace, Edit], &{Atom.to_string(&1.__command__().name), &1})

  @agent_keys %{
    "harness" => :harness,
    "session" => :session,
    "turn" => :turn,
    "tool_use" => :tool_use
  }
  @stamp_keys %{
    "group" => :group,
    "before_sha256" => :before_sha256,
    "before_sha256_lf" => :before_sha256_lf,
    "sha256" => :sha256,
    "chain" => :chain
  }

  @type baseline :: :none | :result | String.t()
  @type entry ::
          {:open, map()}
          | {:cmd, struct()}
          | {:group | :gap, [struct()], baseline()}
          | :undo
          | :redo
          | {:attest, pos_integer(), Meta.actor()}
          | {:sync, String.t()}
          | {:rename, String.t()}
          | {:close, map()}

  @doc "One ledger line for `entry`, stamped `at`, ending in a newline."
  @spec encode(entry(), DateTime.t()) :: String.t()
  def encode(entry, %DateTime{} = at) do
    entry
    |> fields()
    |> Map.merge(%{"v" => @version, "at" => DateTime.to_iso8601(at)})
    |> JSON.encode!()
    |> Kernel.<>("\n")
  end

  @doc """
  Decode one ledger line (without its newline). `{:error, reason}` for anything that isn't a
  version-1 entry this geex knows.
  """
  @spec decode(String.t()) :: {:ok, entry()} | {:error, String.t()}
  def decode(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, %{"v" => @version, "t" => type} = map} -> entry(type, map)
      {:ok, %{"v" => v}} -> {:error, "unsupported ledger version #{inspect(v)}"}
      {:ok, _} -> {:error, "not a ledger entry"}
      {:error, _} -> {:error, "malformed JSON"}
    end
  end

  # --- encode ---

  defp fields({:open, %{path: path, base: base, geex: geex}}),
    do: %{"t" => "open", "path" => path, "base" => text(base), "geex" => geex}

  defp fields({:cmd, command}), do: %{"t" => "cmd", "cmd" => command_json(command)}

  defp fields({kind, commands, baseline}) when kind in [:group, :gap] do
    %{
      "t" => Atom.to_string(kind),
      "cmds" => Enum.map(commands, &command_json/1),
      "baseline" => baseline_json(baseline)
    }
  end

  defp fields(:undo), do: %{"t" => "undo"}
  defp fields(:redo), do: %{"t" => "redo"}

  defp fields({:attest, group, actor}),
    do: %{"t" => "attest", "group" => group, "actor" => actor_json(actor)}

  defp fields({:sync, sha256}), do: %{"t" => "sync", "sha256" => sha256}
  defp fields({:rename, path}), do: %{"t" => "rename", "path" => path}

  defp fields({:close, %{text_sha256: text, synced_sha256: synced}}),
    do: %{"t" => "close", "text_sha256" => text, "synced_sha256" => synced}

  defp command_json(%module{} = command) do
    names = Enum.map(module.__fields__(), & &1.name)

    %{
      "name" => Atom.to_string(module.__command__().name),
      "args" => command |> Map.take(names) |> json_safe(),
      "meta" => meta_json(command.meta)
    }
  end

  defp meta_json(%Meta{} = meta) do
    %{
      "actor" => actor_json(meta.actor),
      "at" => meta.at && DateTime.to_iso8601(meta.at),
      "prompt_hash" => meta.prompt_hash,
      "origin" => meta.origin && %{"turn_id" => meta.origin.turn_id, "seq" => meta.origin.seq},
      "reconcile" =>
        meta.reconcile && Map.new(meta.reconcile, fn {k, v} -> {Atom.to_string(k), v} end),
      "reverts" =>
        meta.reverts &&
          %{"group" => meta.reverts.group, "scope" => Atom.to_string(meta.reverts.scope)}
    }
  end

  defp actor_json(:human), do: "human"
  defp actor_json(:external), do: "external"
  defp actor_json({:llm, model}), do: %{"llm" => model}
  defp actor_json({:extension, id}), do: %{"extension" => to_string(id)}

  defp actor_json({:agent, who}) when is_map(who),
    do: %{"agent" => Map.new(who, fn {k, v} -> {Atom.to_string(k), v} end)}

  defp baseline_json(:none), do: nil
  defp baseline_json(:result), do: "result"
  defp baseline_json(text) when is_binary(text), do: %{"text" => text(text)}

  defp text(binary) do
    if String.valid?(binary), do: binary, else: %{"$b64" => Base.encode64(binary)}
  end

  defp json_safe(binary) when is_binary(binary), do: text(binary)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)

  defp json_safe(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), json_safe(v)} end)

  defp json_safe(other), do: other

  # --- decode ---

  defp entry("open", %{"path" => path, "base" => base, "geex" => geex}) do
    with {:ok, base} <- untext(base), do: {:ok, {:open, %{path: path, base: base, geex: geex}}}
  end

  defp entry("cmd", %{"cmd" => cmd}) do
    with {:ok, command} <- command(cmd), do: {:ok, {:cmd, command}}
  end

  defp entry(kind, %{"cmds" => cmds, "baseline" => baseline}) when kind in ["group", "gap"] do
    with {:ok, commands} <- all(cmds, &command/1),
         {:ok, baseline} <- baseline(baseline) do
      {:ok, {String.to_existing_atom(kind), commands, baseline}}
    end
  end

  defp entry("undo", _), do: {:ok, :undo}
  defp entry("redo", _), do: {:ok, :redo}

  defp entry("attest", %{"group" => group, "actor" => actor}) when is_integer(group) do
    with {:ok, actor} <- actor(actor), do: {:ok, {:attest, group, actor}}
  end

  defp entry("sync", %{"sha256" => sha}) when is_binary(sha), do: {:ok, {:sync, sha}}
  defp entry("rename", %{"path" => path}) when is_binary(path), do: {:ok, {:rename, path}}

  defp entry("close", %{"text_sha256" => text, "synced_sha256" => synced}),
    do: {:ok, {:close, %{text_sha256: text, synced_sha256: synced}}}

  defp entry(type, _), do: {:error, "unknown or incomplete entry #{inspect(type)}"}

  defp command(%{"name" => name, "args" => args, "meta" => meta}) do
    with {:ok, module} <- module(name),
         {:ok, args} <- unjson(args),
         {:ok, command} <- module.parse(args),
         {:ok, meta} <- meta(meta) do
      {:ok, Command.put_meta(command, meta)}
    end
  end

  defp command(_), do: {:error, "malformed command"}

  defp module(name) do
    case Map.fetch(@commands, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "unknown command #{inspect(name)}"}
    end
  end

  defp meta(%{"actor" => actor} = m) do
    with {:ok, actor} <- actor(actor),
         {:ok, at} <- datetime(m["at"]),
         {:ok, origin} <- origin(m["origin"]),
         {:ok, stamp} <- stamp(m["reconcile"]),
         {:ok, reverts} <- reverts(m["reverts"]) do
      {:ok,
       %Meta{
         actor: actor,
         at: at,
         prompt_hash: m["prompt_hash"],
         origin: origin,
         reconcile: stamp,
         reverts: reverts
       }}
    end
  end

  defp meta(_), do: {:error, "malformed meta"}

  defp actor("human"), do: {:ok, :human}
  defp actor("external"), do: {:ok, :external}
  defp actor(%{"llm" => model}) when is_binary(model), do: {:ok, {:llm, model}}
  defp actor(%{"extension" => id}) when is_binary(id), do: {:ok, {:extension, id}}

  defp actor(%{"agent" => who}) when is_map(who) do
    {:ok, {:agent, for({k, v} <- who, key = @agent_keys[k], into: %{}, do: {key, v})}}
  end

  defp actor(other), do: {:error, "unknown actor #{inspect(other)}"}

  defp datetime(nil), do: {:ok, nil}

  defp datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, "bad timestamp"}
    end
  end

  defp origin(nil), do: {:ok, nil}
  defp origin(%{"turn_id" => turn, "seq" => seq}), do: {:ok, %{turn_id: turn, seq: seq}}
  defp origin(_), do: {:error, "malformed origin"}

  defp stamp(nil), do: {:ok, nil}

  defp stamp(map) when is_map(map),
    do: {:ok, for({k, v} <- map, key = @stamp_keys[k], into: %{}, do: {key, v})}

  defp reverts(nil), do: {:ok, nil}

  defp reverts(%{"group" => group, "scope" => scope})
       when is_integer(group) and scope in ["hunk", "call"],
       do: {:ok, %{group: group, scope: String.to_existing_atom(scope)}}

  defp reverts(_), do: {:error, "malformed reverts"}

  defp baseline(nil), do: {:ok, :none}
  defp baseline("result"), do: {:ok, :result}
  defp baseline(%{"text" => text}), do: untext(text)
  defp baseline(_), do: {:error, "malformed baseline"}

  defp untext(binary) when is_binary(binary), do: {:ok, binary}

  defp untext(%{"$b64" => b64}) do
    case Base.decode64(b64) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, "bad base64"}
    end
  end

  defp untext(_), do: {:error, "malformed text"}

  defp unjson(%{"$b64" => _} = b64), do: untext(b64)
  defp unjson(binary) when is_binary(binary), do: {:ok, binary}
  defp unjson(list) when is_list(list), do: all(list, &unjson/1)

  defp unjson(map) when is_map(map) do
    with {:ok, pairs} <- all(Map.to_list(map), fn {k, v} -> wrap(k, unjson(v)) end),
         do: {:ok, Map.new(pairs)}
  end

  defp unjson(other), do: {:ok, other}

  defp wrap(k, {:ok, v}), do: {:ok, {k, v}}
  defp wrap(_k, error), do: error

  defp all(list, fun) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp all(_other, _fun), do: {:error, "expected a list"}
end
