#!/bin/sh
# geex-attest — a ONESHOT captAInHook payload (geex ADR-0032, step d).
#
# Registered on PostToolUse. When an agent's writer tool changes a file, this tells
# every running geex which agent did it. geex has already shown the change (its file
# watcher records it as :external); if this message matches that change, geex relabels
# it with the agent's identity. It records; it never steers.
#
# The message (geex's Geex.Attest, v1), POSTed to each geex's loopback /attest:
#
#   {"v":1, "path", "before" | "created", "sha256", "harness", "session", "turn"?,
#    "tool_use"?, "user_modified"?}
#
#   before  sha256 of the file before the call, as the harness reports it
#           (claude-code: tool_response.originalFile, or original_file for NotebookEdit).
#           Claude Code reports a CRLF file's text with each "\r\n" as "\n"; geex
#           matches that form too, so it is sent as given.
#   created true, in place of before, when the call created the file (claude-code: a Write
#           whose tool_response.type is "create", with originalFile null). geex lists it as
#           the agent's; an open buffer credits it only from empty text.
#   sha256  sha256 of the file on disk now.
#   user_modified  true when you edited the agent's proposed change in the permission prompt
#           before accepting it (claude-code: tool_response.userModified); geex says "edited
#           by you" (ADR-0034). Left out otherwise, so the message is unchanged for the rest.
#
# geex relabels a change only when BOTH hashes match it (for a created file, the empty
# text's), so a wrong, late or duplicate message costs nothing: the change stays :external.
#
# Sends nothing for: a harness other than claude-code, a tool that isn't a writer
# (Write / Edit / NotebookEdit; MultiEdit if a version still has it), a writer that reports
# no prior text and didn't create the file, a NotebookEdit that reports an error, or a
# path that isn't absolute. Read and Grep are excluded on purpose: they carry paths too,
# and attesting them would credit an agent with someone else's write.
#
# FAIL-OPEN: always exits 0 with empty stdout (= Noop). It POSTs before exiting, so the
# message is in flight before the agent's next tool call. The POSTs run in parallel, each
# capped at 1s. Measured: ~3ms for a non-writer call, ~15ms for a small Edit, ~250ms for a
# 2.7MB file; a budgetMs of 1500 covers one hung geex plus that. Register it with failMode
# "open"; a bug here must cost an attribution, never a tool call.
#
# Where geex listens: each instance writes <dir>/<os_pid>.json (0600, in a 0700 dir):
#   {"v":1, "url":"http://127.0.0.1:<port>/attest", "token":"<hex>", "pid":<os_pid>}
# <dir> is $XDG_RUNTIME_DIR/geex, else <tmp>/geex-$USER. captAInHook strips a handler's
# environment to an allowlist, so register with passEnv ["XDG_RUNTIME_DIR"]; without it
# this falls back to /run/user/<uid>/geex. A file not owned by you, a url that isn't
# http://127.0.0.1:, or a pid that is gone is skipped. GEEX_ATTEST_DIR overrides <dir>
# (tests).
#
# THE SPOOL (ADR-0033 decision F): when no running geex took the attestation (none is running,
# or every one answered not_open or held: a geex holding the open file hasn't recorded the write
# yet, ADR-0034) and geex keeps a ledger for the file, the message is appended,
# with an `at` time, to that file's spool next to its ledger:
#   ${XDG_STATE_HOME:-$HOME/.local/state}/geex/ledger/<key>.spool.jsonl   (0600, last 256 lines)
# where <key> is the first 16 hex of the sha256 of the path, as geex names the ledger. Hashes and
# ids only, never content. When geex next opens the file and finds it changed, it credits the
# change only if spooled entries link its last known content to the disk exactly, all from one
# session; otherwise the change stays :external. XDG_STATE_HOME must match geex's; it isn't in
# captAInHook's default allowlist, so add it to passEnv if you set it.
#
# Needs jq (an envelope carries whole file contents with JSON escapes; only a JSON parser
# reads it faithfully), curl, and sha256sum or (macOS) shasum. Without them it sends
# nothing and says so on stderr (captAInHook's trail).

envelope=$(cat)
[ -n "$envelope" ] || exit 0

for tool in jq curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "geex-attest: $tool not found on PATH; nothing sent" >&2
    exit 0
  fi
done

# Stock macOS has shasum, not sha256sum. Both print "<hex>  -".
if command -v sha256sum >/dev/null 2>&1; then
  hash256() { sha256sum; }
elif command -v shasum >/dev/null 2>&1; then
  hash256() { shasum -a 256; }
else
  echo "geex-attest: neither sha256sum nor shasum on PATH; nothing sent" >&2
  exit 0
fi

# Line 1: the path. Line 2: "created" or "edited". Line 3: the message without its hashes.
# Nothing at all when this call isn't one to attest.
picked=$(printf '%s\n' "$envelope" | jq -r '
  .event as $e
  | $e.payload as $p
  | select($e.harness == "claude-code" and $e.type == "PostToolUse")
  | select($p.tool_name | IN("Write", "Edit", "MultiEdit", "NotebookEdit"))
  | (if ($p.tool_response | type) == "object" then $p.tool_response else {} end) as $r
  | select(($r.error // "") == "")
  | (if $p.tool_name == "NotebookEdit" then $p.tool_input.notebook_path
     else $p.tool_input.file_path end) as $path
  | (if $p.tool_name == "NotebookEdit" then $r.original_file else $r.originalFile end) as $orig
  | select(($path | type) == "string" and ($path | startswith("/"))
           and ($path | test("[\r\n]") | not))
  | (($orig == null) and $p.tool_name == "Write" and $r.type == "create") as $created
  | select(($orig | type) == "string" or $created)
  | select(($e.sessionId | type) == "string" and $e.sessionId != "")
  | ($path,
     (if $created then "created" else "edited" end),
     ({v: 1, path: $path, harness: $e.harness, session: $e.sessionId}
      + (if $created then {created: true} else {} end)
      + (if ($p.prompt_id | type) == "string" and $p.prompt_id != ""
         then {turn: $p.prompt_id} else {} end)
      + (if ($p.tool_use_id | type) == "string" and $p.tool_use_id != ""
         then {tool_use: $p.tool_use_id} else {} end)
      + (if $r.userModified == true then {user_modified: true} else {} end)
      | tojson))
' 2>/dev/null) || {
  echo "geex-attest: envelope did not parse; nothing sent" >&2
  exit 0
}
[ -n "$picked" ] || exit 0

{ IFS= read -r path; IFS= read -r kind; IFS= read -r draft; } <<EOF
$picked
EOF

after=$(hash256 <"$path" 2>/dev/null) || exit 0
after=${after%% *}

case $kind in
  created)
    msg=$(jq -cn --argjson d "$draft" --arg s "$after" '$d + {sha256: $s}') || exit 0
    ;;
  *)
    # The prior text, byte for byte as jq decodes it (-j: no trailing newline).
    before=$(printf '%s\n' "$envelope" | jq -j '
      .event.payload
      | if .tool_name == "NotebookEdit" then .tool_response.original_file
        else .tool_response.originalFile end
    ' | hash256)
    before=${before%% *}
    msg=$(jq -cn --argjson d "$draft" --arg b "$before" --arg s "$after" \
      '$d + {before: $b, sha256: $s}') || exit 0
    ;;
esac

# The token goes in on fd 3, never on curl's argv: ps shows argv to every local user. The
# answer's body lands in $3, so the caller can see whether any geex took the message.
post() {
  printf '%s' "$msg" | curl -sS -o "${3:-/dev/null}" -w '%{http_code}' --noproxy '*' \
    --connect-timeout 0.3 -m 1 -H 'Content-Type: application/json' -H @/dev/fd/3 \
    --data-binary @- "$1" 3<<EOF
Authorization: Bearer $2
EOF
}

send() {
  code=$(post "$1" "$2" "$3")
  [ "$code" = 200 ] || echo "geex-attest: $1 answered ${code:-nothing} for $path" >&2
}

# No geex took it: keep it for the next time geex opens this file, if geex keeps its history.
spool() {
  ledger=${XDG_STATE_HOME:-$HOME/.local/state}/geex/ledger
  key=$(printf '%s' "$path" | hash256)
  key=$(printf '%.16s' "$key")
  [ -f "$ledger/$key.jsonl" ] && [ -O "$ledger/$key.jsonl" ] || return 0
  file="$ledger/$key.spool.jsonl"
  line=$(printf '%s' "$msg" | jq -c '. + {at: (now | todate)}') || return 0
  (umask 077 && printf '%s\n' "$line" >>"$file") || return 0
  if [ "$(wc -l <"$file")" -gt 256 ]; then
    tail -n 256 "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  fi
}

if [ -n "${GEEX_ATTEST_DIR:-}" ]; then
  set -- "$GEEX_ATTEST_DIR"
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  set -- "$XDG_RUNTIME_DIR/geex" "${TMPDIR:-/tmp}/geex-${USER:-user}"
else
  set -- "/run/user/$(id -u)/geex" "${TMPDIR:-/tmp}/geex-${USER:-user}"
fi

answers=$(mktemp -d 2>/dev/null) || answers=""
n=0

for dir in "$@"; do
  [ -d "$dir" ] && [ -O "$dir" ] || continue
  for file in "$dir"/*.json; do
    [ -f "$file" ] && [ -O "$file" ] || continue
    info=$(jq -r 'select(.v == 1) | [.url, .token, .pid] | map(tostring) | join(" ")' \
      "$file" 2>/dev/null) || continue
    read -r url token pid <<EOF
$info
EOF
    case $url in http://127.0.0.1:*) ;; *) continue ;; esac
    case $token in '' | *[!0-9a-f]*) continue ;; esac
    case $pid in '' | *[!0-9]*) continue ;; esac
    # A crashed geex leaves its file behind; don't spend the timeout on it. Drop it too, as geex's
    # own start-up sweep would, so a pid the OS hands out again can't revive it: only a plain
    # file of ours (checked above; not a link) named by that pid.
    if ! kill -0 "$pid" 2>/dev/null; then
      [ ! -L "$file" ] && [ "${file##*/}" = "$pid.json" ] && rm -f "$file"
      continue
    fi

    # In parallel, so a hung instance costs at most one timeout however many are running.
    n=$((n + 1))
    send "$url" "$token" "${answers:+$answers/$n}" &
  done
done

wait

# A geex that recorded the write answers attested or ignored (pending: a geex from before
# ADR-0034). held (the open buffer hasn't taken the write in yet), not_open, or no geex at all
# leave it unrecorded, so it is spooled. Without a scratch dir there is no telling: don't spool.
if [ -n "$answers" ]; then
  taken=no
  for answer in "$answers"/*; do
    [ -f "$answer" ] || continue
    case $(jq -r '.status // empty' "$answer" 2>/dev/null) in
      attested | pending | ignored) taken=yes ;;
    esac
  done
  rm -rf "$answers"
  [ "$taken" = yes ] || spool
fi

exit 0
