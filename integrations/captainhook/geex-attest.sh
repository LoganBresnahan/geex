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
#                It also records each tree's starting commit, and "absent" for each path the
#                command names that doesn't exist yet: the only files it may later call new.
#   PostToolUse  compares: for each path the snapshot or a new `git status` names, before is
#                the snapshot's hash or, for a file that was clean, the starting commit's copy
#                as a checkout writes it (`git cat-file --filters`); after is the disk. Each
#                changed file is sent as above, with "during": "Bash" and "program".
# Reading the command only chooses WHERE to look; a credit still needs both hashes. Not
# credited (they stay :external): a background call (run_in_background), a call with no
# snapshot or another session's or an hour-old one, a work tree past the cap or with more than
# 500 changed files, a call changing more than 150, a path holding a newline or a tab, a
# symlink, files outside a git work tree, a new file the command doesn't name (it can't be
# proved new: an ignored file, one inside an untracked directory git lists as one entry, a
# generated one), a file a commit in the call took back to clean, a work tree that is $HOME.
# Snapshots older than an hour (a denied call) go.
#
# FAIL-OPEN: always exits 0 with empty stdout (= Noop). On PreToolUse that matters twice: an
# answer there could approve or deny the call (captAInHook ADR-0010: empty stdout is a Noop,
# first deny wins), and the step runs in the call's critical path, on EVERY tool call (a
# handler registers by event, not by tool), so anything but a claude-code Bash call exits at
# once. The snapshot is written whole or not at all, so captAInHook's budgetMs (failMode
# "open") cutting it short costs a credit, never a call. It POSTs before exiting, so the
# message is in flight before the agent's next tool call. The POSTs run in parallel, each
# capped at 1s; a Bash call's messages go eight at a time, and a geex that gives no answer is
# skipped for the rest of that call (one timeout, not one per batch). Measured: ~3ms for a
# non-writer call, ~15ms for a small Edit, ~250ms for a 2.7MB file; a budgetMs of 1500 covers one
# hung geex plus that. Register it with failMode
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
  hash_files() { xargs -0 sha256sum --; }
elif command -v shasum >/dev/null 2>&1; then
  hash256() { shasum -a 256; }
  hash_files() { xargs -0 shasum -a 256 --; }
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

# The token goes in on fd 3, never on curl's argv: ps shows argv to every local user. The
# answer's body lands in $3, so the caller can see whether any geex took the message.
post() {
  printf '%s' "$msg" | curl -sS -o "${3:-/dev/null}" -w '%{http_code}' --noproxy '*' \
    --connect-timeout 0.3 -m 1 -H 'Content-Type: application/json' -H @/dev/fd/3 \
    --data-binary @- "$1" 3<<EOF
Authorization: Bearer $2
EOF
}

# A geex that gave no answer at all is written to $slow (a Bash call's many messages): the rest
# of the call skips it, so one hung geex costs one timeout, not one per batch.
slow=""
send() {
  code=$(post "$1" "$2" "$3")
  [ "$code" = 200 ] || echo "geex-attest: $1 answered ${code:-nothing} for $path" >&2
  case $code in '' | 000) [ -z "$slow" ] || printf '%s\n' "$1" >>"$slow" ;; esac
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

# The live geex instances, "url token" per line, found once per run: a file not ours, a url
# that isn't loopback, a bad token or a dead pid is skipped.
live=""
live_found=no
find_live() {
  [ "$live_found" = no ] || return 0
  live_found=yes
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
      live="$live$url $token
"
    done
  done
}

# Send $msg (about $path) to every live geex, in parallel; spool it when none took it.
deliver() {
  find_live "$@"
  answers=$(mktemp -d 2>/dev/null) || answers=""
  # Cut short (captAInHook's budget), the answers' directory goes too, in a subshell as well.
  trap 'rm -rf "$answers"; exit 0' INT TERM
  n=0

  # In parallel, so a hung instance costs at most one timeout however many are running.
  while read -r url token; do
    [ -n "$url" ] || continue
    if [ -n "$slow" ] && grep -qxF "$url" "$slow" 2>/dev/null; then continue; fi
    n=$((n + 1))
    send "$url" "$token" "${answers:+$answers/$n}" &
  done <<EOF
$live
EOF

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

# The most work trees one call snapshots, the most changed files one work tree may list (past
# it, that tree is skipped), and the most changed files one PostToolUse sends (past it, none):
# a miss, never a slow agent.
max_roots=4
max_entries=500
max_post=150

# The home directory, resolved, so its tree is never snapshotted however HOME is spelled.
home_real=""
if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
  home_real=$(cd "$HOME" 2>/dev/null && pwd -P) || home_real=""
fi

# git without running anything a repository configures (ADR-0032's amendment, as built: the
# maintainer's word, 2026-11-19). This runs before the permission prompt, in trees a command
# merely names, so: no fsmonitor; no lazy fetch (a partial clone fetching a missing object runs
# its remote's program: GIT_NO_LAZY_FETCH, and a partial clone is refused outright, for gits
# older than that variable); every filter driver the tree's config names (repository, global or
# system) emptied, so neither `status` nor `cat-file --filters` runs one; no optional index
# writes. Set through git's GIT_CONFIG_* variables (git 2.31 or newer, checked first), so a
# driver's name is never quoted into a command line, and any git it starts gets them too.

# git 2.31 or newer: older gits ignore GIT_CONFIG_COUNT, and would run all of the above.
git_new_enough() {
  v=$(git version 2>/dev/null) || return 1
  v=${v#git version }
  major=${v%%.*}
  rest=${v#*.}
  minor=${rest%%[!0-9]*}
  case $major in '' | *[!0-9]*) return 1 ;; esac
  case $minor in '' | *[!0-9]*) return 1 ;; esac
  [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 31 ]; }
}

# Before any git call: fsmonitor off, no lazy fetch, everywhere.
git_quiet() {
  GIT_NO_LAZY_FETCH=1
  GIT_CONFIG_COUNT=1
  GIT_CONFIG_KEY_0=core.fsmonitor
  GIT_CONFIG_VALUE_0=false
  export GIT_NO_LAZY_FETCH GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
}

# Ready the environment for work tree $1, in this shell: its filter drivers emptied. Status 1,
# and nothing to run there, for a partial clone. `git config` only reads.
gs_root=""
gs_enter() {
  gs_root=""
  [ -z "$(git -C "$1" config --get extensions.partialclone 2>/dev/null)" ] || return 1
  if git -C "$1" config --type=bool --get-regexp '^remote\..*\.promisor$' 2>/dev/null |
    grep -q ' true$'; then
    return 1
  fi
  names=$(git -C "$1" config --name-only --get-regexp '^filter\.' 2>/dev/null |
    sed -n 's/^filter\.\(.*\)\.[^.]*$/\1/p' | sort -u)
  i=1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    for key in clean smudge process; do
      eval "GIT_CONFIG_KEY_$i=\"filter.\$name.\$key\" GIT_CONFIG_VALUE_$i=; export GIT_CONFIG_KEY_$i GIT_CONFIG_VALUE_$i"
      i=$((i + 1))
    done
    eval "GIT_CONFIG_KEY_$i=\"filter.\$name.required\" GIT_CONFIG_VALUE_$i=false; export GIT_CONFIG_KEY_$i GIT_CONFIG_VALUE_$i"
    i=$((i + 1))
  done <<EOF
$names
EOF
  GIT_CONFIG_COUNT=$i
  export GIT_CONFIG_COUNT
  gs_root=$1
}

# git in work tree $1, readied once (a different tree, or a subshell, readies it again).
gs() {
  r=$1
  shift
  [ "$r" = "$gs_root" ] || gs_enter "$r" || return 1
  git -C "$r" --no-optional-locks "$@"
}

# Paths `git status` names in work tree $1, one per line, relative to it: modified, staged,
# untracked, deleted; a rename's new name. -z, so a path with a space is named as it is; a path
# holding a newline or a tab is left out. Status 1 when the tree lists more than $max_entries.
# An untracked directory git names as one entry (`dir/`) is printed with its slash, so the
# caller knows a file inside it can't be proved new.
status_paths() {
  out=$(gs "$1" status --porcelain=v1 -z --untracked-files=normal --ignore-submodules=all 2>/dev/null |
    tr '\000' '\n') || return 1
  [ "$(printf '%s\n' "$out" | grep -c .)" -le "$((max_entries * 2))" ] || return 1
  printf '%s\n' "$out" | awk -v max="$max_entries" '
    skip { skip = 0; next }
    /^[ MADRCUT?!][ MADRCUT?!] / {
      xy = substr($0, 1, 2); p = substr($0, 4)
      if (xy ~ /[RC]/) skip = 1
      if (p == "" || p ~ /\t/) next
      if (++n > max) { exit 1 }
      print p
    }
  '
}

# A path is in tree $1 (absolute) when it starts with "$1/": its relative path, else nothing.
in_root() {
  case $2 in "$1"/*) printf '%s' "${2#"$1"/}" ;; *) return 1 ;; esac
}

bash_pre() {
  command -v git >/dev/null 2>&1 || exit 0
  if ! git_new_enough; then
    echo "geex-attest: $(git version 2>/dev/null) is older than 2.31; Bash changes aren't credited" >&2
    exit 0
  fi
  git_quiet
  # The snapshot names the user's files: ours alone (0600 in a 0700 directory).
  umask 077
  # Line 1: the tool-use id. Then "D<TAB>dir" for each directory to look in (the cwd first),
  # and "N<TAB>path" for each path the command names, to prove absent ones new.
  picked=$(printf '%s\n' "$envelope" | jq -r '
    .event as $e | $e.payload as $p
    | select($e.harness == "claude-code" and $e.type == "PreToolUse" and $p.tool_name == "Bash")
    | select(($p.tool_input.run_in_background // false) != true)
    | select(($p.tool_use_id | type) == "string" and ($p.tool_use_id | test("^[A-Za-z0-9_-]{1,128}$")))
    | ($e.cwd // $p.cwd // "") as $cwd
    | ($p.tool_input.command // "") as $cmd
    | def unq: sub("^[\"\u0027]"; "") | sub("[\"\u0027]$"; "");
      def place: if startswith("/") or startswith("~") then . else ($cwd + "/" + .) end;
      def clean: select(. != "" and (test("[\\t\\r\\n]") | not));
    ([$cmd | scan("(?:^|[;&|(\\n])\\s*cd\\s+(\"[^\"]+\"|\u0027[^\u0027]+\u0027|[^\\s;&|)]+)") | .[0] | unq | place]
     + [$cmd | scan("\\bgit\\s+-C\\s+(\"[^\"]+\"|\u0027[^\u0027]+\u0027|[^\\s;&|)]+)") | .[0] | unq | place]
     | map(clean)) as $bases
    | $p.tool_use_id,
      ("D\t" + ([$cwd | clean]
        + ([$bases[], ($cmd | scan("(?<![\\w.$/~-])((?:~|/)[A-Za-z0-9._+@%,:=/-]*)") | .[0])]
           | map(clean) | unique | .[:23])
        | .[])),
      ([$cmd | scan("[A-Za-z0-9._@%+=,:~/-]+") | select(test("[./]") and (startswith("-") | not)
         and (test("://") | not) and . != "." and . != ".." and (test("(^|/)\\.\\.(/|$)") | not))
        | sub("^\\./"; "") | gsub("/\\./"; "/")
        | if startswith("/") or startswith("~") then . else (. as $t | ([$cwd] + $bases)[] + "/" + $t) end]
       | map(clean) | unique | .[:64] | .[] | "N\t" + .)
  ' 2>/dev/null) || exit 0
  [ -n "$picked" ] || exit 0

  work=$(mktemp -d 2>/dev/null) || exit 0
  trap 'rm -rf "$work"' EXIT
  trap 'rm -rf "$work"; exit 0' INT TERM
  id=$(printf '%s\n' "$picked" | head -n 1)
  printf '%s\n' "$picked" | tail -n +2 >"$work/picked"

  roots=""
  count=0
  while IFS='	' read -r kind d; do
    [ "$kind" = D ] || continue
    # Only `~` and `~/…` name a home; any other `~…` is no directory of ours.
    case $d in
      '~') d=$HOME ;;
      '~/'*) d="$HOME/${d#\~/}" ;;
      '~'*) continue ;;
    esac
    # A path to a file, or one not made yet: look from the nearest directory that exists.
    while [ -n "$d" ] && [ ! -d "$d" ]; do
      case $d in */*) d=${d%/*} ;; *) d="" ;; esac
    done
    [ -n "$d" ] || continue
    root=$(git -C "$d" --no-optional-locks rev-parse --show-toplevel 2>/dev/null) || continue
    gs_enter "$root" || continue
    root_real=$(cd "$root" 2>/dev/null && pwd -P) || continue
    [ -z "$home_real" ] || [ "$root_real" != "$home_real" ] || continue
    case "
$roots
" in *"
$root
"*) continue ;; esac
    roots="$roots
$root"
    count=$((count + 1))
    [ "$count" -lt "$max_roots" ] || break
  done <"$work/picked"
  [ -n "$roots" ] || exit 0

  for snaps in "$@"; do
    [ -d "${snaps%/*}" ] && break
  done
  snaps="$snaps/bash"
  mkdir -p "$snaps" 2>/dev/null || exit 0
  [ -O "$snaps" ] || exit 0
  # Denied calls never reach PostToolUse, and a cut-short run leaves its .tmp: an hour, then gone.
  find "$snaps" -type f \( -name '*.snap' -o -name '*.snap.tmp.*' \) -mmin +60 \
    -exec rm -f {} + 2>/dev/null

  session=$(printf '%s\n' "$envelope" | jq -r '.event.sessionId // ""' 2>/dev/null)
  tmp="$snaps/$id.snap.tmp.$$"
  {
    printf 'session\t%s\n' "$session"
    printf 'at\t%s\n' "$(date +%s)"
    printf '%s\n' "$roots" | while IFS= read -r root; do
      [ -n "$root" ] || continue
      paths=$(status_paths "$root") || continue
      printf 'root\t%s\n' "$root"
      # The commit the call starts from: a file clean now is that commit's (a reset or a commit
      # in the call moves HEAD, so HEAD read afterwards would be the wrong before).
      printf 'head\t%s\n' "$(gs "$root" rev-parse --verify -q HEAD 2>/dev/null)"
      printf '%s\n' "$paths" | while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case $rel in
          */) printf 'u\t%s\n' "$rel" ;;
          *)
            if [ -L "$root/$rel" ] || [ -d "$root/$rel" ]; then
              continue
            elif h=$(hash_file "$root/$rel"); then
              printf 'f\t%s\t%s\n' "$h" "$rel"
            elif [ ! -e "$root/$rel" ]; then
              printf 'f\tabsent\t%s\n' "$rel"
            fi
            ;;
        esac
      done
      # Paths the command names that don't exist yet: proved absent, so new if they appear.
      while IFS='	' read -r kind p; do
        [ "$kind" = N ] || continue
        case $p in '~/'*) p="$HOME/${p#\~/}" ;; '~'*) continue ;; esac
        [ -e "$p" ] || [ -L "$p" ] && continue
        # Resolve the part that exists, so a symlinked directory names the file where it lands.
        d=${p%/*} tail=${p##*/}
        while [ -n "$d" ] && [ ! -d "$d" ]; do
          tail="${d##*/}/$tail"
          case $d in */*) d=${d%/*} ;; *) d="" ;; esac
        done
        [ -n "$d" ] || continue
        d=$(cd "$d" 2>/dev/null && pwd -P) || continue
        rel=$(in_root "$root" "$d/$tail") || continue
        [ -e "$root/$rel" ] || [ -L "$root/$rel" ] || printf 'f\tabsent\t%s\n' "$rel"
      done <"$work/picked"
    done
  } >"$tmp" 2>/dev/null || { rm -f "$tmp"; exit 0; }
  # Whole or not at all: a cut-short run leaves only its .tmp, which the sweep removes.
  mv -f "$tmp" "$snaps/$id.snap" 2>/dev/null || rm -f "$tmp"
  exit 0
}

bash_post() {
  command -v git >/dev/null 2>&1 || exit 0
  git_new_enough || exit 0
  git_quiet
  # Line 1: the tool-use id. Line 2: the session. Line 3: "background" or "foreground".
  # Line 4: the message draft.
  picked=$(printf '%s\n' "$envelope" | jq -r '
    .event as $e | $e.payload as $p
    | select($e.harness == "claude-code" and $e.type == "PostToolUse" and $p.tool_name == "Bash")
    | select(($p.tool_use_id | type) == "string" and ($p.tool_use_id | test("^[A-Za-z0-9_-]{1,128}$")))
    | select(($e.sessionId | type) == "string" and $e.sessionId != "" and ($e.sessionId | test("[\\t\\n]") | not))
    | ($p.tool_input.command // "") as $cmd
    # The program: the first word of the first part of the command that does more than move
    # about or set the scene, past assignments and wrappers (and their options), unquoted, as a
    # basename.
    | def unq: (if test("^\".*\"$") or test("^\u0027.*\u0027$") then .[1:-1] else . end) | sub("\\)+$"; "");
      # The options of each wrapper that take a value.
      def takes: {"sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"], "doas": ["-u", "-C"],
                  "env": ["-u", "-S", "-C"], "nice": ["-n"], "time": ["-f", "-o"]};
      def prog(ws):
        def opts(w; ws):
          if (ws | length) == 0 then ""
          elif (ws[0] | startswith("-")) then
            (if (ws[0] | IN((takes[w] // [])[])) then opts(w; ws[2:]) else opts(w; ws[1:]) end)
          else prog(ws) end;
        if (ws | length) == 0 then ""
        elif (ws[0] | test("^[A-Za-z_][A-Za-z0-9_]*=")) then prog(ws[1:])
        elif (ws[0] | IN("env", "sudo", "doas", "command", "exec", "time", "nohup", "nice")) then opts(ws[0]; ws[1:])
        else ws[0] end;
    ([$cmd | gsub("\\\\\\n"; " ") | splits("[;&|\\n]+")
      | gsub("^[\\s(]+"; "")
      | select(. != "" and (startswith("#") | not)
               and (test("^(cd|pushd|popd|export|set|unset|source|umask|true|\\.)(\\s|$)") | not))]
     | first // "") as $part
    | (prog([$part | scan("\"[^\"]*\"|\u0027[^\u0027]*\u0027|\\S+") | unq])
       | split("/") | last // "") as $prog
    | $p.tool_use_id,
      $e.sessionId,
      (if ($p.tool_input.run_in_background // false) == true then "background" else "foreground" end),
      ({v: 1, harness: $e.harness, session: $e.sessionId, during: "Bash"}
       + (if ($p.prompt_id | type) == "string" and $p.prompt_id != ""
          then {turn: $p.prompt_id} else {} end)
       + {tool_use: $p.tool_use_id}
       + (if ($prog | test("^[A-Za-z0-9._+-]{1,64}$")) then {program: $prog} else {} end)
       | tojson)
  ' 2>/dev/null) || exit 0
  [ -n "$picked" ] || exit 0

  { IFS= read -r id; IFS= read -r session; IFS= read -r mode; IFS= read -r draft; } <<EOF
$picked
EOF
  for snaps in "$@"; do
    [ -d "${snaps%/*}" ] && break
  done
  snap="$snaps/bash/$id.snap"
  [ -f "$snap" ] && [ -O "$snap" ] || exit 0

  work=$(mktemp -d 2>/dev/null) || { rm -f "$snap"; exit 0; }
  trap 'rm -rf "$work"' EXIT
  trap 'rm -rf "$work"; exit 0' INT TERM
  mv -f "$snap" "$work/snap" 2>/dev/null || exit 0
  [ "$mode" = background ] && exit 0

  # The snapshot must be this session's, and under an hour old.
  snap_session=$(sed -n 's/^session	//p' "$work/snap" | head -n 1)
  snap_at=$(sed -n 's/^at	//p' "$work/snap" | head -n 1)
  [ -n "$snap_session" ] && [ "$snap_session" = "$session" ] || exit 0
  case $snap_at in '' | *[!0-9]*) exit 0 ;; esac
  [ $(($(date +%s) - snap_at)) -le 3600 ] || exit 0

  # One line per path to check: <root> TAB <before: hash | absent | - | unknown> TAB <path>;
  # and each tree's starting commit in heads.
  : >"$work/heads"
  root=""
  while IFS= read -r line; do
    case $line in
      root'	'*)
        root=${line#root	}
        status_paths "$root" | while IFS= read -r rel; do
          case $rel in '' | */) ;; *) printf '%s\t-\t%s\n' "$root" "$rel" ;; esac
        done
        ;;
      head'	'*)
        printf '%s\t%s\n' "$root" "${line#head	}" >>"$work/heads"
        ;;
      u'	'*)
        # An untracked directory at the snapshot: what's inside it can't be proved new or old.
        printf '%s\tdir\t%s\n' "$root" "${line#u	}"
        ;;
      f'	'*)
        rest=${line#f	}
        printf '%s\t%s\t%s\n' "$root" "${rest%%	*}" "${rest#*	}"
        ;;
    esac
  done <"$work/snap" >"$work/all" 2>/dev/null

  # A path the snapshot names wins over the same path found only now ("-"); a path inside an
  # untracked directory the snapshot named is unknown.
  awk -F '\t' '
    $2 == "dir" { dirs[$1 "\t" $3] = 1; next }
    { key = $1 "\t" $3; if ($2 != "-" || !(key in v)) v[key] = $2; order[key] = 1 }
    END {
      for (k in order) {
        split(k, a, "\t"); before = v[k]
        if (before == "-") for (d in dirs) {
          split(d, b, "\t")
          if (b[1] == a[1] && index(a[2], b[2]) == 1) { before = "unknown"; break }
        }
        print a[1] "\t" before "\t" a[2]
      }
    }
  ' "$work/all" >"$work/paths" 2>/dev/null

  # The after hashes, one sha256 run per tree: the changed regular files, never a link.
  : >"$work/changed"
  cut -f 1 "$work/paths" | sort -u | while IFS= read -r root; do
    [ -n "$root" ] || continue
    awk -F '\t' -v r="$root" '$1 == r && $2 != "unknown" { print $3 }' "$work/paths" |
      while IFS= read -r rel; do
        case $rel in *\\*) continue ;; esac
        [ -f "$root/$rel" ] && [ ! -L "$root/$rel" ] && printf '%s\n' "$rel"
      done >"$work/rels"
    [ -s "$work/rels" ] || continue
    # One hasher, whatever it says about a file it can't read: never a second pass.
    (cd "$root" && tr '\n' '\000' <"$work/rels" | hash_files 2>/dev/null) |
      awk -v r="$root" '{ h = $1; sub(/^[0-9a-f]+  /, ""); print r "\t" h "\t" $0 }' >>"$work/changed"
  done

  # The messages: before from the snapshot, from HEAD for a file clean then (as a checkout
  # writes it), or new only when the snapshot proved it absent. Unchanged: nothing. One pass
  # joins each changed file to its before.
  awk -F '\t' '
    FILENAME == ARGV[1] { h[$1] = $2; next }
    FILENAME == ARGV[2] { b[$1 "\t" $3] = $2; next }
    { print $1 "\t" $3 "\t" b[$1 "\t" $3] "\t" $2 "\t" h[$1] }
  ' "$work/heads" "$work/paths" "$work/changed" >"$work/joined" 2>/dev/null
  # A file a filter driver handles is never credited: its filter isn't run, so its real
  # content can't be read (`check-attr` only reads the attributes).
  : >"$work/filtered"
  cut -f 1 "$work/joined" | sort -u | while IFS= read -r root; do
    [ -n "$root" ] || continue
    awk -F '\t' -v r="$root" '$1 == r { print $2 }' "$work/joined" | tr '\n' '\000' |
      gs "$root" check-attr -z --stdin filter 2>/dev/null | tr '\000' '\n' |
      awk -v r="$root" 'NR % 3 == 1 { p = $0 } NR % 3 == 0 && $0 != "unspecified" && $0 != "unset" { print r "\t" p }'
  done >>"$work/filtered"
  awk -F '\t' 'FILENAME == ARGV[1] { f[$0] = 1; next } !(($1 "\t" $2) in f)' \
    "$work/filtered" "$work/joined" >"$work/joined.k" && mv -f "$work/joined.k" "$work/joined"
  # The cap counts real changes only: a hash that moved, a file proved absent that now exists,
  # a file listed now that wasn't then. A file dirty before and untouched is no change.
  n_changed=$(awk -F '\t' '$3 == "absent" || $3 == "-" || ($3 ~ /^[0-9a-f]+$/ && $3 != $4) { n++ }
    END { print n + 0 }' "$work/joined")
  if [ "$n_changed" -gt "$max_post" ]; then
    # Files that may have changed (one listed only now may be a reset, not an edit): to compare.
    echo "geex-attest: $n_changed files to compare after the Bash call (over $max_post); nothing sent" >&2
    exit 0
  fi
  : >"$work/msgs"
  while IFS='	' read -r root rel before after head; do
    case $before in
      absent)
        # Where it landed, resolved again now: a link the call made can't credit a file outside
        # the tree.
        case $rel in */*) dir="$root/${rel%/*}" ;; *) dir=$root ;; esac
        d=$(cd "$dir" 2>/dev/null && pwd -P) || continue
        in_root "$root" "$d/${rel##*/}" >/dev/null || continue
        created=yes
        ;;
      -)
        [ -n "$head" ] || continue
        gs "$root" cat-file --filters "$head:$rel" >"$work/blob" 2>/dev/null || continue
        before=$(hash_file "$work/blob") || continue
        created=no
        ;;
      '' | unknown) continue ;;
      *) created=no ;;
    esac
    [ "$created" = yes ] || [ "$before" != "$after" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$root/$rel" "$before" "$after" "$created" >>"$work/msgs"
  done <"$work/joined"

  [ -s "$work/msgs" ] || exit 0
  # One message per file, however many trees named it (a nested repository).
  sort -t '	' -u -k1,1 "$work/msgs" >"$work/msgs.u" && mv -f "$work/msgs.u" "$work/msgs"

  # Sent eight at a time, each to every live geex: one hung geex costs its timeout per batch.
  jq -r -R --argjson d "$draft" '
    split("\t") as [$path, $before, $after, $created]
    | $path + "\t" + ($d + {path: $path, sha256: $after}
      + (if $created == "yes" then {created: true} else {before: $before} end) | tojson)
  ' <"$work/msgs" >"$work/json" 2>/dev/null || exit 0
  find_live "$@"
  slow="$work/slow"
  : >"$slow"
  i=0
  while IFS='	' read -r path msg; do
    [ -n "$msg" ] || continue
    (deliver "$@") &
    i=$((i + 1))
    [ $((i % 8)) -ne 0 ] || wait
  done <"$work/json"
  wait
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
