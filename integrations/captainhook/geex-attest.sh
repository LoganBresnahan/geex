#!/bin/sh
# geex-attest — a ONESHOT captAInHook payload (geex ADR-0032, step d; its 2026-11-18 amendment).
#
# Registered on PostToolUse, and on PreToolUse for Bash. When an agent's tool changes a file,
# this tells every running geex which agent did it. geex has already shown the change (its file
# watcher records it as :external); if this message matches that change, geex relabels it with
# the agent's identity. It records; it never steers.
#
# The message (geex's Geex.Attest, v1), POSTed to each geex's loopback /attest:
#
#   {"v":1, "path", "before" | "created", "sha256", "harness", "session", "turn"?,
#    "tool_use"?, "user_modified"?, "during"?, "program"?}
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
#   during  "Bash" on a credit by time (below): the file changed WHILE the call ran. geex
#           shows it as "while", never as authorship.
#   program the name of the program the Bash command ran (sed, python3, prettier, git), never
#           the command line: a command can carry a token. Kept out of the spool.
#
# geex relabels a change only when BOTH hashes match it (for a created file, the empty
# text's), so a wrong, late or duplicate message costs nothing: the change stays :external.
#
# Writers: Write / Edit / NotebookEdit (MultiEdit if a version still has it), on PostToolUse.
# Sends nothing for a writer that reports no prior text and didn't create the file, a
# NotebookEdit that reports an error, or a path that isn't absolute. Read and Grep are excluded
# on purpose: they carry paths too, and attesting them would credit an agent with someone
# else's write.
#
# BASH, a credit by time (the 2026-11-18 amendment). A Bash response carries no file and no
# text from before, so the payload brackets the call:
#   PreToolUse   snapshots each git work tree the call may touch (the one holding the
#                envelope's cwd, and the ones holding each `cd DIR`, `git -C DIR` and absolute
#                path in the command): the sha256 of every file `git status` names there
#                ("absent" for a deleted one), into <dir>/bash/<tool_use_id>.snap.
#   PostToolUse  compares: for each path the snapshot or a new `git status` names, before is
#                the snapshot's hash or, for a file that was clean, git's index copy as a
#                checkout writes it (`git cat-file --filters`); after is the disk. Each changed
#                file is sent as above, with "during": "Bash" and "program".
# Reading the command only chooses WHERE to look; a credit still needs both hashes. Not
# credited (they stay :external): a background call (run_in_background), a call with no
# snapshot, a work tree past the cap or with too many changed files, a path git quotes,
# files outside a git work tree, ignored files, files inside an untracked directory git lists
# as one entry, a work tree that is $HOME. Snapshots older than an hour (a denied call) go.
#
# FAIL-OPEN: always exits 0 with empty stdout (= Noop). On PreToolUse that matters twice: an
# answer there could approve or deny the call (captAInHook ADR-0010: empty stdout is a Noop,
# first deny wins), and the step runs in the call's critical path, on EVERY tool call (a
# handler registers by event, not by tool), so anything but a claude-code Bash call exits at
# once. The snapshot is written whole or not at all, so captAInHook's budgetMs (failMode
# "open") cutting it short costs a credit, never a call. It POSTs before exiting, so the
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
# (tests). Bash snapshots live in <dir>/bash/ (0700), never as *.json in <dir> itself.
#
# THE SPOOL (ADR-0033 decision F): when no running geex took the attestation (none is running,
# or every one answered not_open or held: a geex holding the open file hasn't recorded the write
# yet, ADR-0034) and geex keeps a ledger for the file, the message is appended,
# with an `at` time, to that file's spool next to its ledger:
#   ${XDG_STATE_HOME:-$HOME/.local/state}/geex/ledger/<key>.spool.jsonl   (0600, last 256 lines)
# where <key> is the first 16 hex of the sha256 of the path, as geex names the ledger. Hashes and
# ids only, never content (so never "program"). When geex next opens the file and finds it
# changed, it credits the change only if spooled entries link its last known content to the disk
# exactly, all from one session; otherwise the change stays :external. XDG_STATE_HOME must match
# geex's; it isn't in captAInHook's default allowlist, so add it to passEnv if you set it.
#
# Needs jq (an envelope carries whole file contents with JSON escapes; only a JSON parser
# reads it faithfully), curl, and sha256sum or (macOS) shasum; git for Bash. Without them it
# sends nothing and says so on stderr (captAInHook's trail).

envelope=$(cat)
[ -n "$envelope" ] || exit 0

# A PreToolUse for anything but Bash leaves at once: this runs before every tool call.
case $envelope in
  *'"type":"PreToolUse"'*)
    case $envelope in *'"Bash"'*) ;; *) exit 0 ;; esac
    ;;
esac

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

# The sha256 of a file's bytes; nothing (and status 1) when it isn't a readable regular file.
hash_file() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  h=$(hash256 <"$1" 2>/dev/null) || return 1
  printf '%s' "${h%% *}"
}

if [ -n "${GEEX_ATTEST_DIR:-}" ]; then
  set -- "$GEEX_ATTEST_DIR"
elif [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  set -- "$XDG_RUNTIME_DIR/geex" "${TMPDIR:-/tmp}/geex-${USER:-user}"
else
  set -- "/run/user/$(id -u)/geex" "${TMPDIR:-/tmp}/geex-${USER:-user}"
fi
snaps="$1/bash"

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
# Hashes and ids only: "program" stays out.
spool() {
  ledger=${XDG_STATE_HOME:-$HOME/.local/state}/geex/ledger
  key=$(printf '%s' "$path" | hash256)
  key=$(printf '%.16s' "$key")
  [ -f "$ledger/$key.jsonl" ] && [ -O "$ledger/$key.jsonl" ] || return 0
  file="$ledger/$key.spool.jsonl"
  line=$(printf '%s' "$msg" | jq -c 'del(.program) + {at: (now | todate)}') || return 0
  (umask 077 && printf '%s\n' "$line" >>"$file") || return 0
  if [ "$(wc -l <"$file")" -gt 256 ]; then
    tail -n 256 "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  fi
}

# Send $msg (about $path) to every live geex, in parallel; spool it when none took it.
deliver() {
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
      # A crashed geex leaves its file behind; don't spend the timeout on it. Drop it too, as
      # geex's own start-up sweep would, so a pid the OS hands out again can't revive it: only a
      # plain file of ours (checked above; not a link) named by that pid.
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
  # ADR-0034). held (the open buffer hasn't taken the write in yet), not_open, or no geex at
  # all leave it unrecorded, so it is spooled. Without a scratch dir there is no telling:
  # don't spool.
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
}

# ---- Bash: a credit by time ----------------------------------------------------------------

# The most work trees one call snapshots, and the most changed files one work tree may list
# (past it, that tree is skipped: a miss, never a slow agent).
max_roots=4
max_entries=500

# Paths `git status` names in work tree $1, one per line, relative to it: modified, staged,
# untracked, deleted; a rename's new name. A path git quotes (a newline, a quote, a control
# byte) is left out. Status 1 when the tree lists more than $max_entries.
status_paths() {
  out=$(git -C "$1" -c core.quotepath=off status --porcelain=v1 --untracked-files=normal \
    2>/dev/null) || return 1
  [ "$(printf '%s\n' "$out" | grep -c .)" -le "$max_entries" ] || return 1
  printf '%s\n' "$out" | while IFS= read -r entry; do
    p=${entry#???}
    case $p in *' -> '*) p=${p##* -> } ;; esac
    case $p in '' | '"'* | */) continue ;; esac
    printf '%s\n' "$p"
  done
}

bash_pre() {
  command -v git >/dev/null 2>&1 || exit 0
  # The snapshot names the user's files: ours alone (0600 in a 0700 directory).
  umask 077
  # Line 1: the tool-use id. Then the directories to look in, one per line.
  picked=$(printf '%s\n' "$envelope" | jq -r '
    .event as $e | $e.payload as $p
    | select($e.harness == "claude-code" and $e.type == "PreToolUse" and $p.tool_name == "Bash")
    | select(($p.tool_input.run_in_background // false) != true)
    | select(($p.tool_use_id | type) == "string" and ($p.tool_use_id | test("^[A-Za-z0-9_-]{1,128}$")))
    | ($e.cwd // $p.cwd // "") as $cwd
    | ($p.tool_input.command // "") as $cmd
    | def unq: sub("^[\"\u0027]"; "") | sub("[\"\u0027]$"; "");
      def place: if startswith("/") or startswith("~") then . else ($cwd + "/" + .) end;
    $p.tool_use_id,
    ([$cwd]
     + [$cmd | scan("(?:^|[;&|(\\n])\\s*cd\\s+(\"[^\"]+\"|\u0027[^\u0027]+\u0027|[^\\s;&|)]+)") | .[0] | unq | place]
     + [$cmd | scan("\\bgit\\s+-C\\s+(\"[^\"]+\"|\u0027[^\u0027]+\u0027|[^\\s;&|)]+)") | .[0] | unq | place]
     + [$cmd | scan("(?<![\\w.$/~-])((?:~|/)[A-Za-z0-9._+@%,:=/-]*)") | .[0]]
     | map(select(. != "" and (test("[\\r\\n]") | not))) | unique | .[:24] | .[])
  ' 2>/dev/null) || exit 0
  [ -n "$picked" ] || exit 0

  id=$(printf '%s\n' "$picked" | head -n 1)
  roots=""
  count=0
  printf '%s\n' "$picked" | tail -n +2 >"${TMPDIR:-/tmp}/geex-attest-dirs.$$" || exit 0
  while IFS= read -r d; do
    case $d in '~') d=$HOME ;; '~/'*) d="$HOME/${d#\~/}" ;; esac
    # A path to a file, or one not made yet: look from the nearest directory that exists.
    while [ -n "$d" ] && [ ! -d "$d" ]; do d=${d%/*}; done
    [ -n "$d" ] || continue
    root=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || continue
    [ "$root" != "$HOME" ] || continue
    case "
$roots
" in *"
$root
"*) continue ;; esac
    roots="$roots
$root"
    count=$((count + 1))
    [ "$count" -lt "$max_roots" ] || break
  done <"${TMPDIR:-/tmp}/geex-attest-dirs.$$"
  rm -f "${TMPDIR:-/tmp}/geex-attest-dirs.$$"
  [ -n "$roots" ] || exit 0

  mkdir -p "$snaps" 2>/dev/null || exit 0
  [ -O "$snaps" ] || exit 0
  # Denied calls never reach PostToolUse: their snapshots go after an hour.
  find "$snaps" -name '*.snap' -type f -mmin +60 -exec rm -f {} + 2>/dev/null

  tmp="$snaps/$id.snap.tmp.$$"
  (
    printf '%s\n' "$roots" | while IFS= read -r root; do
      [ -n "$root" ] || continue
      paths=$(status_paths "$root") || continue
      printf 'root\t%s\n' "$root"
      printf '%s\n' "$paths" | while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case $rel in *'	'*) continue ;; esac
        h=$(hash_file "$root/$rel") || h=absent
        [ -d "$root/$rel" ] && continue
        printf 'f\t%s\t%s\n' "$h" "$rel"
      done
    done
  ) >"$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
  # Whole or not at all: a cut-short run leaves only its .tmp, which the sweep removes.
  mv -f "$tmp" "$snaps/$id.snap" 2>/dev/null || rm -f "$tmp"
  exit 0
}

bash_post() {
  command -v git >/dev/null 2>&1 || exit 0
  # Line 1: the tool-use id. Line 2: "background" or "foreground". Line 3: the message draft.
  picked=$(printf '%s\n' "$envelope" | jq -r '
    .event as $e | $e.payload as $p
    | select($e.harness == "claude-code" and $e.type == "PostToolUse" and $p.tool_name == "Bash")
    | select(($p.tool_use_id | type) == "string" and ($p.tool_use_id | test("^[A-Za-z0-9_-]{1,128}$")))
    | select(($e.sessionId | type) == "string" and $e.sessionId != "")
    | ($p.tool_input.command // "") as $cmd
    # The program: the first word of the first part of the command that does more than move
    # about or set the scene, past assignments and wrappers, as a basename.
    | ([$cmd | split("\n")[0] | splits("[;&|]+")
        | gsub("^[\\s(]+"; "")
        | select(. != "" and (test("^(cd|pushd|popd|export|set|unset|source|umask|true|\\.)(\\s|$)") | not))]
       | first // "") as $part
    | ([$part | splits("\\s+") | select(. != "")]
       | map(select(test("^[A-Za-z_][A-Za-z0-9_]*=") | not))
       | map(select(IN("env", "sudo", "command", "exec", "time", "nohup", "nice") | not))
       | first // "") as $word
    | ($word | sub("^[\"\u0027]+"; "") | sub("[\"\u0027]+$"; "") | split("/") | last) as $prog
    | $p.tool_use_id,
      (if ($p.tool_input.run_in_background // false) == true then "background" else "foreground" end),
      ({v: 1, harness: $e.harness, session: $e.sessionId, during: "Bash"}
       + (if ($p.prompt_id | type) == "string" and $p.prompt_id != ""
          then {turn: $p.prompt_id} else {} end)
       + {tool_use: $p.tool_use_id}
       + (if ($prog | test("^[A-Za-z0-9._+-]{1,64}$")) then {program: $prog} else {} end)
       | tojson)
  ' 2>/dev/null) || exit 0
  [ -n "$picked" ] || exit 0

  { IFS= read -r id; IFS= read -r mode; IFS= read -r draft; } <<EOF
$picked
EOF
  snap="$snaps/$id.snap"
  [ -f "$snap" ] && [ -O "$snap" ] || exit 0
  if [ "$mode" = background ]; then
    rm -f "$snap"
    exit 0
  fi

  work="${TMPDIR:-/tmp}/geex-attest-post.$$"
  # One line per path to check: <root> TAB <before: hash | absent | -> TAB <relative path>.
  root=""
  while IFS= read -r line; do
    case $line in
      root'	'*)
        root=${line#root	}
        status_paths "$root" | while IFS= read -r rel; do
          [ -n "$rel" ] && printf '%s\t-\t%s\n' "$root" "$rel"
        done
        ;;
      f'	'*)
        rest=${line#f	}
        printf '%s\t%s\t%s\n' "$root" "${rest%%	*}" "${rest#*	}"
        ;;
    esac
  done <"$snap" >"$work" 2>/dev/null
  rm -f "$snap"

  # A path the snapshot names wins over the same path found only now ("-").
  sort -t '	' -k1,1 -k3,3 -k2,2r "$work" 2>/dev/null | awk -F '\t' '
    { key = $1 "\t" $3; if (!(key in seen)) { seen[key] = 1; print } }
  ' >"$work.u" 2>/dev/null
  rm -f "$work"

  while IFS='	' read -r root before rel; do
    [ -n "$rel" ] || continue
    path="$root/$rel"
    after=$(hash_file "$path") || continue
    created=no
    case $before in
      absent) created=yes ;;
      -)
        # Clean before the call: git's index copy, as a checkout would write it. Not in the
        # index and not named before: it didn't exist (an untracked file is always named).
        if b=$(git -C "$root" cat-file --filters ":$rel" 2>/dev/null | hash256) &&
          git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
          before=${b%% *}
        else
          created=yes
        fi
        ;;
    esac
    if [ "$created" = yes ]; then
      msg=$(jq -cn --argjson d "$draft" --arg p "$path" --arg s "$after" \
        '$d + {path: $p, created: true, sha256: $s}') || continue
    else
      [ "$before" != "$after" ] || continue
      msg=$(jq -cn --argjson d "$draft" --arg p "$path" --arg b "$before" --arg s "$after" \
        '$d + {path: $p, before: $b, sha256: $s}') || continue
    fi
    deliver "$@"
  done <"$work.u"
  rm -f "$work.u"
  exit 0
}

# ---- which call is this ----------------------------------------------------------------------

which=$(printf '%s\n' "$envelope" | jq -r '
  .event | select(.harness == "claude-code") | "\(.type) \(.payload.tool_name // "")"
' 2>/dev/null) || {
  echo "geex-attest: envelope did not parse; nothing sent" >&2
  exit 0
}

case $which in
  "PreToolUse Bash") bash_pre "$@" ;;
  "PostToolUse Bash") bash_post "$@" ;;
  "PostToolUse "*) ;;
  *) exit 0 ;;
esac

# ---- a writer: Write / Edit / NotebookEdit ---------------------------------------------------

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

deliver "$@"
exit 0
