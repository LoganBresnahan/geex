defmodule Geex.MCP.Protocol do
  @moduledoc """
  The pure MCP/JSON-RPC core (mcp-ai-integration.md §4 / §11) — the single
  highest-value thing ported from pharos: **protocol logic as a pure function**,
  unit-testable with plain strings, no process or socket of its own.

  `handle_line/1` takes one decoded NDJSON line and returns one of three outcomes
  (all load-bearing JSON-RPC truths):

    * `{:reply, iodata}`      — a request (`id` present): write this frame back.
    * `:noreply`              — a notification (no `id`): never gets a response.
    * `{:protocol_error, iodata}` — malformed input still needs an error frame,
      with `id: null` when no id could be recovered.

  Methods: `initialize` (negotiate protocol version), `notifications/initialized`
  and `notifications/cancelled` (ack, no reply), `tools/list` (projected from the
  command registry via `Geex.MCP.Schema`), `tools/call` (the same `parse/1` +
  the same `Geex.Dispatch.run/1` a human hits), `ping` (`{}` — pharos omits this;
  geex does not). Unknown methods → `-32601`. Any handler fault — a raise, or a
  dependency process (registry/session/buffer) being down — is contained as a
  `-32603` internal-error frame; `handle_line/1` never crashes the process running
  it (the three-outcome contract is total).

  Dependency-free (Elixir's built-in `JSON`). The transport layer
  ([adr/0018](../../doc/adr/0018-mcp-transport-streamable-http.md)) frames lines to
  and from this function; it is the same core whether the bytes arrive over stdio
  (CI) or loopback HTTP (live).
  """

  alias Geex.Command
  alias Geex.Command.Meta
  alias Geex.{CommandRegistry, Dispatch}
  alias Geex.MCP.Schema

  # The MCP revision geex implements (§11). Negotiated against the client's request;
  # the preferred (latest) supported version is the fallback. 2025-11-25 is current;
  # 2025-06-18 is kept for back-compat.
  @protocol_version "2025-11-25"
  @supported_versions ["2025-11-25", "2025-06-18"]

  # Placeholder authorship for an MCP tool-call. The edit genuinely arrived through
  # the LLM tool door (so `{:llm, _}` is honest), but the *model* and the turn id are
  # connection state this stateless core doesn't see — the session-aware transport
  # threads the real `clientInfo`/turn through later (ADR-0012: never fabricate, but
  # an LLM-via-MCP edit is honestly LLM-authored).
  @mcp_model "unknown"

  @type outcome :: {:reply, iodata()} | :noreply | {:protocol_error, iodata()}

  @doc "Handle one decoded JSON-RPC line. See the moduledoc for the three outcomes."
  @spec handle_line(String.t()) :: outcome()
  def handle_line(line) when is_binary(line) do
    case JSON.decode(line) do
      {:error, _} ->
        {:protocol_error, error_frame(nil, -32700, "Parse error")}

      {:ok, msg} when is_map(msg) ->
        if Map.has_key?(msg, "id"),
          do: {:reply, handle_request(msg)},
          else: handle_notification(msg)

      {:ok, _not_an_object} ->
        {:protocol_error, error_frame(nil, -32600, "Invalid Request")}
    end
  end

  # --- requests (have an id; always get a frame) ---

  defp handle_request(%{"id" => id} = msg) do
    result =
      case Map.get(msg, "method") do
        method when is_binary(method) -> route(method, Map.get(msg, "params") || %{})
        nil -> {:error, -32600, ~s(Invalid Request: missing "method")}
        _ -> {:error, -32600, ~s(Invalid Request: "method" must be a string)}
      end

    encode(id, result)
  rescue
    # A handler that raises (or whose dependency GenServer — CommandRegistry,
    # Session, Buffer — is down) must still yield a frame, never crash the process
    # running the protocol. This is the §11 -32603 path. Kept narrow: the pure
    # envelope logic (decode/classify/encode) lives in handle_line/1, outside this
    # try, so its bugs still surface in tests rather than being masked.
    exception -> error_frame(id, -32603, "Internal error: #{Exception.message(exception)}")
  catch
    :exit, _reason -> error_frame(id, -32603, "Internal error")
    kind, value -> error_frame(id, -32603, "Internal error: #{inspect({kind, value})}")
  end

  defp route("initialize", params), do: initialize_result(params)
  defp route("tools/list", _params), do: tools_list()
  defp route("tools/call", params), do: tool_call(params)
  defp route("ping", _params), do: %{}
  defp route(other, _params), do: {:error, -32601, "Method not found: #{other}"}

  # --- notifications (no id; never get a response) ---

  # notifications/initialized and notifications/cancelled are acked by silence;
  # cancellation is a no-op in v0.5 (§12). Any other notification is ignored.
  defp handle_notification(_msg), do: :noreply

  # --- method handlers ---

  defp initialize_result(params) do
    requested = if is_map(params), do: params["protocolVersion"], else: nil

    %{
      "protocolVersion" => negotiate(requested),
      # tools only; no listChanged claim — v0.5 does not emit it (§11/§12).
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "geex", "version" => version()}
    }
  end

  defp negotiate(v) when is_binary(v), do: if(v in @supported_versions, do: v, else: @protocol_version)
  defp negotiate(_), do: @protocol_version

  defp tools_list do
    modules = Enum.map(CommandRegistry.all(), & &1.module)
    %{"tools" => Schema.tools(modules)}
  end

  defp tool_call(%{"name" => name} = params) when is_binary(name) do
    args = Map.get(params, "arguments", %{})

    case lookup_tool(name) do
      {:ok, module} -> call_command(module, args)
      :error -> {:error, -32602, "Unknown tool: #{name}"}
    end
  end

  defp tool_call(_params), do: {:error, -32602, "Invalid params: \"name\" (string) is required"}

  defp call_command(module, args) when is_map(args) do
    case module.parse(args) do
      {:error, why} ->
        # A found tool with invalid ARGUMENTS is a tool-execution error (isError:true)
        # so the model sees it and self-corrects (MCP 2025-11-25, SEP-1303) — not a
        # JSON-RPC error. Protocol faults (unknown tool, malformed call) stay -32602.
        tool_result("Invalid arguments: #{why}", true)

      {:ok, command} ->
        command = Command.put_meta(command, Meta.llm(@mcp_model))

        case Dispatch.run(command) do
          {:ok, snapshot} -> tool_result(snapshot.text, false)
          {:error, reason} -> tool_result("error: #{inspect(reason)}", true)
        end
    end
  end

  defp call_command(_module, _args),
    do: {:error, -32602, ~s(Invalid params: "arguments" must be an object)}

  # An unknown tool name may not even be an existing atom — that is still just an
  # unknown tool, not a crash.
  defp lookup_tool(name) do
    CommandRegistry.lookup(String.to_existing_atom(name))
  rescue
    ArgumentError -> :error
  end

  # --- frame encoding ---

  # A tool result rides a JSON-RPC *success*; tool failure is `isError: true` in the
  # result, not a JSON-RPC error (which is reserved for protocol faults). §11.
  defp tool_result(text, is_error?) do
    %{"content" => [%{"type" => "text", "text" => text}], "isError" => is_error?}
  end

  defp encode(id, {:error, code, message}), do: error_frame(id, code, message)
  defp encode(id, result), do: result_frame(id, result)

  defp result_frame(id, result) do
    JSON.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp error_frame(id, code, message) do
    JSON.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp version, do: to_string(Application.spec(:geex, :vsn) || ~c"0.1.0")
end
