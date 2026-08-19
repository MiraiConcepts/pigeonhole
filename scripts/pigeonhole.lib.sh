#!/bin/bash
# shellcheck disable=SC2034  # config vars are consumed by the scripts that source this
# Shared helpers for the pigeonhole documents pipeline.
# Sourced by pigeonhole.{triage,apply,sweep}.sh — not executable on its own.
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
# shellcheck source=/zpool/catallenya/ntfy/ntfy.lib.sh
source "/zpool/catallenya/ntfy/ntfy.lib.sh"
# The Syncthing quiet gate, shared with liquidroom — st_apikey / st_api_base /
# st_folder_idle / syncthing_quiet, the folder id and the SKIP_SYNCTHING_GATE test
# seam. It was two byte-identical copies differing only in which directory the .tmp
# glob watched; that directory is now syncthing_quiet's argument.
# shellcheck source=/zpool/catallenya/syncthing/syncthing.lib.sh
source "/zpool/catallenya/syncthing/syncthing.lib.sh"

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
# approval container can write, and a marker is the smallest possible thing:
# {"action":…,"at":…} and nothing else. The security property is not that the file
# is empty — pigeonhole.apply.sh READS the action out of it — it is that the marker
# carries NO PATH. The container names an id and a verb; where that document is and
# where it may go are read from the record the triage wrote.
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

# The same check for the OTHER destination a model-derived name reaches: staging/.
# under_docs is not a substitute — staging/ is itself under DOCS, so a name that
# walks out of staging/ and lands at the DOCS ROOT passes under_docs cleanly, and
# the root is the one directory in this tree that must never receive a write: the
# path unit fires on it, so a document that lands there re-triages itself forever
# at one model call per fire. That is exactly what a `date` of "../0801" did
# (2026-08-19) — through a valid_date arm that checked two characters of a
# seven-character string and never looked at the other five.
under_staging() { # $1 = candidate absolute path
    local real
    real="$(realpath -m -- "$1" 2>/dev/null)" || return 1
    [[ "$real" == "${STAGING_DIR}/"* ]]
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
#
# EVERY ARM ANCHORS THE WHOLE STRING, and that is the load-bearing part. This value
# is spliced straight into a filename, so a date is a path component whether or not
# it looks like one. Until 2026-08-19 the arms were selected by LENGTH and then
# checked a substring: the 7-char arm read characters 5-6 and nothing else, so
# "../0801" passed (its "08" is a valid month) and staged the document at the DOCS
# root; the 10-char arm was a bare `date -d`, which happily parses "01/02/2003".
# The switch on length stays — it is what picks the precision — but no arm may now
# accept a character it has not looked at.
valid_date() { # $1 = YYYY | YYYY-MM | YYYY-MM-DD
    # LC_ALL=C for the same reason valid_segment sets it: [0-9] under a UTF-8
    # collation is not the ASCII digits, and a check that depends on the caller's
    # environment is a bug whichever way it errs.
    local dt="$1" LC_ALL=C
    case "${#dt}" in
        10) [[ "$dt" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] \
                && date -d "$dt" >/dev/null 2>&1 ;;
        7)  [[ "$dt" =~ ^[0-9]{4}-(0[1-9]|1[0-2])$ ]] ;;
        4)  [[ "$dt" =~ ^[0-9]{4}$ ]] \
                && (( 10#$dt >= 1900 && 10#$dt <= $(date +%Y) + 1 )) ;;
        *)  return 1 ;;
    esac
}

# The Syncthing quiet gate lives in syncthing/syncthing.lib.sh (sourced at the top),
# shared with liquidroom. The triage calls syncthing_quiet "$DOCS" — a dropped file
# is only touched once Syncthing has finished with it, because acting mid-transfer
# files a truncated document and a move inside a synced folder propagates to every
# peer. docs_quiet() was the local name for it; the only thing it added over the
# shared function was the directory, which is now the argument.

MAX_PER_RUN="${MAX_PER_RUN:-20}"   # cap; truncation is logged explicitly, never silent
# Pages rasterised and sent per document. NOT 1: page 1 is often a cover sheet, and
# classifying it reads the wrong page correctly. 3 covers 75 of 96 filed PDFs outright.
MAX_PAGES="${MAX_PAGES:-3}"

NTFY_TOPIC="pigeonhole"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

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

# --- records and destinations ----------------------------------------------

# bin_dest <current-path> -> where this document goes in bin/, never clobbering.
#
# THREE different paths move a document to bin/ — a Discard tap, a week untouched in
# staging, a week parked behind a dead API — and they must agree, because the record
# stores where the file LANDED and every later tap reads that back. A name already
# taken gets a UTC timestamp prefix. Two documents can legitimately share a name (the
# same statement re-downloaded, a scan repeated), and the one thing this pipeline
# must never do is lose one to a silent overwrite.
bin_dest() {
    local base dest
    base="$(basename "$1")"
    dest="${BIN_DIR}/${base}"
    [[ -e "$dest" ]] && dest="${BIN_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-${base}"
    printf '%s' "$dest"
}

# staged_class <record-file> -> clean | flagged | blocked | paused | "" (not staged)
#
# The ONE predicate that says what a staged record is, because two callers disagreeing
# about it is a real defect rather than a tidiness point: the triage decides which
# bucket a proposal is notified in, and the sweep decides which proposals a re-batch
# rebuilds from. When the sweep's copy drifted to "only the overdue ones", the
# replacement message silently dropped every clean proposal that was not yet 24h old.
#
# ORDER MATTERS. paused outranks blocked outranks flagged: a parked document has no
# proposal at all, so offering it an Accept button would be offering a decision that
# was never made.
staged_class() {
    local f="$1"
    [[ "$(jq -r '.state // ""' "$f" 2>/dev/null)" == "staged" ]] || return 0
    [[ "$(jq -r '.kind  // ""' "$f")" == "batch"  ]] && return 0
    [[ "$(jq -r '.paused  // "null"' "$f")" != "null" ]] && { printf paused;  return 0; }
    [[ "$(jq -r '.blocked // "null"' "$f")" != "null" ]] && { printf blocked; return 0; }
    [[ "$(jq -r '.flags | length' "$f")" != "0" ]]       && { printf flagged; return 0; }
    printf clean
}

# retire_batches — mark every live batch record `superseded`.
#
# A batch is a SNAPSHOT of what was staged when its notification went out, so once a
# newer one exists the old record is only useful if you tap its (still-live) message,
# which apply re-verifies member by member anyway. Without this they accumulate one
# per run forever and nothing distinguishes the live batch from its predecessors.
# Called by the triage and by the sweep, immediately before each mints its own.
retire_batches() {
    local old
    for old in "${PROPOSALS_DIR}"/*.json; do
        [[ -f "$old" ]] || continue
        [[ "$(jq -r '.kind  // ""' "$old")" == "batch"  ]] || continue
        [[ "$(jq -r '.state // ""' "$old")" == "staged" ]] || continue
        jq -c '. + {state:"superseded"}' "$old" > "${old}.tmp" && mv "${old}.tmp" "$old"
    done
}

# notif_id <record-file> -> the ntfy sequence id the message carrying this record's
# buttons was published under.
#
# A solo proposal's message rides its own record id. The BATCH message rides
# BATCH_NTFY_ID, because there is only ever one live batch and each new one has to
# withdraw the last without looking up which id that was — which means a tap on a
# batch must withdraw that literal too. It used to retract the batch RECORD's uuid,
# an id nothing was ever published under, so every batch notification survived the
# tap that emptied it and its Accept button then answered "No such proposal."
notif_id() {
    local f="$1"
    [[ "$(jq -r '.kind // ""' "$f" 2>/dev/null)" == "batch" ]] \
        && { printf '%s' "$BATCH_NTFY_ID"; return 0; }
    printf '%s' "$(basename "$f" .json)"
}

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
#
# The EXTRACTION is _ntfy_env's, in ntfy/ntfy.lib.sh; the KEY LIST stays here. That
# split is the point rather than an accident of refactoring: three pipelines needed
# the same loop over a different set of names, and a shared function that guessed
# which set to read — or read the union of all of them — would be a bug waiting for
# the next pipeline. The one key below is this pipeline's own.
# (Deliberately not naming the variables in prose: gitleaks 8.24.3, which CI pins,
# reads a secret-shaped name beside the word "password" as a finding.)
_load_env() { _ntfy_env PIGEONHOLE_REVERSE_PROXY_PORT; }

# Where an ntfy button POSTs. Caddy serves the approval container on the tailnet;
# every component is asserted because an unset var yields a syntactically valid but
# dead URL ("https://host.ts.net:") and the buttons then fail silently on tap —
# exactly the bug capture shipped and caught only in live testing.
pigeonhole_base_url() {
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
# Reads $BASE, which the caller sets from pigeonhole_base_url (not passed per call:
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
    [[ "$2" == "1" ]] && b="http, Accept, ${BASE}/pigeonhole/${id}/accept, method=POST, headers.X-Pigeonhole=1; "
    printf '%shttp, Discard, %s/pigeonhole/%s/discard, method=POST, headers.X-Pigeonhole=1' \
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
    [[ "$2" == "1" ]] && b="http, Accept, ${BASE}/pigeonhole/${id}/accept, method=POST, headers.X-Pigeonhole=1; "
    printf '%shttp, Delete, %s/pigeonhole/%s/delete, method=POST, headers.X-Pigeonhole=1' \
        "$b" "$BASE" "$id"
}

# ntfy sequence id for the batch notification. A STABLE literal, not a record id:
# there is only ever one live batch message, exactly as there is only ever one
# batch record that is not `superseded`, and giving it a fixed id lets each new
# batch withdraw the last one without having to look up which id that was.
# Per-topic, so it cannot collide with anything outside this pipeline.
#
# DO NOT RENAME IT to match the pipeline's own rename. The value is not a label, it
# is the address of a message that may be on the phone right now: change it and the
# live batch notification becomes unaddressable — nothing can ever withdraw it, and
# it sits there listing documents that have all moved on. The one word left saying
# "documents" here is load-bearing for exactly that reason.
BATCH_NTFY_ID="documents-batch"
# The paused message is one-per-topic, not one-per-document: a stable literal, so the
# next run retracts the previous one and republishes with the new count rather than
# stacking a ping per stuck document. Twelve documents arriving during an outage is
# one fact, and it should read as one.
PAUSED_NTFY_ID="pigeonhole-paused"

# sync_paused_summary — the one "Paused: N Documents" message for this topic, rebuilt
# from the records and reconciled with what is on the phone.
#
# Called UNCONDITIONALLY at the end of any run that could have changed the paused set
# (both ways into the triage, and the sweep after it bins the ones that ran out of
# time). paused_sync retracts first and publishes only if anything is left, so the run
# that RESOLVES an outage is the run that takes the count off the phone. That used to
# be the one run that could not: the retract lived INSIDE the "something is paused"
# branch, so a recovered pipeline left "Paused: 3 Documents" sitting there forever,
# naming documents that had long since been filed.
#
# The reason is the most recently parked STAGED record's. Reading `.paused` from every
# record in glob order took whichever uuid sorted last — effectively at random — and
# counted records that had since been binned, so the message could report an outage
# that was over while a different one was running.
sync_paused_summary() {
    # LC_ALL=C so the timestamp comparison below is byte order, not collation order.
    local f ff reason="" newest="" LC_ALL=C
    local -a items=()
    for f in "${PROPOSALS_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(staged_class "$f")" == "paused" ]] || continue
        items+=("$(basename "$(jq -r '.at // .staged_path // .original_name' "$f")")")
        ff="$(jq -r '.first_failed_at // ""' "$f")"
        if [[ -z "$reason" || "$ff" > "$newest" ]]; then
            newest="$ff"; reason="$(jq -r '.paused' "$f")"
        fi
    done
    # Five fixed slots, then the items; with none it is a bare retract. The outcome
    # clause is pigeonhole's own — a parked document survives in bin/, which is not
    # true of afterimage's screenshots, and flattening that would make the message
    # consistent by hiding the part you most need to know.
    paused_sync "$PAUSED_NTFY_ID" Document "${reason:-The API is unavailable}" \
        "moved to bin/ in 7 days, nothing is deleted" "${items[@]}"
}

# notify / retract / ntfy_muted / ntfy_id_safe moved to ntfy/ntfy.lib.sh (sourced at
# the top), unchanged. Four near-identical copies lived across the repo and had
# already drifted — two had no --max-time, one had no hdr_safe.
#
# What stays pigeonhole's own is the retraction POLICY, which is not symmetric with
# afterimage's. THE RULE: a notification lives exactly as long as its decision is
# outstanding. A tap withdraws its own message — but only when nothing was refused
# (see the drain loop in pigeonhole.apply.sh), because a refused tap moved nothing
# and those buttons are still the way to act on the document. That conditional is
# what makes a message's disappearance mean "it happened" rather than "you tapped".
# A message REPLACED rather than resolved — the 24h nudge, the binned note — is
# withdrawn only by a replacement carrying the same buttons, so the handle survives.
#
# `id` is an ntfy sequence id. Tag anything a later message will supersede: solo
# proposals with the RECORD id, batches with $BATCH_NTFY_ID (see notif_id).
