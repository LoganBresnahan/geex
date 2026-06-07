defmodule Geex.PresetsTest do
  @moduledoc """
  Teeth for the checked-in per-harness presets (ADR-0016, Rung 1). These files are
  config in *another tool's* version-sensitive schema, so the value here is pinning the
  invariants geex relies on — and the ADR-0016 *design decisions* — so a well-meaning
  edit that drifts them trips a test:

    * the MCP endpoint is **loopback only** (a checked-in preset must never point a harness
      at an off-host address) and matches geex's serve default (`/mcp` on :4000);
    * the deny-list covers geex's replaceable **structured writers** — and *deliberately*
      does **not** deny Bash (shell/subprocess writes are Rung 0 reconcile's job, not the
      preset's — ADR-0016 §3) nor Read (reads must keep working).
  """
  use ExUnit.Case, async: true

  @claude_code "presets/claude-code"

  describe "claude-code .mcp.json (points the harness at geex over loopback)" do
    setup do
      %{geex: Path.join(@claude_code, ".mcp.json") |> File.read!() |> JSON.decode!()}
    end

    test "registers a single `geex` HTTP MCP server", %{geex: mcp} do
      assert %{"mcpServers" => %{"geex" => server}} = mcp
      # Streamable HTTP transport — the exact `type` Claude Code expects (ADR-0018).
      assert server["type"] == "http"
    end

    test "the endpoint is loopback `/mcp` on the serve default port", %{geex: mcp} do
      uri = mcp["mcpServers"]["geex"]["url"] |> URI.parse()

      # Never a non-loopback host in a committed preset — it binds nothing off-host can reach.
      assert uri.host in ~w(127.0.0.1 localhost ::1)
      assert uri.path == "/mcp"
      # Bound to geex's single-source default port (not a bare literal), so the preset can't
      # silently drift off the port a default-served geex actually listens on.
      assert uri.port == Geex.Application.default_http_mcp_port()
    end
  end

  describe "claude-code .claude/settings.json (denies the harness's structured writers)" do
    setup do
      deny =
        Path.join(@claude_code, ".claude/settings.json")
        |> File.read!()
        |> JSON.decode!()
        |> get_in(["permissions", "deny"])

      %{deny: deny}
    end

    test "denies every structured file-writer geex's tools replace", %{deny: deny} do
      # The coverage gate is met (create/edit/delete/rename over MCP), so these are safe to
      # deny — they route the harness to geex instead. Casing is exact (Claude Code tools).
      # `MultiEdit` is legacy (a separate tool in Claude Code ≤1.x, folded into `Edit` in 2.0)
      # — kept as a defensive back-compat deny and pinned here so the entry can't silently
      # vanish from the preset. ALL four are asserted: an un-pinned deny entry reads as
      # covered while a drifting edit could quietly re-open a structured-writer path.
      for tool <- ~w(Write Edit MultiEdit NotebookEdit), do: assert(tool in deny)
    end

    test "does NOT deny Bash — shell writes are Rung 0 reconcile's job, by design", %{deny: deny} do
      # ADR-0016 §3: Rung 1 does not close the subprocess-write gap; chasing shell writes
      # here is futile and breaks legitimate shell use. If someone adds a `Bash(...)` deny,
      # this fails on purpose — re-read the ADR before "tightening" the preset.
      refute Enum.any?(deny, &String.starts_with?(&1, "Bash"))
    end

    test "does NOT deny reads", %{deny: deny} do
      refute "Read" in deny
    end
  end
end
