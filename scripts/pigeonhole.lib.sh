#!/bin/bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared helpers for the documents pipeline.
# Sourced by documents.{triage,apply}.sh — not executable on its own.
#
# Scope is ROOT FILES ONLY. The numbered folders are the filed corpus and are only
# ever hashed for duplicate detection, never read, renamed or moved — so a nightly
# re-audit can never churn a decision you made by hand.

set -uo pipefail

# Everything that talks to api.anthropic.com lives in ai.lib.sh, shared with the
# capture pipeline: transport + retry (api_post/api_class), request construction
# (ai_build_request) and the response gate (ai_extract). Sourced FIRST, before the
# log()/die() below, so this file's identical definitions stay authoritative.
# shellcheck source=/zpool/catallenya/ai/scripts/ai.lib.sh
source "/zpool/catallenya/ai/scripts/ai.lib.sh"

# Overridable ONLY so the pipeline can be exercised against a scratch tree without
# touching the real corpus — same seam as API_URL in ai.lib.sh. Never set in
# production; the defaults are the only values systemd ever runs with.
# The corpus stays in Syncthing's synced folder — the move to pigeonhole/ was code
# only, so no device re-pairing and no restic change (the corpus rides in
# syncthing/data, which restic already takes).
DOCS="${DOCS:-/zpool/catallenya/syncthing/data/master/documents}"
STATE_DIR="${STATE_DIR:-/zpool/catallenya/pigeonhole/intake-state}"
LOCK_FILE="${STATE_DIR}/.intake.lock"
# Scratch for rasterised pages. Under STATE_DIR because that is writable as carrein
# without root (a manual run must work too), is NOT a restic target (pigeonhole/ is
# not in restic's path list), and is not synced to peers. Wiped on exit.
WORK_DIR="${STATE_DIR}/work"
VOCAB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pigeonhole.vocab.json"

# --- propose-and-approve ---------------------------------------------------
# State is the FILESYSTEM, not a state file: a document is wherever it currently
# sits, so `ls` answers "what is the system doing" and nothing can desync from
# anything else. root -> staging -> (numbered folder | bin).
#
# staging/ and bin/ are INSIDE the synced folder deliberately (owner, 2026-07-31):
# a staged document is visible on every paired device with the name it is about to
# be given, and a discarded one stays recoverable everywhere. The cost is that each
# state change propagates. Neither directory is picked up by list_candidates (root
# FILES only) or list_corpus (globs [0-9][0-9]_*), so no scan needed changing.
STAGING_DIR="${DOCS}/staging"
BIN_DIR="${DOCS}/bin"
# The records stay OUT of the synced folder — they are machinery, not documents,
# and STATE_DIR is not a restic target. approvals/ is the only directory the
# approval container can write, and it holds nothing but zero-byte markers.
PROPOSALS_DIR="${STATE_DIR}/proposals"
APPROVALS_DIR="${STATE_DIR}/approvals"

# Path safety. The closed vocabulary used to guarantee that a model-chosen value
# could never become a path; with free text that guarantee has to be enforced here
# instead, and it is the single most load-bearing check in the pipeline.
#
# The charset is what makes traversal impossible: no slash, no leading dot, and
# `..` cannot be spelled without one. Length is bounded so a pathological name
# cannot blow past NAME_MAX and get silently truncated into a different file.
SEGMENT_RE='^[a-z0-9][a-z0-9._-]{0,63}$'
valid_segment() { # $1 = one path component proposed by the model
    # LC_ALL=C is load-bearing, not tidiness. Bash's =~ honours LC_COLLATE, and under
    # en_US.UTF-8 the range [a-z] collates to include accented letters — "café"
    # MATCHES, while under C it does not. A vendor name with an accent is entirely
    # plausible, so this was reachable; worse, the function would have accepted it in
    # an interactive shell and rejected it under systemd, which sets no locale. A
    # validation result that depends on the caller's environment is a bug whichever
    # way it errs. Caught by the test suite 2026-07-31.
    local LC_ALL=C
    [[ "$1" =~ $SEGMENT_RE ]] && [[ "$1" != *".."* ]]
}

# Belt to valid_segment's braces: resolve the assembled path and require it to land
# under DOCS. valid_segment should already make this impossible, so a failure here
# means the charset check was bypassed or a component was assembled from somewhere
# it should not have been. -m so a not-yet-existing destination still resolves.
under_docs() { # $1 = candidate absolute path
    local real
    real="$(realpath -m -- "$1" 2>/dev/null)" || return 1
    [[ "$real" == "${DOCS}/"* ]]
}

new_uuid() { cat /proc/sys/kernel/random/uuid; }

# A real calendar date, at any of the three precisions the schema admits. The regex
# alone is not enough: it accepts 2023-02-29, which the 2026-07-18 battery actually
# produced, and it accepts year 0000, which shipped as a silent gap until 2026-07-30.
#
# `date -d` cannot carry the year-only case — it parses a bare "0000" as a TIME and
# returns success — so that arm is an explicit range. 10# forces base ten, or an
# unprefixed 0009 is invalid octal and aborts the arithmetic instead of failing the
# check. Upper bound allows next year: renewals and policies are dated ahead.
valid_date() { # $1 = YYYY | YYYY-MM | YYYY-MM-DD
    local dt="$1"
    case "${#dt}" in
        10) date -d "$dt" >/dev/null 2>&1 ;;
        7)  [[ "${dt:5:2}" =~ ^(0[1-9]|1[0-2])$ ]] ;;
        4)  (( 10#$dt >= 1900 && 10#$dt <= $(date +%Y) + 1 )) ;;
        *)  return 1 ;;
    esac
}

# A dropped file is only touched once Syncthing has finished with it. Two signals,
# both cheap: no scratch files alongside (Syncthing writes .syncthing.*.tmp then
# renames, so their presence means the folder is mid-work), and the API's own idle
# state. This replaced an hour-long MIN_AGE_SECONDS proxy for "probably finished";
# asking Syncthing directly is both faster and an actual answer.
docs_quiet() {
    compgen -G "${DOCS}/.syncthing.*.tmp" >/dev/null 2>&1 && return 1
    # Test seam, same rationale as DOCS above: a scratch tree has no Syncthing to
    # ask. Never set in production — without the real idle check, a mid-transfer
    # file gets classified truncated.
    [[ "${SKIP_SYNCTHING_GATE:-}" == "1" ]] && return 0
    st_folder_idle
}

SYNCTHING_CONFIG="/zpool/catallenya/syncthing/data/config/config.xml"
SYNCTHING_FOLDER_ID="3j1oy-9cefl"   # label "master"

# Reaching the Syncthing API from the host is fiddlier than it looks:
#   - :8384 is EXPOSED but NOT PUBLISHED (docker ps shows a bare "8384/tcp"), so
#     127.0.0.1:8384 reaches nothing. Consistent with commit 8051401's tailnet-only posture.
#   - The container IP (172.18.x) works but is dynamic — it moves on `compose up -d`.
#     Resolving it at runtime needs `docker inspect`, i.e. the docker socket, i.e.
#     root-equivalent access for this unit. Not worth it for a health check.
#   - So: go through Caddy on loopback with the correct SNI. Stable, cert validates,
#     no hardcoded IP, no docker socket. Port comes from .env like everything else.
# Sets ST_HOST / ST_PORT / ST_BASE as globals. Must NOT be called via $(...) — a
# subshell would set them and throw them away.
ST_HOST=""; ST_PORT=""; ST_BASE=""
st_api_base() {
    local root_env="/zpool/catallenya/.env"
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    # shellcheck source=/dev/null  # runtime-only file, not in the repo
    source "$root_env"
    ST_HOST="${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}"
    ST_PORT="${SYNCTHING_REVERSE_PROXY_PORT}"
    ST_BASE="https://${ST_HOST}:${ST_PORT}"
}

MAX_PER_RUN="${MAX_PER_RUN:-20}"   # cap; truncation is logged explicitly, never silent
# Pages rasterised and sent per document. NOT 1: page 1 is often a cover sheet, and
# classifying it reads the wrong page correctly. 3 covers 75 of 96 filed PDFs outright.
MAX_PAGES="${MAX_PAGES:-3}"

NTFY_TOPIC="pigeonhole"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# --- Syncthing -------------------------------------------------------------

# The config dir is carrein:carrein 0700 — readable as ourselves, no elevation.
st_apikey() {
    [[ -r "$SYNCTHING_CONFIG" ]] || die "cannot read $SYNCTHING_CONFIG"
    grep -oPm1 '(?<=<apikey>)[^<]+' "$SYNCTHING_CONFIG"
}

# Refuse to touch anything unless Syncthing says the folder is settled. Acting
# mid-transfer files a truncated document, and a move inside a synced folder
# propagates to every peer — a bad move is not local.
st_folder_idle() {
    local key json state need
    key="$(st_apikey)" || return 1
    st_api_base || return 1   # sets globals; NOT $(...) — see st_api_base
    json="$(curl -sS --max-time 15 --resolve "${ST_HOST}:${ST_PORT}:127.0.0.1" \
            -H "X-API-Key: ${key}" \
            "${ST_BASE}/rest/db/status?folder=${SYNCTHING_FOLDER_ID}" 2>/dev/null)" || return 1
    state="$(jq -r '.state // "unknown"' <<<"$json" 2>/dev/null)"
    need="$(jq -r '.needFiles // 1' <<<"$json" 2>/dev/null)"
    [[ "$state" == "idle" && "$need" == "0" ]]
}

# --- Candidates ------------------------------------------------------------

# Root files only. CLAUDE.md is documentation, not a document; dotfiles are
# Syncthing/macOS machinery.
list_candidates() {
    find "$DOCS" -maxdepth 1 -type f \
        ! -name 'CLAUDE.md' ! -name '.*' -printf '%f\n' 2>/dev/null | sort
}

# The filed corpus: exactly the numbered folders, any depth (catches
# 03_employment/resumes-and-cover-letters/). Naturally excludes .claude/,
# .stfolder, .stignore without an exclusion list.
list_corpus() {
    find "$DOCS"/[0-9][0-9]_* -type f ! -name '.*' 2>/dev/null | sort
}

sha256_of() { sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1; }

# --- seen.json --- REMOVED 2026-07-31
# The whole family (seen_init/get/has/put/gc/age_days) existed because the nightly
# re-scanned a root that kept its files: without memoisation one stuck document cost
# ~60 pointless classifications and 30 identical pings a month. The triage drains the
# root on every run, so nothing is ever re-seen and there is nothing to remember.
# Duplicate detection is by corpus hash, in the triage.

# --- Vocabulary ------------------------------------------------------------
# The vocabulary is a PROMPT HINT now, not a gate — the classifier is told to reuse
# these values when they fit so the same vendor is spelled the same way across years,
# but it may coin a new one and a human approves the result. vocab_has() went with the
# scorer that was the last thing enforcing membership.

is_lookalike() { # $1=doc_type $2=folder
    jq -e --arg t "$1" --arg f "$2" \
       '(._lookalike_families.doc_type | index($t)) or (._lookalike_families.folder | index($f))' \
       "$VOCAB" >/dev/null 2>&1
}

# --- ntfy ------------------------------------------------------------------

# Only the keys this pipeline needs, extracted rather than sourced. `source` on the
# root .env pulled in every database credential and service token the stack has —
# roughly forty values, to use four — and it is arbitrary code execution if that
# file ever grows a $(...), which a data file should never be able to do. capture
# fixed this first; the copy here lagged behind.
# (Deliberately not naming the variables in prose: gitleaks 8.24.3, which CI pins,
# reads a secret-shaped name beside the word "password" as a finding.)
_load_env() {
    local root_env="/zpool/catallenya/.env" k v line
    [[ -f "$root_env" ]] || { log "no .env"; return 1; }
    for k in TAILNET_DOMAIN TAILNET_DNS_NAME NTFY_REVERSE_PROXY_PORT PIGEONHOLE_REVERSE_PROXY_PORT; do
        line="$(grep -m1 "^${k}=" "$root_env" 2>/dev/null)" || continue
        v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
        printf -v "$k" '%s' "$v"
    done
}

# Where an ntfy button POSTs. Caddy serves the approval container on the tailnet;
# every component is asserted because an unset var yields a syntactically valid but
# dead URL ("https://host.ts.net:") and the buttons then fail silently on tap —
# exactly the bug capture shipped and caught only in live testing.
documents_base_url() {
    _load_env || return 1
    [[ -n "${TAILNET_DOMAIN:-}" && -n "${TAILNET_DNS_NAME:-}" ]] || {
        log "TAILNET_DOMAIN/TAILNET_DNS_NAME unset in .env"; return 1; }
    [[ -n "${PIGEONHOLE_REVERSE_PROXY_PORT:-}" ]] || {
        log "PIGEONHOLE_REVERSE_PROXY_PORT unset in .env"; return 1; }
    printf 'https://%s.%s:%s' "$TAILNET_DOMAIN" "$TAILNET_DNS_NAME" "$PIGEONHOLE_REVERSE_PROXY_PORT"
}

# reason_text <CODE> -> one capitalized human sentence for a notification body.
# The CODES stay in the records and the journal — stable, grep-able — but a phone
# notification is read half-asleep, and ZIP_NEEDS_HUMAN is not English (owner,
# 2026-08-01). An unknown code falls through unchanged, so a new one is never
# hidden behind a blank.
reason_text() {
    case "$1" in
        PDF_UNREADABLE_OR_ENCRYPTED) echo "PDF is locked or unreadable." ;;
        ZIP_ENCRYPTED_OR_CORRUPT)    echo "Archive is locked or corrupt." ;;
        ZIP_NEEDS_HUMAN)             echo "Archives are never filed automatically." ;;
        IMAGE_UNREADABLE)            echo "Image cannot be read." ;;
        UNSUPPORTED_TYPE)            echo "File type is not supported." ;;
        RASTERISE_FAILED)            echo "Pages could not be rendered." ;;
        CLASSIFY_FAILED)             echo "The model call failed." ;;
        BAD_SEGMENT)                 echo "Proposed name is not safe to use." ;;
        ESCAPES_DOCS)                echo "Proposed path leaves the documents folder." ;;
        DESTINATION_EXISTS)          echo "Something already has that name." ;;
        IMPOSSIBLE_DATE)             echo "Proposed date does not exist." ;;
        DUPLICATE)                   echo "Byte-identical copy of something already filed." ;;
        *)                           echo "$1" ;;
    esac
}

# flag_clause <FLAG> -> a predicate about "Document", combined by flags_sentence.
flag_clause() {
    case "$1" in
        NEW_FOLDER)         echo "requires a new folder" ;;
        DATE_NOT_PRINTED)   echo "has no printed date" ;;
        NO_DATE_PRINTED)    echo "has no printed date" ;;
        LOOKALIKE_FAMILY)   echo "is a type that has been misfiled before" ;;
        AMBIGUOUS_FOLDER)   echo "could belong in more than one folder" ;;
        AMBIGUOUS_DATE)     echo "shows more than one plausible date" ;;
        OWNER_UNCLEAR)      echo "does not say whose it is" ;;
        UNREADABLE)         echo "is hard to read" ;;
        MULTIPLE_DOCUMENTS) echo "contains several documents" ;;
        OK)                 echo "needs a look" ;;
        *)                  echo "is flagged $1" ;;
    esac
}

# flags_sentence — flag codes on stdin, one per line -> "Document has no printed
# date and requires a new folder." Duplicate clauses collapse: DATE_NOT_PRINTED
# and NO_DATE_PRINTED both arrive on a dateless document and must not read
# "Document has no printed date and has no printed date."
flags_sentence() {
    local c cl out="" seen=""
    while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        cl="$(flag_clause "$c")"
        [[ "$seen" == *"|${cl}|"* ]] && continue
        seen+="|${cl}|"
        out+="${out:+ and }${cl}"
    done
    [[ -n "$out" ]] && printf 'Document %s.' "$out"
}

# batch_list <record-file>... -> the notification body's item list: one item
# per document — a LITERAL "1." (dot escaped, so no markdown renderer can turn
# it into a list: the Android app renders ordered-list markers as unnumbered
# dots, seen on the actual device 2026-08-01), the original name, a HARD BREAK
# (trailing two spaces), and the destination on a second line indented with
# NBSPs — list indentation died with the list, and ordinary leading spaces are
# collapsed by the web renderer. Every construct here is load-bearing; plain
# lists, hard breaks alone, an ASCII tree, a fenced block and inline code spans
# were all tried the same day and rejected on the device. Names ARE md_escaped
# now that nothing is code-spanned: a filename is untrusted text off another
# device, and a link inside one would otherwise render live in a notification.
batch_list() {
    local f n=0 pad=$'    '
    for f in "$@"; do
        n=$((n+1))
        printf '%d\\. %s  \n%s%s\n' "$n" \
            "$(md_escape "$(jq -r '.original_name // "?"' "$f")")" \
            "$pad" \
            "$(md_escape "$(jq -r '.dest_path // "?"' "$f")")"
    done
}

# buttons <id> <1|0 offer-Accept> — the Actions header for a STAGED proposal.
# Reads $BASE, which the caller sets from documents_base_url (not passed per call:
# every caller resolves it once per run, and the triage's call sites predate this
# function living here). A blocked record is offered no Accept.
#
# NO clear=true on any of them, deliberately. pigeonhole.apply.sh withdraws the
# notification once the move has actually SUCCEEDED, which makes its disappearance
# the receipt: gone means done, still there means it did not happen (and a Refused
# ping says why). clear=true would dismiss it on the tap instead — instant, and a
# lie every time the move is refused.
#
# THE UNDO IS GONE (2026-08-09, owner's call). These buttons used to stay live after
# a tap so that `filed → discard` could walk the document back, which fell out of the
# state rule for free. It also meant every document you ever filed left a permanent
# notification. One action, one outcome, notification gone is the trade; a document
# filed to the wrong place is recovered by MOVING THE FILE — it is in Syncthing on
# every device, bin/ is never emptied, and ZFS snapshots sit behind both.
buttons() { # $1=id $2=1 if the Accept button should be offered
    local id="$1" b=""
    [[ "$2" == "1" ]] && b="http, Accept, ${BASE}/pigeonhole/${id}/accept, method=POST, headers.X-Documents=1; "
    printf '%shttp, Discard, %s/pigeonhole/%s/discard, method=POST, headers.X-Documents=1' \
        "$b" "$BASE" "$id"
}

# bin_buttons <id> <1|0 offer-Accept> — for the note a document gets when it ages
# into bin/ after its week. Two terminal choices and no Skip: it has already had
# its week, and offering to send it back to staging just restarts a clock it
# already ran out.
#
# Delete is the ONLY destructive button in the pipeline. It does not conflict with
# "the sweep never empties bin/" — that rule is really "nothing is destroyed
# without a tap", and this is the tap. Behind it: bin/ rides in Syncthing (so the
# delete propagates, which is the point) and under ZFS/sanoid snapshots plus
# restic, which is the actual recovery path for a mis-tap.
bin_buttons() { # $1=id $2=1 if the Accept button should be offered
    local id="$1" b=""
    [[ "$2" == "1" ]] && b="http, Accept, ${BASE}/pigeonhole/${id}/accept, method=POST, headers.X-Documents=1; "
    printf '%shttp, Delete, %s/pigeonhole/%s/delete, method=POST, headers.X-Documents=1' \
        "$b" "$BASE" "$id"
}

# ntfy sequence id for the batch notification. A STABLE literal, not a record id:
# there is only ever one live batch message, exactly as there is only ever one
# batch record that is not `superseded`, and giving it a fixed id lets each new
# batch withdraw the last one without having to look up which id that was.
# Per-topic, so it cannot collide with anything outside this pipeline.
BATCH_NTFY_ID="documents-batch"

# notify <title> <priority> <tags> <body> [actions] [id]
#
# `id` is an ntfy sequence id (X-Sequence-ID) — what retract() addresses, and the only way
# to take a notification off the phone. Tag anything that a later message will
# supersede: solo proposals with the RECORD id, batches with $BATCH_NTFY_ID.
#
# Retracting here is not symmetric with capture. A documents notification is the
# UNDO HANDLE (see buttons()), so it may only be withdrawn when the message
# replacing it carries the same buttons — the nudge and the binned note both do.
# Nothing withdraws a notification on a tap; that would delete the handle.
notify() { # $1=title $2=priority $3=tags $4=body [$5=actions] [$6=id]
    _load_env || { log "skipping notify"; return 0; }
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    # Title carries a filename, which is untrusted — it arrives over Syncthing from
    # whatever device wrote it. hdr_safe strips the CR/LF that would otherwise inject
    # a second Actions header and replace the real buttons.
    local -a hdr=(-H "Title: $(hdr_safe "$1")" -H "Tags: $3" -H "Markdown: yes")
    [[ -n "${2:-}" ]] && hdr+=(-H "Priority: $2")
    # Sanitised here rather than left to callers: the URLs are ours, but the labels
    # beside them are not always going to be.
    [[ -n "${5:-}" ]] && hdr+=(-H "Actions: $(tr -d '\r\n' <<<"$5")")
    # X-Sequence-ID, and only this spelling family. `X-ID` looks like the obvious
    # name, is accepted with a 200, and is SILENTLY IGNORED — the message comes back
    # with no sequence_id and every later retract addresses nothing. Verified
    # against 2.27.0 by diffing our header against the CLI's own --sequence-id:
    # X-Sequence-ID / Sequence-ID / Sid work, X-ID / X-Seq / Seq do not.
    [[ -n "${6:-}" ]] && hdr+=(-H "X-Sequence-ID: $(ntfy_id_safe "$6")")
    # --data-raw, never -d: curl reads a -d value beginning with "@" as a FILENAME
    # and POSTs that file's contents. The body starts with a filename from the root
    # of master/documents, so a synced file named "@/zpool/catallenya/.env" would
    # exfiltrate that file to this (unauthenticated) topic. --data-raw is
    # byte-identical except it never interprets a leading @.
    ntfy_muted && return 0
    curl -sS "${hdr[@]}" \
         --data-raw "$(tail -c 3500 <<<"$4")" "${url}/${NTFY_TOPIC}" >/dev/null || true
}

# Test seam, same rationale as DOCS/STATE_DIR above and API_URL in ai.lib.sh — and
# the only one of the three that was missing, which cost something real: the suite
# runs the REAL triage and apply against a scratch tree, so while their FILES went
# to /tmp, every notification they raised went to the live `documents` topic. A
# full test run put dozens of "Refused: 1 Document" pings on the owner's phone,
# and there was no seam to stop it. Capture never showed the same symptom only
# because its suite runs the sweep exclusively with --dry-run.
#
# Deliberately placed just BEFORE the curl in both functions, not at the top: the
# header construction, hdr_safe and ntfy_id_safe still run under test, so a crash
# in any of them is still caught. Only the wire call is suppressed.
# Never set in production.
ntfy_muted() { [[ "${NTFY_DISABLE:-}" == "1" ]]; }

# ntfy_id_safe <id> — reduce an id to what is safe in BOTH a header value and a
# URL path segment. Record ids are UUIDs and the batch id is a literal, so this
# changes nothing today; it is here because the id reaches ntfy through two
# different syntaxes and a stray slash would silently retract the wrong path.
#
# Leading dots go too, which is not fussiness: the charset alone leaves ".." whole,
# and DELETE on <topic>/.. resolves to the topic root rather than to a message.
# Stripping them empties that value, and retract() declines an empty id.
ntfy_id_safe() { tr -cd 'A-Za-z0-9._-' <<<"$1" | sed 's/^\.*//'; }

# retract <id> — take a previously tagged notification off the phone.
#
# ntfy has no per-message expiry and no scheduled delete (checked against 2.27.0,
# our server): the only way a notification disappears is an explicit DELETE
# addressed to its sequence id, which the server broadcasts to subscribers as a
# message_delete event. Hence the X-Sequence-ID on everything retractable.
#
# Best-effort, like notify(): a failed retract leaves clutter, never a wrong
# outcome. The server answers 200 for an id it has never seen, so a speculative
# call is free — which is what makes "retract, then publish the replacement" a
# safe unconditional pair even for a record that was never notified solo.
#
# Known gap: the delete event is cached like any message, so a phone offline
# longer than the cache window (NTFY_CACHE_DURATION, widened to 72h in
# docker-compose.yml for exactly this reason) never receives it and keeps the
# stale notification. The app's own auto-delete mops up that straggler.
retract() {
    local id="${1:-}"
    [[ -n "$id" ]] || return 0
    _load_env || return 0
    local url="https://${TAILNET_DOMAIN}.${TAILNET_DNS_NAME}:${NTFY_REVERSE_PROXY_PORT}"
    ntfy_muted && return 0
    curl -sS --max-time 15 -X DELETE \
         "${url}/${NTFY_TOPIC}/$(ntfy_id_safe "$id")" >/dev/null || true
}
