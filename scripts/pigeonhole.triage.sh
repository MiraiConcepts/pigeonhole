#!/bin/bash
# pigeonhole.triage.sh — drop a document at the root of master/documents, get a
# proposal you can approve. Replaces the scan/classify/apply nightly.
#
# Fired by pigeonhole.triage.path the moment a file lands at the root. Drains the
# whole root serially, then exits.
#
# HARD INVARIANT — every file MUST leave the root before this script exits, on
# every branch, success or failure. PathExistsGlob re-fires for as long as a file
# remains, so a document left in place hot-loops systemd and bills an API call per
# spin. This is the same invariant afterimage.triage.sh carries, learned the same way.
# Nothing below returns without having moved the file to staging/ or bin/.
#
# WHY THERE IS NO LONGER A VOCABULARY GATE. The old pipeline filed unsupervised, so
# safety came from a closed enum: every field the model could fill was a dropdown,
# and it could never emit a string that becomes a path. That cost a hand-edit of
# pigeonhole.vocab.json roughly every other document — 15 of 33 vendors in the corpus
# appear exactly once, and the tail is unbounded. A human tap now sits between the
# model and the filesystem, so the enum's job is done by the human, and the fields
# are free text. What replaces the enum is valid_segment() plus under_docs() in
# pigeonhole.lib.sh, and those are the load-bearing checks now. Do not weaken them.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/pigeonhole/scripts/pigeonhole.lib.sh
source "${SELF_DIR}/pigeonhole.lib.sh"

# Model + effort come from ai.lib.sh (AI_MODEL / AI_EFFORT), shared with the
# capture pipeline — one edit there moves both.
MAX_TOKENS=4096

# QUIET_WAIT_S / QUIET_POLL_S come from syncthing/syncthing.lib.sh with liquidroom,
# which waits on the same folder. The service also carries a start limit as a
# backstop against a Syncthing that never settles.

for _bin in jq curl base64 od sha256sum pdfinfo pdftoppm identify; do
    command -v "$_bin" >/dev/null || die "missing required command: ${_bin}"
done
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set (EnvironmentFile=/etc/ai.env)}"

mkdir -p "$STATE_DIR" "$WORK_DIR" "$PROPOSALS_DIR" "$APPROVALS_DIR" "$STAGING_DIR" "$BIN_DIR"

# Serialise. A slow classification must not overlap the next .path fire.
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another triage holds the lock; exiting"; exit 0; }

cleanup() { rm -f "${WORK_DIR:?}"/*.png 2>/dev/null || true; }
trap cleanup EXIT

# --- openability -----------------------------------------------------------
# Runs BEFORE rasterisation on purpose: a file locked precisely because it is
# sensitive (SG lab reports are commonly NRIC/DOB-protected) never leaves the
# machine at all. Deciding on metadata rather than content is the only way to get
# that property.
#
# THE IMAGE FORMATS ARE THE ONES THIS BOX CAN ALREADY RENDER. HEIC and HEIF are the
# iPhone defaults, so photographing a document with one was the largest real gap;
# TIFF is what scanners emit and WEBP what a browser saves. All verified to
# round-trip through ImageMagick here on 2026-07-31 — none of them needed a new
# dependency, which is why the list is this long and stops where it does.
#
# Anything NOT here is still staged and reported as UNSUPPORTED_TYPE rather than
# ignored: silence about a file you dropped is the worst outcome, worse than "I
# cannot read this".
openable() { # $1=path -> echoes reason_code on failure
    local f="$1" ext="${1##*.}"
    case "${ext,,}" in
        pdf)       pdfinfo "$f" >/dev/null 2>&1 || { echo "PDF_UNREADABLE_OR_ENCRYPTED"; return 1; } ;;
        zip)       unzip -t "$f" >/dev/null 2>&1 || { echo "ZIP_ENCRYPTED_OR_CORRUPT"; return 1; }
                   echo "ZIP_NEEDS_HUMAN"; return 1 ;;   # archives are never auto-proposed
        jpg|jpeg|png|heic|heif|webp|tiff|tif|avif)
                   identify "$f" >/dev/null 2>&1 || { echo "IMAGE_UNREADABLE"; return 1; } ;;
        *)         echo "UNSUPPORTED_TYPE"; return 1 ;;
    esac
    return 0
}

# Page 1 is often NOT the informative page — the 7-page W-2 opens with a cover
# sheet carrying no year, no employer and no form. Cap at MAX_PAGES: 75 of 96
# filed PDFs are within it, and later pages are boilerplate far more often than
# they are the document's identity.
rasterise() { # $1=src $2=out_prefix -> one png path per line
    local f="$1" out="$2" ext="${1##*.}"
    case "${ext,,}" in
        pdf) pdftoppm -png -r 150 -f 1 -l "$MAX_PAGES" "$f" "$out" >/dev/null 2>&1 || return 1
             local p; p="$(ls "${out}"-*.png 2>/dev/null | sort -V)"
             [[ -n "$p" ]] && { printf '%s\n' "$p"; return 0; }; return 1 ;;
        jpg|jpeg|png|heic|heif|webp|tiff|tif|avif)
             # -flatten collapses transparency and any multi-frame image to one
             # page. Without it a transparent PNG renders as black, and a
             # multi-page TIFF (which is what a sheet-feed scanner produces)
             # silently writes out-0.png, out-1.png and we would send neither.
             convert "$f"[0] -flatten "${out}.png" >/dev/null 2>&1 || return 1
             echo "${out}.png"; return 0 ;;
    esac
    return 1
}

# --- schema ----------------------------------------------------------------
# folder / doc_type / qualifier are free text bounded by SEGMENT_RE. owner stays an
# enum: it is four real people plus "unknown", it is genuinely closed, and it only
# ever becomes a filename suffix. `date` keeps its regex — and note the gate still
# range-checks a year-only value, because the regex happily accepts 0000.
build_schema() {
    jq -n --arg seg "${SEGMENT_RE#^}" --argjson owner "$(jq -c '.owner' "$VOCAB")" \
      '($seg | rtrimstr("$")) as $s |
       {
        type: "object",
        properties: {
          folder:        {type:"string", pattern:("^" + $s + "$")},
          folder_is_new: {type:"boolean"},
          doc_type:      {type:"string", pattern:("^" + $s + "$")},
          qualifier:     {type:"string", pattern:("^" + $s + "$")},
          owner:         {type:"string", enum:$owner},
          date:          {type:"string", pattern:"^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$"},
          date_source:   {type:"string", enum:["printed_on_document","inferred","absent"]},
          needs_human:   {type:"boolean"},
          reason_code:   {type:"string", enum:[
            "OK","AMBIGUOUS_FOLDER","AMBIGUOUS_DATE","NO_DATE_PRINTED",
            "OWNER_UNCLEAR","UNREADABLE","MULTIPLE_DOCUMENTS","LOOKALIKE_FAMILY"]}
        },
        required: ["folder","folder_is_new","doc_type","qualifier","owner","date",
                   "date_source","needs_human","reason_code"],
        additionalProperties: false
      }'
}

# --- model calls -----------------------------------------------------------

ask() { # $1=newline-separated pngs $2=prompt $3=schema
    local pngs="$1" prompt="$2" schema="$3" msgf out pg
    local -a imgs=()
    while IFS= read -r pg; do [[ -n "$pg" ]] && imgs+=("$pg"); done <<<"$pngs"
    msgf="$(mktemp)"
    ai_build_request "$msgf" "$AI_MODEL" "$AI_EFFORT" "$MAX_TOKENS" "$schema" "$prompt" \
        "${imgs[@]}" || { rm -f "$msgf"; return 1; }
    local rc=0
    out="$(api_post "$msgf")" || rc=$?
    rm -f "$msgf"
    (( rc == 0 )) || return "$rc"
    ai_extract "$out"
}

# The vocabulary is now a PREFERENCE, not a constraint. Without it the same vendor
# arrives as anthropic, Anthropic and anthropic-pbc across three years; with it as
# an enum, every new vendor needed a hand-edit. Naming it here gets the consistency
# without the treadmill.
classify_prompt() {
    cat <<EOF
You are naming and filing one personal document. The images are its rendered pages.

Return the folder it belongs in, what kind of document it is, who issued it, whose
it is, and its date. These become the path and filename:
  <folder>/<date>_<doc_type>_<qualifier>.<ext>

FOLDERS THAT EXIST. Use one of these unless the document genuinely belongs nowhere
in them:
$(find "$DOCS" -maxdepth 1 -type d -name '[0-9][0-9]_*' -printf '  %f\n' 2>/dev/null | sort)
If none fits, propose a NEW folder name and set folder_is_new=true. Follow the same
NN_lowercase-with-hyphens shape and pick the next free number. Do this sparingly —
a new folder the owner has to merge later is worse than a slightly loose fit. If an
existing folder is merely imperfect, use it and set folder_is_new=false.

VALUES ALREADY IN USE. Reuse one of these EXACTLY when it fits, so the same thing
is always spelled the same way. Coin a new one only when nothing here matches.
  doc_type:  $(jq -r '.doc_type | join(", ")' "$VOCAB")
  qualifier: $(jq -r '.qualifier | join(", ")' "$VOCAB")

FORMAT. folder, doc_type and qualifier must be lowercase, may contain only letters,
digits, dots, hyphens and underscores, must start with a letter or digit, and must
not contain "..". Use hyphens between words. qualifier is the issuer or vendor —
use "none" when the document has no meaningful issuer.

Rules (from the owner's filing scheme):
- Pick the folder by the document's PURPOSE. Insurance = cards/policies/claims.
  Medical = clinical results and notes. Receipts = purchase invoices/receipts,
  INCLUDING medical ones (an invoice from a clinic is a receipt, not a medical
  record).
- invoice vs receipt: use WHAT THE DOCUMENT CALLS ITSELF. If it is headed "Invoice"
  or "Tax Invoice", doc_type is "invoice". If headed "Receipt", it is "receipt".
  Do not reason about which word fits better — read the heading.
- date: use the MOST PRECISE date PRINTED ON the document itself. Never guess from
  context. Month only -> YYYY-MM. Year only -> YYYY (a tax form's date is its tax
  year). If no date is printed at all, set date_source="absent" and needs_human=true.
- When SEVERAL dates are printed, prefer the report/issue/generated/statement date
  over received, collected, due, delivery or payment dates. (Battery-verified
  2026-07-18: a lab report printing "Received 06 Nov" and "Generated 07 Nov" files
  as 11-07 — the owner adjudicated exactly this class by hand.)
- Singapore documents print dates as DD/MM/YYYY: 08/07/2026 is 8 July, never Aug 7.
- owner: an EMAIL ADDRESS identifies a person just as a name does. A document
  addressed to owner@example.invalid is owner="self" even if no name appears on
  it — online receipts routinely identify the customer only by account email. Match
  the address itself, not the domain: protonmail.com is a mail provider.
  "self" is the repository owner. Other known people are in the schema
  enum: REDACTED-PERSON-B, REDACTED-PERSON-C, REDACTED-PERSON-D.
  Someone not listed -> owner="unknown" and needs_human=true.
- Set needs_human=true when you are unsure of anything. It costs the owner a glance;
  a misfiling costs them a lost document.
EOF
}

# --- staging ---------------------------------------------------------------

# stage_file <src> <desired-basename> -> echoes the staged path
# Never clobbers: a collision in staging gets -2, -3, ... Two documents can
# legitimately propose the same name (two invoices from one vendor on one day) and
# losing one to a silent overwrite is the outcome this whole pipeline exists to
# avoid.
stage_file() {
    local src="$1" want="$2" stem ext dest n=2
    stem="${want%.*}"; ext="${want##*.}"
    dest="${STAGING_DIR}/${want}"
    # Already exactly where it belongs — a retry re-staging a document that never
    # left. Without this the collision loop below treats the file as its own
    # duplicate and renames it doc-2.pdf, then doc-3.pdf, once per day of the outage.
    [[ "$src" == "$dest" ]] && { printf '%s' "$dest"; return 0; }
    while [[ -e "$dest" ]]; do dest="${STAGING_DIR}/${stem}-${n}.${ext}"; n=$((n+1)); done
    # THE LAST LAYER, and the only one that guards the WRITE rather than a value.
    # `want` is assembled from model output, so a single component that walks up a
    # directory ("../0801") turns this line into a move to the DOCS ROOT — where the
    # path unit sees the file, fires this script, and buys a model call per spin.
    # valid_date and valid_segment both have to fail for that to be reachable, and on
    # 2026-08-19 both did. Checked after the collision loop, because the loop rebuilds
    # the path from `stem` and would carry an escape straight through.
    under_staging "$dest" || { log "  !! ${want} does not resolve inside staging/"; return 1; }
    mv -n -- "$src" "$dest" 2>/dev/null || return 1
    [[ -f "$dest" && ! -e "$src" ]] || return 1
    printf '%s' "$dest"
}

# record <uuid> <json>  — the proposal file is the durable half of the state.
# It is never deleted, which is what makes undo free: a discard against an already
# accepted record knows where the document went.
NEW_IDS=()
record() { printf '%s\n' "$2" > "${PROPOSALS_DIR}/${1}.json"; NEW_IDS+=("$1"); }

# --- drain the root --------------------------------------------------------

waited=0
until syncthing_quiet "$DOCS"; do
    (( waited >= QUIET_WAIT_S )) && { log "syncthing still busy after ${waited}s; leaving root for the next fire"; exit 0; }
    sleep "$QUIET_POLL_S"; waited=$((waited + QUIET_POLL_S))
done

# --- the second way in -------------------------------------------------------
# `--retry` re-runs the classify against documents already sitting in staging/,
# parked because the API could not answer. They are NOT moved back to the root to be
# picked up the normal way: the root is a Syncthing folder, so a move out and back
# would replicate to every device, twice a day, for as long as the outage lasts.
#
# Everything below is the same machinery. The loop already works on a path relative
# to $DOCS, so a staged path drops straight into it; what differs is that a retry
# UPDATES the record it already has — keeping its id and, critically, its
# first_failed_at — rather than minting a new one and restarting the seven-day clock.
RETRY=0
declare -A RETRY_ID=()
if [[ "${1:-}" == "--retry" ]]; then
    RETRY=1; shift
    CANDS=()
    for f in "${PROPOSALS_DIR}"/*.json; do
        [[ -f "$f" ]] || continue
        [[ "$(jq -r '.state  // ""' "$f")" == "staged" ]] || continue
        [[ "$(jq -r '.paused // "null"' "$f")" == "null" ]] && continue
        rel="$(jq -r '.at // .staged_path // empty' "$f")"
        [[ -n "$rel" && -f "${DOCS}/${rel}" ]] || continue
        CANDS+=("$rel"); RETRY_ID["$rel"]="$(basename "$f" .json)"
    done
    # Nothing parked is the HEALTHY end of an outage, and it is also the run that has
    # to say so: the paused summary is withdrawn from here, not just from the bottom
    # of a full run. Without this the last document to recover took its record out of
    # the paused set and then the script exited above the only line that tells the
    # phone — leaving "Paused: 1 Document" naming a document already filed.
    (( ${#CANDS[@]} )) || { log "nothing parked"; sync_paused_summary; exit 0; }
    log "retrying ${#CANDS[@]} parked document(s)"
else
    mapfile -t CANDS < <(list_candidates)
    (( ${#CANDS[@]} )) || { log "nothing at root"; exit 0; }
fi

# CAP THE RUN. A model call per document, unattended, with no ceiling is a bill
# waiting to happen — dropping a phone's worth of scans in at once would have spent
# hundreds of calls before anyone noticed. The remainder stays at root, so the .path
# unit re-fires and the next run takes the next MAX_PER_RUN. Truncation is logged and
# surfaced in the notification, never silent.
TRUNCATED=0
if (( RETRY == 0 )) && (( ${#CANDS[@]} > MAX_PER_RUN )); then
    TRUNCATED=$(( ${#CANDS[@]} - MAX_PER_RUN ))
    log "CAP: ${#CANDS[@]} at root, taking ${MAX_PER_RUN}, deferring ${TRUNCATED} to the next run"
    CANDS=("${CANDS[@]:0:$MAX_PER_RUN}")
fi
(( RETRY )) || log "draining ${#CANDS[@]} file(s) from root"

# The filed corpus, hashed, for duplicate detection. 135 files in well under a
# second, so there is no cache to invalidate and nothing to go stale.
declare -A CORPUS_BY_HASH=()
while IFS= read -r f; do CORPUS_BY_HASH["$(sha256_of "$f")"]="$f"; done < <(list_corpus)

STAGED=0; BINNED=0; BLOCKED=0; PAUSED=0
# A document that could not even be MOVED out of the Syncthing root. Counted, not just
# logged, because this is the one failure the run cannot otherwise record: no record is
# written, so the notify loop below — which walks records — is structurally blind to it,
# and the .path unit re-fires on the file at an API call per spin. afterimage learned
# this the hard way and grew `Stuck`; pigeonhole had the identical bug and exited 0.
STUCK=0

for name in "${CANDS[@]}"; do
    src="${DOCS}/${name}"
    [[ -f "$src" ]] || continue          # vanished under us; nothing to drain
    # In retry mode $name is a path under staging/, so anything that wants a filename
    # takes $bname. For a root document the two are identical.
    bname="$(basename "$name")"
    if (( RETRY )); then
        id="${RETRY_ID[$name]}"
    else
        id="$(new_uuid)"
    fi
    sha="$(sha256_of "$src")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if (( RETRY )); then
        # Carry the original name, the moment it first arrived and the moment it first
        # failed. Losing first_failed_at here would restart the seven-day clock on
        # every retry and the document would never reach day 7.
        base="$(jq -c '{id, original_name, sha256, staged_at, first_failed_at}' \
                "${PROPOSALS_DIR}/${id}.json")"
    else
        base="$(jq -nc --arg i "$id" --arg n "$bname" --arg s "$sha" --arg t "$now" \
            '{id:$i, original_name:$n, sha256:$s, staged_at:$t}')"
    fi

    # A byte-identical copy of something already filed. To bin rather than deleted:
    # nothing in this pipeline destroys a document without a tap.
    if [[ -n "${CORPUS_BY_HASH[$sha]:-}" ]]; then
        keeper="${CORPUS_BY_HASH[$sha]#"${DOCS}/"}"
        if mv -n -- "$src" "${BIN_DIR}/${bname}" 2>/dev/null; then
            BINNED=$((BINNED+1)); log "  DUPE   ${name} == ${keeper} -> bin/"
            record "$id" "$(jq -c --argjson b "$base" --arg k "$keeper" \
                '$b + {state:"binned", blocked:"DUPLICATE", duplicate_of:$k}' <<<'{}')"
        else
            log "  !! could not bin duplicate ${name}"
        fi
        continue
    fi

    # Unopenable: staged under its ORIGINAL name, never transmitted, no proposal.
    if ! reason="$(openable "$src")"; then
        if staged="$(stage_file "$src" "$bname")"; then
            BLOCKED=$((BLOCKED+1)); log "  BLOCK  ${name} (${reason}) — not transmitted"
            record "$id" "$(jq -c --argjson b "$base" --arg r "$reason" --arg p "${staged#"${DOCS}/"}" \
                '$b + {state:"staged", blocked:$r, staged_path:$p}' <<<'{}')"
        else
            STUCK=$((STUCK+1)); log "  !! could not stage ${name}"
        fi
        continue
    fi

    if ! pngs="$(rasterise "$src" "${WORK_DIR}/${sha:0:12}")"; then
        if staged="$(stage_file "$src" "$bname")"; then
            BLOCKED=$((BLOCKED+1)); log "  BLOCK  ${name} (RASTERISE_FAILED) — not transmitted"
            record "$id" "$(jq -c --argjson b "$base" --arg p "${staged#"${DOCS}/"}" \
                '$b + {state:"staged", blocked:"RASTERISE_FAILED", staged_path:$p}' <<<'{}')"
        fi
        continue
    fi

    log "  CLASSIFY ${name}"
    # The four verdicts are read separately here. Until now this was a bare
    # `if ! prop=...`, which collapsed all three failures into CLASSIFY_FAILED — so a
    # timeout was reported as terminal, the document was marked blocked, and nothing
    # ever retried it. afterimage could already tell them apart; this could not.
    ask_rc=0
    prop="$(ask "$pngs" "$(classify_prompt)" "$(build_schema)")" || ask_rc=$?
    if (( ask_rc == 2 || ask_rc == 3 )); then
        # PARKED, not blocked. `blocked` means a human has to look; this needs no
        # human at all, only an API that answers. It is staged under its ORIGINAL
        # name — there is no proposal to name it after — and carries no flags and no
        # blocked code, so nothing offers a button for a decision that does not exist.
        #
        # first_failed_at is written ONCE and never rewritten. pigeonhole ages a
        # record from its file mtime, which every retry touches, so without a stamp of
        # its own the seven-day clock would restart on every attempt and the item
        # would never reach day 7 — the same defect that got `skip` deleted.
        if staged="$(stage_file "$src" "$bname")"; then
            PAUSED=$((PAUSED+1)); log "  PAUSE  ${name} — $(ai_reason "$ask_rc")"
            record "$id" "$(jq -c --argjson b "$base" --arg p "${staged#"${DOCS}/"}" \
                --arg r "$(ai_reason "$ask_rc")" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '$b + {state:"staged", paused:$r, staged_path:$p,
                       first_failed_at: ($b.first_failed_at // $t)}' <<<'{}')"
        else
            STUCK=$((STUCK+1))
            log "  !! could not stage ${name} — LEFT AT ROOT, next fire will retry"
        fi
        continue
    elif (( ask_rc != 0 )); then
        # Terminal and per-item: a refusal, a truncated reply, a malformed request.
        # Retrying THIS document cannot help, so it is blocked for a human.
        if staged="$(stage_file "$src" "$bname")"; then
            BLOCKED=$((BLOCKED+1)); log "  BLOCK  ${name} (CLASSIFY_FAILED)"
            record "$id" "$(jq -c --argjson b "$base" --arg p "${staged#"${DOCS}/"}" \
                '$b + {state:"staged", blocked:"CLASSIFY_FAILED", staged_path:$p}' <<<'{}')"
        fi
        continue
    fi

    # --- assemble and validate the destination -----------------------------
    # ONE call per document — the adversarial verify pass retired with the shared
    # AI config (2026-08-01). It existed to protect unsupervised filing; every
    # proposal now waits for a human tap, and that tap is the verifier. The
    # mechanical checks below are not part of that trade and stay.
    # Everything below is what the closed vocabulary used to guarantee for free.
    folder="$(jq -r .folder <<<"$prop")"; dtype="$(jq -r .doc_type <<<"$prop")"
    qual="$(jq -r .qualifier <<<"$prop")"; owner="$(jq -r .owner <<<"$prop")"
    ddate="$(jq -r .date <<<"$prop")"
    blocked=""; flags=()

    # owner is in this loop even though the schema declares it an enum. The schema is
    # the API's promise, not this box's check: ai_extract parses the reply as JSON and
    # never validates it against the schema it asked for, so `owner` is exactly as
    # trusted as the three free-text fields — and it is spliced into the filename the
    # same way. A field that reaches a path gets checked here, whatever its type says.
    for seg in "$folder" "$dtype" "$qual" "$owner"; do
        valid_segment "$seg" || { blocked="BAD_SEGMENT"; break; }
    done

    fname="${ddate}_${dtype}"
    [[ "$qual"  != "none" ]] && fname="${fname}_${qual}"
    [[ "$owner" != "self" ]] && fname="${fname}_${owner}"
    fname="${fname}.${bname##*.}"
    dest="${DOCS}/${folder}/${fname}"

    [[ -z "$blocked" ]] && ! under_docs "$dest"        && blocked="ESCAPES_DOCS"
    [[ -z "$blocked" ]] && [[ -e "$dest" ]]            && blocked="DESTINATION_EXISTS"
    [[ -z "$blocked" ]] && ! valid_date "$ddate"       && blocked="IMPOSSIBLE_DATE"

    # Flags do NOT block — they route the notification. A flagged document gets its
    # own message explaining why instead of riding in the batch, so "approve all"
    # only ever covers proposals nothing was noticed about.
    [[ "$(jq -r .folder_is_new  <<<"$prop")" == "true" ]] && flags+=("NEW_FOLDER")
    [[ "$(jq -r .needs_human    <<<"$prop")" == "true" ]] && flags+=("$(jq -r .reason_code <<<"$prop")")
    [[ "$(jq -r .date_source    <<<"$prop")" != "printed_on_document" ]] && flags+=("DATE_NOT_PRINTED")
    is_lookalike "$dtype" "$folder" && flags+=("LOOKALIKE_FAMILY")

    # Stage under the proposed name when we have one, so what you see in staging/ is
    # exactly what accepting will call it — and accepting becomes a plain move.
    want="$bname"; [[ -z "$blocked" || "$blocked" == "DESTINATION_EXISTS" ]] && want="$fname"
    if ! staged="$(stage_file "$src" "$want")"; then
        # Fall back to the ORIGINAL name before giving up. A proposed name this
        # refuses is a problem with the proposal, not with the filesystem, and the
        # expensive half of that bug was never the bad name — it was the document
        # left at the root afterwards, re-firing the path unit at a model call per
        # spin. Staging it under the name it arrived with keeps the drain invariant
        # and hands the owner a document with no Accept button, which is the right
        # outcome for a proposal that could not even be written down.
        blocked="BAD_SEGMENT"
        if ! staged="$(stage_file "$src" "$bname")"; then
            STUCK=$((STUCK+1))
            log "  !! could not stage ${name} — LEFT AT ROOT, next fire will retry"
            continue
        fi
        log "  !! refused the proposed name for ${name}; staged as ${bname}"
    fi

    record "$id" "$(jq -c --argjson b "$base" --argjson p "$prop" \
        --arg sp "${staged#"${DOCS}/"}" --arg dp "${folder}/${fname}" \
        --arg bl "$blocked" --argjson fl "$(printf '%s\n' "${flags[@]:-}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
        '$b + {state:"staged", proposal:$p, staged_path:$sp,
               dest_path:$dp, blocked:(if $bl=="" then null else $bl end), flags:$fl}' <<<'{}')"

    if [[ -n "$blocked" ]]; then
        BLOCKED=$((BLOCKED+1)); log "  BLOCK  ${name} (${blocked}) -> staging/${staged##*/}"
    else
        STAGED=$((STAGED+1)); log "  STAGE  ${name} -> ${folder}/${fname}${flags[*]:+  [${flags[*]}]}"
    fi
done

log "staged ${STAGED}, blocked ${BLOCKED}, binned ${BINNED}, paused ${PAUSED}"

# Assert the invariant rather than trusting it. Files deliberately deferred by the
# cap are EXPECTED to remain — the .path unit re-firing on them is how the next
# batch gets taken, and that loop terminates because each run removes MAX_PER_RUN.
# Anything left OVER that number means a branch above returned without moving its
# file, which is the version that spins forever at an API call per spin.
left="$(list_candidates | wc -l)"
(( RETRY )) && left=0     # a retry works in staging/ and never touches the root
(( left <= TRUNCATED )) \
    || log "  !! $(( left - TRUNCATED )) file(s) STILL AT ROOT beyond the cap — path unit will spin"
(( TRUNCATED > 0 )) && log "  ${TRUNCATED} deferred; the path unit will re-fire for them"

# --- notify ----------------------------------------------------------------
# THE BATCH ACCUMULATES, THE INDIVIDUALS DO NOT. Ignoring a proposal leaves it in
# staging, so a clean one you ignored must reappear alongside the next arrival — that is
# the whole point of the batch and it is built from everything currently staged and
# clean, not from this run. Individual notifications go out once, for documents
# triaged in THIS run only: they each need their own decision, and re-sending three
# unresolved ones every time a fourth document arrives is how a useful notification
# becomes one you swipe away without reading. The batch's tail line names how many
# are sitting there, so nothing is invisible.

# The X-Pigeonhole header is required by the container on every route. It is not
# authentication — it forces a CORS preflight so a stray browser tab cannot fire
# these callbacks.
#
# NOTHING USES clear=true, and that is deliberate. clear=true dismisses on the TAP,
# before apply has done anything; a refused move would then leave the notification
# gone and the document unmoved. pigeonhole.apply.sh withdraws the notification after
# the move SUCCEEDS instead, so a message disappearing means the thing happened, and
# a message still sitting there means it did not.
#
# There were three buttons here until 2026-08-09. Skip went because ignoring the
# notification already did the same thing, and Accept/Discard stopped being an undo
# pair because keeping a notification alive after a tap meant every filed document
# left one behind forever. Two buttons, one outcome each.

# --- paused: one message per topic, whatever the count -----------------------
# Built from everything currently paused, not just this run — the same rule the batch
# follows. Twelve documents stuck behind one outage is one fact, and a ping per
# document would be twelve notifications with identical text and nothing to tap.
#
# FIRST, and deliberately above the base-URL gate below: this message carries no
# buttons, so it needs no base URL, and it is the one message that must still go out
# on the run where notifications are otherwise impossible. Unconditional, so the run
# that ends an outage is the run that clears the summary — see sync_paused_summary.
sync_paused_summary

# buttons() moved to pigeonhole.lib.sh — the sweep sends the same buttons on
# its re-notify and final-note messages, and two copies of an Actions string is how
# one of them drifts. BASE is what it reads.
# shellcheck disable=SC2034  # consumed by buttons() in pigeonhole.lib.sh
if ! BASE="$(pigeonhole_base_url)"; then
    # EXIT 1, matching the sweep. The classification work is already done and every
    # document is safely staged, so this is not a lost run — but it is a run whose
    # proposals nobody was told about, and exiting 0 would write a completion stamp
    # and report a healthy job while documents piled up in staging unannounced. A
    # non-zero exit costs nothing here and fires OnFailure=.
    log "  !! no base URL — proposals are staged but no notification was sent"
    log "     (check TAILNET_DOMAIN, TAILNET_DNS_NAME and"
    log "      PIGEONHOLE_REVERSE_PROXY_PORT in .env)"
    exit 1
fi

# Everything still staged, partitioned. jq per file rather than one slurp: the
# directory is small and a malformed record should cost one document, not the run.
# staged_class() is the predicate — shared with the sweep's re-batch, which used to
# carry its own copy and drifted.
clean=(); flagged=(); blocked_ids=()
for f in "${PROPOSALS_DIR}"/*.json; do
    [[ -f "$f" ]] || continue
    rid="$(basename "$f" .json)"
    # `paused` and the empty class both fall through: a parked record has no proposal
    # to accept, so offering it an Accept button would offer a decision nothing made.
    case "$(staged_class "$f")" in
        blocked) blocked_ids+=("$rid") ;;
        flagged) flagged+=("$rid") ;;
        clean)   clean+=("$rid") ;;
    esac
done

if (( ${#clean[@]} )); then
    # Retire the previous batch records first — one helper, shared with the sweep,
    # which mints its batches the same way. See retire_batches in pigeonhole.lib.sh.
    retire_batches
    bid="$(new_uuid)"
    cfiles=()
    for rid in "${clean[@]}"; do cfiles+=("${PROPOSALS_DIR}/${rid}.json"); done
    # No count of flagged/blocked here — each of those already has its own
    # notification, so a tail line was the same fact twice. The truncation count
    # is different: deferred documents have NO other notification yet, and
    # silently processing 20 of 200 reads as "that's everything" while the other
    # 180 look lost until someone opens the folder. It is one of the three things
    # italics mean, which is why it goes through body_aside rather than a literal.
    body="$(body_join "$(batch_list "${cfiles[@]}")" \
        "$( (( TRUNCATED > 0 )) && body_aside "${TRUNCATED} more still queued" )")"
    jq -nc --arg i "$bid" --argjson m "$(printf '%s\n' "${clean[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$i, kind:"batch", state:"staged", members:$m, staged_at:$t}' > "${PROPOSALS_DIR}/${bid}.json"
    # Withdraw the batch message this one supersedes — the on-disk records were
    # just marked `superseded` above, and this is the same step on the phone.
    # Retract-then-publish rather than an in-place update: an update may be applied
    # silently, and a batch that grew a document has to alert.
    # A batch that GREW has to alert, so this is a fresh proposal under the stable
    # batch id rather than a nudge: notify_nudge would retract-and-republish, which is
    # the same wire traffic, but the call site should say which of the two it means.
    retract "$BATCH_NTFY_ID"
    notify_proposal "$(title_count Staged "${#clean[@]}" Document)" \
        "$body" "$(buttons "$bid" 1)" "$BATCH_NTFY_ID"
    log "  notified batch of ${#clean[@]}"
fi

# Individuals, new-this-run only.
for rid in "${NEW_IDS[@]:-}"; do
    [[ -n "$rid" ]] || continue
    f="${PROPOSALS_DIR}/${rid}.json"
    [[ -f "$f" ]] || continue
    [[ "$(jq -r '.state' "$f")" == "staged" ]] || continue
    bl="$(jq -r '.blocked // "null"' "$f")"
    fl="$(jq -r '.flags[]?' "$f" | flags_sentence)"
    # Tagged with the record id: the sweep's nudge and its binned note both replace
    # this message rather than stacking beside it.
    if [[ "$bl" != "null" ]]; then
        # CLASSIFY_FAILED leaves the Blocked family. It is the one code here that is
        # not about the document at all — it is rc 1 out of ai.lib.sh, the same fact
        # afterimage reports, and the model class must read identically on both
        # topics. What stays under `Blocked` is the eleven codes that genuinely
        # describe the file: an unreadable PDF, an encrypted archive, a path that
        # escapes the corpus, an impossible date.
        if [[ "$bl" == CLASSIFY_FAILED ]]; then
            btitle="$(title_count "Model Failed" 1 Document)"
        else
            btitle="$(title_count Blocked 1 Document)"
        fi
        notify_proposal "$btitle" \
            "$(body_join \
                "$(body_list "$(basename "$(jq -r .staged_path "$f")")")" \
                "$(reason_text "$bl")")" \
            "$(buttons "$rid" 0)" "$rid"
    elif [[ -n "$fl" ]]; then
        # `Flagged`, not `Review`: the title reports what happened to the document,
        # and the two buttons underneath already say what to do about it. This was
        # the only title in the repo giving an instruction.
        notify_proposal "$(title_count Flagged 1 Document)" \
            "$(body_join "$(batch_list "$f")" "$fl")" \
            "$(buttons "$rid" 1)" "$rid"
    fi
done

# --- files that never made it out of the root --------------------------------
# LAST, and non-zero. Everything above is about documents that reached staging/; this
# is about ones that did not, and it is the branch that used to be silent. A run where
# every file failed to stage exited 0: no OnFailure=, no notification, ExecStartPost=
# stamping the watchdog fresh, and the .path unit re-firing forever.
#
# One message however many are stuck, on a stable id, because the cause is almost
# always one thing — a full disk or a permission change — and twelve identical alarms
# is how a topic gets muted.
if (( STUCK > 0 )); then
    notify_fault "$(title_count Stuck "$STUCK" Document)" \
        "Could not move $( (( STUCK == 1 )) && printf 'a document' || printf '%s documents' "$STUCK" ) out of the documents root. The disk may be full, or permissions may have changed. The trigger will keep retrying until this is cleared." \
        "$STUCK_NTFY_ID"
    log "  !! ${STUCK} document(s) STUCK at root"
    exit 1
fi

exit 0
