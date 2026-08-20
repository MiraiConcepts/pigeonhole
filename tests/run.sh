#!/usr/bin/env bash
# Regression tests for the pigeonhole propose-and-approve pipeline.
#
# Everything here runs offline and free: the model half is driven against
# ai/tests/sink.py, which serves scripted payloads, so a full triage costs nothing
# and a 429 can be summoned on demand.
#
# TWO CLASSES OF CASE DOMINATE, and both are here because they are the failures that
# actually cost something:
#
#   Path safety. The closed vocabulary used to guarantee that a model-chosen value
#   could never become a path. With free text that guarantee lives in valid_segment()
#   and under_docs(), so those are tested against traversal, absolute paths, casing
#   and length rather than trusted.
#
#   The drain invariants. Both .path units re-fire while their glob matches, so a
#   branch that returns without moving a file (triage) or deleting a marker (apply)
#   spins systemd — and the triage spends an opus call per spin. Every failure branch
#   is asserted to drain.
#
#   bash pigeonhole/tests/run.sh
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "${SELF_DIR}/../scripts" && pwd)"
SINK="$(cd "${SELF_DIR}/../../ai/tests" && pwd)/sink.py"

PASS=0 FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "$3" "$2"; }
has()  { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "contains $3" "$2"; }
hasnt(){ [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "must not contain $3" "$2"; }

TMP="$(mktemp -d)"
SINK_PID=""
cleanup() { [[ -n "$SINK_PID" ]] && kill "$SINK_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Source the library against a scratch tree so nothing here can touch the real corpus.
export DOCS="${TMP}/docs" STATE_DIR="${TMP}/state"
# ...and nothing here can reach the real PHONE either. This suite runs the actual
# triage and apply, not dry-runs of them, so before this existed a full run put
# every notification they raised — dozens of "Refused: 1 Document" pings — on the
# live `pigeonhole` topic. The files were always scratch; the notifications were not.
export NTFY_DISABLE=1
# shellcheck source=../scripts/pigeonhole.lib.sh
source "${SCRIPT_DIR}/pigeonhole.lib.sh"

fresh() { # rebuild the scratch tree
    rm -rf "${TMP}/docs" "${TMP}/state"
    mkdir -p "${TMP}/docs/09_receipts-and-purchases" "${TMP}/docs/staging" \
             "${TMP}/docs/bin" "${TMP}/state/proposals" "${TMP}/state/approvals"
}

# ------------------------------------------------------------------ path safety
echo "valid_segment"

for good in invoice anthropic 09_receipts-and-purchases a a1 x.y-z_2 acme-physiotherapy; do
    valid_segment "$good" && ok "accepts ${good}" || bad "accepts ${good}" ok reject
done

# Each of these is a way a free-text field becomes a path. The enum used to make
# them unrepresentable; now this function does.
for evil in '..' '../etc' 'a/b' '/etc/passwd' '.hidden' '' 'Anthropic' 'a..b' \
            'a b' 'café' '-leading-hyphen' '.'; do
    valid_segment "$evil" && bad "rejects '${evil}'" reject ok || ok "rejects '${evil}'"
done
long="$(printf 'a%.0s' {1..64})"
valid_segment "$long"  && ok "accepts 64 chars"        || bad "accepts 64 chars" ok reject
valid_segment "${long}a" && bad "rejects 65 chars" reject ok || ok "rejects 65 chars"

echo "under_docs"
fresh
is "a normal destination is inside"  "$(under_docs "${DOCS}/09_receipts-and-purchases/x.pdf" && echo in)" "in"
is "traversal is outside"            "$(under_docs "${DOCS}/../../../etc/passwd" && echo in)" ""
is "an absolute path is outside"     "$(under_docs "/etc/passwd" && echo in)" ""
is "DOCS itself is not 'under' DOCS" "$(under_docs "${DOCS}" && echo in)" ""

# under_docs is NOT the check that guards staging: staging/ is itself under DOCS, so
# a name that walks out of staging lands at the DOCS ROOT and passes under_docs
# cleanly — and the root is the one directory in this tree that must never receive a
# write, because the path unit fires on it and the document re-triages itself forever
# at a model call per fire.
echo "under_staging"
is "a staged name is inside"        "$(under_staging "${DOCS}/staging/x.pdf" && echo in)" "in"
is "the DOCS root is NOT"           "$(under_staging "${DOCS}/staging/../0801_x.pdf" && echo in)" ""
is "and under_docs would say it is" "$(under_docs "${DOCS}/staging/../0801_x.pdf" && echo in)" "in"
is "a filed folder is not staging"  "$(under_staging "${DOCS}/09_receipts-and-purchases/x.pdf" && echo in)" ""

# ------------------------------------------------------------------- valid_date
# The schema regex accepts 2023-02-29 (the 2026-07-18 battery produced exactly
# that) and year 0000, which filed silently until 2026-07-30.
echo "valid_date"
for d in 2021 2027 2024-02-29 2021-09-20 2021-01 2021-12; do
    valid_date "$d" && ok "accepts ${d}" || bad "accepts ${d}" ok reject
done
# The last four are the 2026-08-19 shipped bug and its neighbours. The arms were
# picked by LENGTH and then checked a SUBSTRING: the 7-char arm looked at characters
# 5-6 and nothing else, so "../0801" passed on its "08" and the date became a path;
# the 10-char arm was a bare `date -d`, which parses "01/02/2003" quite happily.
for d in 0000 9999 1899 2023-02-29 2021-13 2021-00 abc '' 202 20211 \
         '../0801' 'ab/de08' '01/02/2003' '2021/09/20' '20a1'; do
    valid_date "$d" && bad "rejects ${d}" reject ok || ok "rejects ${d}"
done

# ------------------------------------------------------- the Syncthing quiet gate
# The gate moved to syncthing/syncthing.lib.sh on 2026-08-19, shared with
# liquidroom, which watches a different directory inside the SAME Syncthing folder.
# The directory is the argument now, and that is the whole of what has to be pinned:
# a gate that consulted one fixed root would report liquidroom's mid-transfer as
# pigeonhole's, or — worse, because it fails silently toward acting — miss its own.
#
# SKIP_SYNCTHING_GATE short-circuits the API half; the .tmp half runs for real, so
# these cases exercise the branch that decides without a network at all.
echo "syncthing gate"
fresh
declare -F syncthing_quiet >/dev/null && ok "syncthing_quiet defined" \
    || bad "syncthing_quiet defined" "a function" "missing"
is "a settled directory is quiet" \
   "$(SKIP_SYNCTHING_GATE=1 syncthing_quiet "$DOCS" && echo quiet)" "quiet"
: > "${DOCS}/.syncthing.invoice.pdf.tmp"
is "a scratch file means mid-transfer" \
   "$(SKIP_SYNCTHING_GATE=1 syncthing_quiet "$DOCS" && echo quiet)" ""
is "and only for the directory it is in" \
   "$(SKIP_SYNCTHING_GATE=1 syncthing_quiet "$STAGING_DIR" && echo quiet)" "quiet"
rm -f "${DOCS}/.syncthing.invoice.pdf.tmp"
# The failure mode the parameter introduces: no argument would glob the FILESYSTEM
# ROOT for .syncthing.*.tmp, find none, and report quiet — the gate answering yes to
# a question nobody asked. It fails closed instead, which costs one .path fire.
is "no directory fails closed" "$(SKIP_SYNCTHING_GATE=1 syncthing_quiet 2>/dev/null && echo quiet)" ""
# Without the seam the gate must ASK Syncthing rather than assume — the test seam is
# the only reason the case above never touches the network, and a gate that defaulted
# to "quiet" would file truncated documents on every real drop.
gate="$(sed -n '/^syncthing_quiet() {/,/^}/p' /zpool/catallenya/syncthing/syncthing.lib.sh)"
has "production still asks the API"  "$gate" "st_folder_idle"
has "the seam is opt-in"             "$gate" 'SKIP_SYNCTHING_GATE:-'
# The triage passes its own root, not a default the library could have guessed.
has "the triage names the directory" "$(cat "${SCRIPT_DIR}/pigeonhole.triage.sh")" \
    'syncthing_quiet "$DOCS"'

# --------------------------------------------------------------------- triage
# Driven against the sink: one classify payload per document — the human tap is
# the verifier, so there is no second call to script.
echo "triage — staging and the drain invariant"

OKPROP='{"folder":"09_receipts-and-purchases","folder_is_new":false,"doc_type":"invoice","qualifier":"anthropic","owner":"self","date":"2026-07-08","date_source":"printed_on_document","needs_human":false,"reason_code":"OK"}'

triage() { # $1=sink codes; $2..=payloads -> runs the triage over the scratch tree
    local codes="$1"; shift
    : > "${TMP}/port"
    python3 "$SINK" "$codes" "$@" > "${TMP}/port" &
    SINK_PID=$!
    for _ in $(seq 20); do [[ -s "${TMP}/port" ]] && break; sleep 0.2; done
    DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" SKIP_SYNCTHING_GATE=1 \
      API_URL="http://127.0.0.1:$(cat "${TMP}/port")/" ANTHROPIC_API_KEY=sink \
      API_RETRY_BASE_S=1 PIGEONHOLE_REVERSE_PROXY_PORT=1 \
      bash "${SCRIPT_DIR}/pigeonhole.triage.sh" >"${TMP}/out" 2>&1
    kill "$SINK_PID" 2>/dev/null; wait "$SINK_PID" 2>/dev/null; SINK_PID=""
}
mkpdf() { convert -size 400x500 xc:white -pointsize 20 -annotate +20+40 "$2" "${DOCS}/$1" 2>/dev/null; }
rootn()  { find "${DOCS}" -maxdepth 1 -type f | wc -l; }
propfield() { jq -r "$1" "${TMP}"/state/proposals/*.json 2>/dev/null | grep -v '^null$' | head -1; }

fresh; mkpdf doc.pdf Invoice; triage 200 "$OKPROP"
is "happy path drains root"        "$(rootn)" "0"
is "staged under the proposed name" "$(ls "${DOCS}/staging")" "2026-07-08_invoice_anthropic.pdf"
is "destination recorded"          "$(propfield .dest_path)" "09_receipts-and-purchases/2026-07-08_invoice_anthropic.pdf"

# THE EXPENSIVE FAILURE. Each of these left a file at root in an earlier draft, and
# a file at root means the .path unit fires again and buys another opus call. Draining
# is therefore asserted for EVERY failure shape, whatever its verdict.
# `|` separates the sink script from the label because a sink script may itself
# contain a colon: "403:billing_error" is one argument, not two.
for case in "401|fatal API" "503,503,503|exhausted API" "403:billing_error|out of credits" "402|no balance"; do
    codes="${case%%|*}"; label="${case##*|}"
    fresh; mkpdf doc.pdf Invoice; triage "$codes" "$OKPROP"
    is "${label} still drains root" "$(rootn)" "0"
done

# A TERMINAL failure is blocked: retrying this document cannot help, so a human is
# the only way forward and the record says so. (propfield strips null lines, so a
# field that is absent reads as the empty string.)
fresh; mkpdf doc.pdf Invoice; triage 401 "$OKPROP"
is "fatal API is recorded blocked" "$(propfield .blocked)" "CLASSIFY_FAILED"
is "and is not paused"             "$(propfield .paused)"  ""

# A TRANSIENT or PAUSED failure is neither. Until 2026-08-10 these were recorded
# blocked as well, which was wrong twice over: it told the owner a document needed
# their attention when it needed none, and nothing ever retried it. `blocked` means a
# human must act; these need only an API that answers.
for case in "503,503,503|The API is unreachable" "403:billing_error|Out of credits" "402|Out of credits"; do
    codes="${case%%|*}"; want="${case##*|}"
    fresh; mkpdf doc.pdf Invoice; triage "$codes" "$OKPROP"
    is "${want} (${codes}) is paused, not blocked" "$(propfield .blocked)" ""
    is "  and names why"               "$(propfield .paused)" "$want"
    is "  and stamps the clock"        "$([[ "$(propfield .first_failed_at)" == 20*Z ]] && echo yes)" "yes"
    is "  and keeps its original name" "$(ls "${DOCS}/staging")" "doc.pdf"
done

fresh; mkpdf doc.pdf Invoice
triage 200 "$(jq -c '.folder="../../../etc"' <<<"$OKPROP")"
is "traversal drains root"     "$(rootn)" "0"
is "traversal is blocked"      "$(propfield .blocked)" "BAD_SEGMENT"

fresh; mkpdf doc.pdf Invoice
triage 200 "$(jq -c '.date="0000"' <<<"$OKPROP")"
is "year 0000 is blocked"      "$(propfield .blocked)" "IMPOSSIBLE_DATE"

# THE 2026-08-19 REPRODUCTION, end to end. `date` is spliced into the staged filename
# like any other component, and the 7-char arm of valid_date checked characters 5-6
# only — so "../0801" was a valid date, `stage_file` moved the document to
# staging/../0801_invoice_anthropic.pdf, and that resolves to the DOCS ROOT. The root
# is what pigeonhole.triage.path watches: the document re-triaged itself on every
# fire, at one opus call per spin, until someone noticed by hand.
fresh; mkpdf doc.pdf Invoice
triage 200 "$(jq -c '.date="../0801"' <<<"$OKPROP")"
is "a date that is a path is blocked"  "$(propfield .blocked)" "IMPOSSIBLE_DATE"
is "and NOTHING lands at the root"     "$(rootn)" "0"
is "and it keeps its original name"    "$(ls "${DOCS}/staging")" "doc.pdf"
is "and the root really is empty"      "$(find "${DOCS}" -maxdepth 1 -name '*0801*' | wc -l)" "0"

# owner is declared an enum in the schema, but ai_extract never validates a reply
# against the schema it asked for — so owner is exactly as trusted as the three
# free-text fields, and it is spliced into the same filename.
fresh; mkpdf doc.pdf Invoice
triage 200 "$(jq -c '.owner="../../etc"' <<<"$OKPROP")"
is "an owner that is a path is blocked" "$(propfield .blocked)" "BAD_SEGMENT"
is "and drains the root"                "$(rootn)" "0"
is "and keeps its original name"        "$(ls "${DOCS}/staging")" "doc.pdf"

fresh; printf 'not a pdf' > "${DOCS}/doc.pdf"; triage 200 "$OKPROP"
is "unopenable drains root"    "$(rootn)" "0"
is "unopenable never transmitted" "$(propfield .blocked)" "PDF_UNREADABLE_OR_ENCRYPTED"
is "unopenable keeps its name" "$(ls "${DOCS}/staging")" "doc.pdf"

fresh; mkpdf doc.pdf Invoice; cp "${DOCS}/doc.pdf" "${DOCS}/09_receipts-and-purchases/old.pdf"
triage 200 "$OKPROP"
is "duplicate drains root"     "$(rootn)" "0"
is "duplicate goes to bin"     "$(ls "${DOCS}/bin")" "doc.pdf"
is "duplicate is not deleted"  "$([ -f "${DOCS}/bin/doc.pdf" ] && echo kept)" "kept"

fresh; mkpdf doc.pdf Invoice; touch "${DOCS}/09_receipts-and-purchases/2026-07-08_invoice_anthropic.pdf"
triage 200 "$OKPROP"
is "collision is blocked"      "$(propfield .blocked)" "DESTINATION_EXISTS"

# A flagged proposal must still be staged and filable — flags route the
# notification, they do not block.
fresh; mkpdf doc.pdf Invoice
triage 200 "$(jq -c '.folder="12_new-thing"|.folder_is_new=true' <<<"$OKPROP")"
is "new folder is not blocked" "$(propfield '.blocked // "none"')" "none"
has "new folder is flagged"    "$(propfield '.flags|join(",")')" "NEW_FOLDER"

# ------------------------------------------------------------- render capability
# openable() claims eight image formats. That claim is only true while ImageMagick
# on this box is built against the right delegates, and an upgrade can silently drop
# one — at which point every iPhone photo starts coming back IMAGE_UNREADABLE and
# the pipeline looks broken rather than under-equipped.
#
# HEIC is listed r-- (read, no write) and that is sufficient: we decode what a phone
# produced and never encode one. It is also why there is no round-trip fixture here —
# this box cannot create a HEIC to test with, and an earlier attempt to fake one
# produced a PNG named .heic, which passed for the wrong reason.
echo "render capability"
fmts="$(identify -list format 2>/dev/null)"
for f in HEIC HEIF AVIF; do
    has "${f} is readable" "$(grep -oE "^ *${f} +[rw+-]+" <<<"$fmts" | tr -s ' ')" " ${f} r"
done
delegates="$(convert -list configure 2>/dev/null | grep -m1 '^DELEGATES')"
for d in jpeg png tiff webp heic; do
    has "${d} delegate compiled in" "$delegates" " ${d}"
done

# --------------------------------------------------------------------- apply
echo "apply — the state machine"

seed() { # one staged document with a known hash
    fresh
    echo "content" > "${DOCS}/staging/a.pdf"
    ID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
    jq -nc --arg i "$ID" --arg s "$(sha256_of "${DOCS}/staging/a.pdf")" \
      '{id:$i,original_name:"a.pdf",sha256:$s,state:"staged",staged_path:"staging/a.pdf",
        dest_path:"09_receipts-and-purchases/a.pdf",blocked:null,flags:[]}' \
      > "${STATE_DIR}/proposals/${ID}.json"
}
tap() { # $1=action -> run apply
    jq -nc --arg a "$1" '{action:$a,at:"t"}' > "${STATE_DIR}/approvals/${ID}.json"
    DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" bash "${SCRIPT_DIR}/pigeonhole.apply.sh" \
      >"${TMP}/aout" 2>&1
}
state() { jq -r .state "${STATE_DIR}/proposals/${ID}.json"; }
markers() { find "${STATE_DIR}/approvals" -name '*.json' | wc -l; }

seed
tap accept;  is "staged -> accept -> filed"   "$(state)" "filed"
is "the document is at the destination" "$([ -f "${DOCS}/09_receipts-and-purchases/a.pdf" ] && echo yes)" "yes"
# Still true, and still worth pinning: the STATE RULE survived the removal of undo
# (2026-08-09). What went is the notification that used to stay live long enough to
# send this second action — the table is reachable by a fresh proposal or a marker,
# no longer by a button on a spent notification.
tap discard; is "filed -> discard -> binned"  "$(state)" "binned"
tap accept;  is "binned -> accept -> filed"   "$(state)" "filed"
tap discard; is "and back to bin/"            "$(state)" "binned"
is "every tap drained its marker" "$(markers)" "0"
# There is no skip arm any more, and an action nothing emits must not quietly
# succeed: a stray marker naming one is a refusal, not a move.
tap skip
is  "a skip marker is refused"    "$(state)" "binned"
has "and says the action is gone" "$(cat "${TMP}/aout")" "unknown action"

# A document binned when bin/ already holds that name gets a timestamp prefix. An
# earlier where_is() rebuilt the bin path from the ORIGINAL name, so that document
# could never be found again and both un-discard paths refused.
seed; touch "${DOCS}/bin/a.pdf"
tap discard; is "collision-binned document is binned"  "$(state)" "binned"
is  "and got a distinct name"  "$(ls "${DOCS}/bin" | wc -l)" "2"
# Accept is the path that has to find it now that skip is gone — same where_is
# lookup, same regression guarded.
tap accept;  is "collision-binned is still reachable"   "$(state)" "filed"
is  "and lands at its destination" "$([ -f "${DOCS}/09_receipts-and-purchases/a.pdf" ] && echo yes)" "yes"

echo "apply — refusals"
seed; echo tampered > "${DOCS}/staging/a.pdf"; tap accept
is  "changed contents refuse"        "$(state)" "staged"
has "and say so"                     "$(cat "${TMP}/aout")" "changed after it was proposed"
is  "refusal still drains marker"    "$(markers)" "0"

seed; rm "${DOCS}/staging/a.pdf"; tap accept
is  "vanished document refuses"      "$(markers)" "0"
has "and says so"                    "$(cat "${TMP}/aout")" "no longer where it was"

seed; touch "${DOCS}/09_receipts-and-purchases/a.pdf"; tap accept
is  "occupied destination refuses"   "$(state)" "staged"
has "and says so"                    "$(cat "${TMP}/aout")" "already at"

seed
jq -c '.blocked="PDF_UNREADABLE_OR_ENCRYPTED"' "${STATE_DIR}/proposals/${ID}.json" > "${TMP}/b" \
  && mv "${TMP}/b" "${STATE_DIR}/proposals/${ID}.json"
tap accept
is  "a blocked record cannot be accepted" "$(state)" "staged"

seed; jq -nc '{}' > "${STATE_DIR}/approvals/${ID}.json"
DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" bash "${SCRIPT_DIR}/pigeonhole.apply.sh" >/dev/null 2>&1
is "an unreadable marker is dropped, not retried" "$(markers)" "0"

echo "apply — delete"
# Delete is the only arm that destroys anything, so both halves are tested: that it
# works from bin/, and that it is REFUSED everywhere else. The button is only ever
# offered on a binned note, but a marker is just a filename the container wrote —
# the restriction has to hold in the script that does the removing, not in the UI
# that asks for it.
seed; tap discard
tap delete
is "binned -> delete -> deleted"      "$(state)" "deleted"
is "and the file is gone"             "$([ -e "${DOCS}/bin/a.pdf" ] && echo present || echo gone)" "gone"
is "delete drained its marker"        "$(markers)" "0"

seed; tap delete
is  "a STAGED document cannot be deleted" "$(state)" "staged"
is  "and is untouched on disk"            "$([ -f "${DOCS}/staging/a.pdf" ] && echo yes)" "yes"
has "and the refusal says why"            "$(cat "${TMP}/aout")" "Only a document in bin/"

seed; tap accept; tap delete
is "a FILED document cannot be deleted"   "$(state)" "filed"
is "and is untouched on disk"             "$([ -f "${DOCS}/09_receipts-and-purchases/a.pdf" ] && echo yes)" "yes"

echo "apply — batches"
fresh
BATCH=99999999-0000-4000-8000-000000000000; MEMBERS=()
for n in 1 2 3; do
    m="1111111${n}-0000-4000-8000-000000000000"; MEMBERS+=("$m")
    echo "doc${n}" > "${DOCS}/staging/doc${n}.pdf"
    jq -nc --arg i "$m" --arg s "$(sha256_of "${DOCS}/staging/doc${n}.pdf")" --arg n "$n" \
      '{id:$i,original_name:("doc"+$n+".pdf"),sha256:$s,state:"staged",
        staged_path:("staging/doc"+$n+".pdf"),
        dest_path:("09_receipts-and-purchases/doc"+$n+".pdf"),blocked:null,flags:[]}' \
      > "${STATE_DIR}/proposals/${m}.json"
done
# doc2 was already filed by an earlier tap — an older batch notification stays
# tappable after a newer one supersedes it, so this must be tolerated silently
# rather than failing the batch.
mv "${DOCS}/staging/doc2.pdf" "${DOCS}/09_receipts-and-purchases/doc2.pdf"
jq -c '.state="filed"' "${STATE_DIR}/proposals/${MEMBERS[1]}.json" > "${TMP}/b" \
  && mv "${TMP}/b" "${STATE_DIR}/proposals/${MEMBERS[1]}.json"
jq -nc --arg i "$BATCH" --argjson m "$(printf '%s\n' "${MEMBERS[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
  '{id:$i,kind:"batch",state:"staged",members:$m}' > "${STATE_DIR}/proposals/${BATCH}.json"
jq -nc '{action:"accept",at:"t"}' > "${STATE_DIR}/approvals/${BATCH}.json"
DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" bash "${SCRIPT_DIR}/pigeonhole.apply.sh" >"${TMP}/bout" 2>&1
is "batch files every member"        "$(ls "${DOCS}/09_receipts-and-purchases" | wc -l)" "3"
is "batch empties staging"           "$(ls "${DOCS}/staging" | wc -l)" "0"
has "a stale member is not an error" "$(cat "${TMP}/bout")" "refused 0"
is "batch drains its marker"         "$(markers)" "0"

# ------------------------------------------------------------ parked / retry
# A document parked by an API failure is not a proposal: it has no dest_path, no
# buttons and nothing for the owner to decide. It is retried once a day through the
# triage's side door and binned at seven days, and the clock is first_failed_at,
# written once — NOT the record mtime, which every retry touches.
echo "parked documents"

retry() { # $1=sink codes; $2..=payloads -> runs the triage's --retry side door
    local codes="$1"; shift
    : > "${TMP}/port"
    python3 "$SINK" "$codes" "$@" > "${TMP}/port" &
    SINK_PID=$!
    for _ in $(seq 20); do [[ -s "${TMP}/port" ]] && break; sleep 0.2; done
    DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" SKIP_SYNCTHING_GATE=1 \
      API_URL="http://127.0.0.1:$(cat "${TMP}/port")/" ANTHROPIC_API_KEY=sink \
      API_RETRY_BASE_S=1 PIGEONHOLE_REVERSE_PROXY_PORT=1 \
      bash "${SCRIPT_DIR}/pigeonhole.triage.sh" --retry >"${TMP}/out" 2>&1
    kill "$SINK_PID" 2>/dev/null; wait "$SINK_PID" 2>/dev/null; SINK_PID=""
}

# Park one, then let the side door find it.
fresh; mkpdf doc.pdf Invoice; triage 402 "$OKPROP"
is "parked, not blocked"        "$(propfield .paused)" "Out of credits"
ff0="$(propfield .first_failed_at)"
is "and it is in staging"       "$(ls "${DOCS}/staging")" "doc.pdf"

# Retry while the API is still down: nothing resolves, and — the load-bearing part —
# the clock does NOT move. If first_failed_at were rewritten here the seven days
# would restart on every attempt and the document would never reach day 7.
retry 402 "$OKPROP"
is "still parked after a failed retry" "$(propfield .paused)" "Out of credits"
is "the clock did not move"            "$(propfield .first_failed_at)" "$ff0"
is "and the file did not move"         "$(ls "${DOCS}/staging")" "doc.pdf"

# Retry once the API is back: the document becomes an ordinary proposal, renamed in
# place, with no trace of having been parked.
retry 200 "$OKPROP"
is "a recovered document is no longer paused" "$(propfield .paused)" ""
is "and gets its proposed name"               "$(ls "${DOCS}/staging")" "2026-07-08_invoice_anthropic.pdf"
is "and a destination"                        "$(propfield .dest_path)" "09_receipts-and-purchases/2026-07-08_invoice_anthropic.pdf"
# A recovered document also mints a batch record, correctly — count only proposals.
is "and keeps its record id"                  "$(jq -s '[.[] | select(.kind != "batch")] | length' "${TMP}"/state/proposals/*.json)" "1"

# The side door must never touch the root — that is the whole reason it exists.
fresh; mkpdf doc.pdf Invoice; triage 402 "$OKPROP"
retry 402 "$OKPROP"
is "the root stays empty during a retry" "$(rootn)" "0"

# And with nothing parked it is a no-op, not an error: the timer fires daily whether
# or not anything is waiting.
fresh
retry 200 "$OKPROP"
has "nothing parked is a clean exit" "$(cat "${TMP}/out")" "nothing parked"

# ----------------------------------------------------------- record helpers
# Small shared functions, each of which exists because two call sites disagreed about
# something once. Tested directly: they are cheap to call and the disagreements they
# encode are expensive.
echo "record helpers"

seed
is "a clean proposal is clean"  "$(staged_class "${STATE_DIR}/proposals/${ID}.json")" "clean"
recput() { jq -c "$1" "${STATE_DIR}/proposals/${ID}.json" > "${TMP}/rc" && mv "${TMP}/rc" "${STATE_DIR}/proposals/${ID}.json"; }
recput '.flags=["NEW_FOLDER"]';              is "flags make it flagged" "$(staged_class "${STATE_DIR}/proposals/${ID}.json")" "flagged"
recput '.blocked="CLASSIFY_FAILED"';         is "blocked outranks flagged" "$(staged_class "${STATE_DIR}/proposals/${ID}.json")" "blocked"
# paused outranks both, and that ordering is the point: a parked document has no
# proposal at all, so it must never be offered an Accept button.
recput '.paused="Out of credits"';           is "paused outranks blocked" "$(staged_class "${STATE_DIR}/proposals/${ID}.json")" "paused"
recput '.state="filed"';                     is "a filed record is not staged" "$(staged_class "${STATE_DIR}/proposals/${ID}.json")" ""
jq -nc '{id:"b",kind:"batch",state:"staged",members:[]}' > "${STATE_DIR}/proposals/b.json"
is "a batch is not a document"  "$(staged_class "${STATE_DIR}/proposals/b.json")" ""

# The batch message rides a stable literal, so a TAP on a batch must retract that,
# not the batch record's uuid — which is an id nothing was ever published under. The
# batch notification used to survive the tap that emptied it, and its Accept button
# then answered "No such proposal." for every document it listed.
seed
is "a solo tap withdraws its own message"    "$(notif_id "${STATE_DIR}/proposals/${ID}.json")" "$ID"
jq -nc '{id:"b",kind:"batch",state:"staged",members:[]}' > "${STATE_DIR}/proposals/b.json"
is "a batch tap withdraws the batch literal" "$(notif_id "${STATE_DIR}/proposals/b.json")" "documents-batch"
# Deliberately NOT renamed with the pipeline: it is the address of a message that may
# be on the phone right now, and changing it orphans that message forever.
is "and the literal is not the pipeline's name" "$BATCH_NTFY_ID" "documents-batch"

fresh; echo x > "${DOCS}/staging/a.pdf"
is "bin_dest uses a free name as-is" "$(bin_dest "${DOCS}/staging/a.pdf")" "${DOCS}/bin/a.pdf"
touch "${DOCS}/bin/a.pdf"
is "and prefixes a taken one" \
   "$(basename "$(bin_dest "${DOCS}/staging/a.pdf")" | grep -cE '^[0-9]{8}T[0-9]{6}Z-a\.pdf$')" "1"

fresh
jq -nc '{id:"b1",kind:"batch",state:"staged",members:[]}'  > "${STATE_DIR}/proposals/b1.json"
jq -nc '{id:"b2",kind:"batch",state:"applied",members:[]}' > "${STATE_DIR}/proposals/b2.json"
jq -nc '{id:"d1",state:"staged",flags:[]}'                 > "${STATE_DIR}/proposals/d1.json"
retire_batches
is "a live batch is retired"        "$(jq -r .state "${STATE_DIR}/proposals/b1.json")" "superseded"
is "a spent batch is left alone"    "$(jq -r .state "${STATE_DIR}/proposals/b2.json")" "applied"
is "a document record is untouched" "$(jq -r .state "${STATE_DIR}/proposals/d1.json")" "staged"

# ------------------------------------------------------------ the paused summary
# One message per topic, whatever the count — and the run that ENDS an outage is the
# run that has to take it off the phone. Both triages used to keep the retract inside
# their "something is paused" branch, so a recovered pipeline left "Paused: 3
# Documents" sitting there forever, naming documents that had long since been filed.
#
# Proven by shadowing notify/retract in a subshell, the same way ntfy/tests/run.sh
# proves paused_sync: the shadows print the argv they receive, so the assertions read
# the exact choreography with no wire involved.
echo "the paused summary"
psync() {
    (
        retract() { printf 'RETRACT %s\n' "${1:-}"; }
        notify()  { printf 'NOTIFY title=[%s] id=[%s]\n%s\n' "${1:-}" "${6:-}" "${4:-}"; }
        sync_paused_summary
    )
}
mkpaused() { # $1=id $2=name $3=state $4=first_failed_at $5=reason
    jq -nc --arg i "$1" --arg n "$2" --arg s "$3" --arg t "$4" --arg r "$5" \
      '{id:$i,original_name:$n,state:$s,staged_path:("staging/"+$n),paused:$r,first_failed_at:$t}' \
      > "${STATE_DIR}/proposals/${1}.json"
}

fresh
mkpaused 11111111-0000-4000-8000-000000000000 a.pdf staged 2026-08-01T00:00:00Z "The API is unreachable"
mkpaused 22222222-0000-4000-8000-000000000000 b.pdf staged 2026-08-02T00:00:00Z "Out of credits"
# Binned, newest failure, and last in glob order — all three of the things the old
# `jq '.paused' *.json | tail -1` would have picked it for.
mkpaused 33333333-0000-4000-8000-000000000000 c.pdf binned 2026-08-03T00:00:00Z "Something else entirely"
t="$(psync)"
is    "retract fires first"                "$(head -n1 <<<"$t")" "RETRACT pigeonhole-paused"
has   "only STAGED records are counted"    "$t" "Model Paused: 2 Documents"
# The two staged records failed for DIFFERENT reasons — one unreachable, one out of
# credits — which is the case the bracket exists for. The triage rewrites a record's
# reason on every park, so a long outage really does leave both kinds in staging at
# once, and naming only the newest would hide the other. The binned record's reason
# must not reach it: `Something else entirely` matches neither pattern, so a leak
# would read as an empty bracket rather than as Mixed.
has   "and a mixed outage names both"      "$t" "Model Paused: 2 Documents [Mixed]"
has   "and they are listed"                "$t" '1\. a.pdf'
has   "the reason is the newest staged failure" "$t" "_Out of credits."
hasnt "never a binned record's"            "$t" "Something else entirely"
has   "the summary rides its stable id"    "$t" "id=[pigeonhole-paused]"

# THE FIX: the run that finds nothing paused still retracts, and publishes nothing.
fresh
t0="$(psync)"
is    "a resolved outage still retracts" "$t0" "RETRACT pigeonhole-paused"
hasnt "and republishes nothing"          "$t0" "NOTIFY"

# --------------------------------------------------------------------- sweep
# Nightly lifecycle: one nudge at 24h, bin at 7d, bin never emptied. Ages come
# from the record file's mtime, so backdating it is the whole test harness.
echo "sweep — staged lifecycle"
swp="${SCRIPT_DIR}/pigeonhole.sweep.sh"

sseed() { # $1 = how long ago the record was last touched
    seed
    touch -d "$1" "${STATE_DIR}/proposals/${ID}.json"
}
run_sweep() {
    DOCS="${TMP}/docs" STATE_DIR="${TMP}/state" PIGEONHOLE_REVERSE_PROXY_PORT=1 \
        bash "$swp" "$@" >"${TMP}/sout" 2>&1
}

sseed '1 hour ago'; run_sweep --dry-run
hasnt "a fresh proposal is left alone"  "$(cat "${TMP}/sout")" "would"

sseed '2 days ago'; run_sweep --dry-run
has "dry-run announces the nudge"       "$(cat "${TMP}/sout")" "would re-notify"
is  "dry-run stamps nothing"            "$(jq -r '.renotified_at // "none"' "${STATE_DIR}/proposals/${ID}.json")" "none"
run_sweep
is  "the nudge is stamped"              "$(jq -r '.renotified_at != null' "${STATE_DIR}/proposals/${ID}.json")" "true"
is  "the document stays staged"         "$(state)" "staged"
# A clean overdue proposal re-batches — same shape the triage first sent, with a
# fresh batch record so its Accept covers exactly the overdue members.
is  "re-batch record carries it"        "$(jq -r 'select(.kind=="batch" and .state=="staged") | .members[0]' "${STATE_DIR}"/proposals/*.json)" "$ID"
run_sweep
is  "the nudge happens once"            "$(grep -c 're-notified' "${TMP}/sout")" "0"

# THE GATE AND THE CONTENT ARE DIFFERENT QUESTIONS. One overdue proposal is what
# decides to nudge at all; what the replacement message must LIST is everything
# currently staged and clean. There is only one batch message, and this one REPLACES
# the cumulative one the triage sent — so rebuilding it from the overdue members
# alone dropped every clean proposal younger than 24h off the phone completely, with
# no other notification of their own to fall back on.
fresh
mkstaged() { # $1=id $2=name $3=record mtime
    echo "$2" > "${DOCS}/staging/$2"
    jq -nc --arg i "$1" --arg n "$2" --arg s "$(sha256_of "${DOCS}/staging/$2")" \
      '{id:$i,original_name:$n,sha256:$s,state:"staged",staged_path:("staging/"+$n),
        dest_path:("09_receipts-and-purchases/"+$n),blocked:null,flags:[]}' \
      > "${STATE_DIR}/proposals/${1}.json"
    touch -d "$3" "${STATE_DIR}/proposals/${1}.json"
}
OLD_ID=aaaaaaaa-1111-4000-8000-000000000000
NEW_ID=aaaaaaaa-2222-4000-8000-000000000000
mkstaged "$OLD_ID" old.pdf   '2 days ago'
mkstaged "$NEW_ID" fresh.pdf '1 hour ago'
run_sweep
rebatch="$(jq -r 'select(.kind=="batch" and .state=="staged") | .members[]' "${STATE_DIR}"/proposals/*.json)"
has "the re-batch carries the overdue member" "$rebatch" "$OLD_ID"
has "and the fresh one it replaces on the phone" "$rebatch" "$NEW_ID"
# The fresh proposal keeps its own 24h clock — being listed again is not a nudge.
is  "and the fresh one is not nudged early" \
    "$(jq -r '.renotified_at // "none"' "${STATE_DIR}/proposals/${NEW_ID}.json")" "none"

sseed '8 days ago'; run_sweep --dry-run
has "dry-run announces the bin"         "$(cat "${TMP}/sout")" "would bin"
is  "dry-run moves nothing"             "$([ -f "${DOCS}/staging/a.pdf" ] && echo still)" "still"
run_sweep
is  "a week-old proposal is binned"     "$(state)" "binned"
is  "the document is in bin/"           "$([ -f "${DOCS}/bin/a.pdf" ] && echo yes)" "yes"
# The final note's promise: Accept on a sweep-binned record still files it.
tap accept
is  "binned-by-sweep -> accept -> filed" "$(state)" "filed"

sseed '8 days ago'
echo old > "${DOCS}/bin/ancient.pdf"; touch -d '90 days ago' "${DOCS}/bin/ancient.pdf"
run_sweep
is  "bin/ is never auto-emptied"        "$([ -f "${DOCS}/bin/ancient.pdf" ] && echo kept)" "kept"

# The binned note was the last notification able to outlive its decision, so it got
# a clock of its own: a week in staging to decide, a week in bin/ to rescue. What it
# withdraws is the MESSAGE — the document is not touched, because the only thing in
# this pipeline that removes a document is a Delete tap.
sseed '8 days ago'; run_sweep                       # staged -> binned, note sent
touch -d '8 days ago' "${STATE_DIR}/proposals/${ID}.json"
run_sweep --dry-run
has "an aged binned note is withdrawn"  "$(cat "${TMP}/sout")" "would withdraw the binned note"
is  "dry-run stamps nothing"            "$(jq -r '.note_withdrawn // "none"' "${STATE_DIR}/proposals/${ID}.json")" "none"
run_sweep
is  "and is stamped once withdrawn"     "$(jq -r '.note_withdrawn // false' "${STATE_DIR}/proposals/${ID}.json")" "true"
is  "the document is STILL in bin/"     "$([ -f "${DOCS}/bin/a.pdf" ] && echo yes)" "yes"
is  "and the record is still binned"    "$(state)" "binned"
run_sweep
is  "the withdrawal happens once"       "$(grep -c 'withdrew the binned note' "${TMP}/sout")" "0"

# Same rule as apply: a document that changed underneath its proposal is left for
# a human, loudly — there is no path back through the pipeline for it.
sseed '8 days ago'; echo tampered > "${DOCS}/staging/a.pdf"
run_sweep
is  "changed contents are not binned"   "$(state)" "staged"
has "and are named in the log"          "$(cat "${TMP}/sout")" "contents changed"

# ------------------------------------------------------------------ the units
# Asserting the source lines exist is weak, but these are invariants whose breakage
# is silent and expensive, and each was got wrong at least once during the build.
echo "unit invariants"
UNIT_DIR="$(cd "${SELF_DIR}/../systemd" && pwd)"
tp="$(cat "${UNIT_DIR}/pigeonhole.triage.path")"
# `pigeonhole/*` also matches staging/, bin/ and the numbered folders, which always
# exist — so the condition never goes false and the unit fires forever.
is  "triage glob is extension-scoped, never bare *" \
    "$(grep -c 'PathExistsGlob=.*pigeonhole/\*$' <<<"$tp")" "0"
is  "triage wakes for readable AND unreadable types" "$(grep -c "^PathExistsGlob=" <<<"$tp")" "28"
has "apply glob matches only finished markers" \
    "$(cat "${UNIT_DIR}/pigeonhole.apply.path")" 'approvals/*.json'
# The start limit moved out of these units and into the adhoc class when the job
# factory landed, so asserting on the unit file would now pass only by accident and
# fail for the right reason. Assert the CHAIN instead: each unit claims the class,
# and the class provides the limit. Both halves matter — a unit that silently lost
# its Class= would still find StartLimitBurst in the policy file and look fine.
ADHOC_POLICY="$(cat "${UNIT_DIR}/../../systemd/policy/20-adhoc.conf" 2>/dev/null)"
# A sweep that cannot reach its base URL used to exit 0, which told systemd it had
# succeeded: the completion stamp was written and the watchdog reported it fresh
# while documents piled up unswept. "Nothing to sweep" is still a success; "cannot
# sweep" is not.
has "a sweep that cannot run fails loudly" \
    "$(sed -n '/no base URL/,/^fi/p' "${SCRIPT_DIR}/pigeonhole.sweep.sh")" "exit 1"
# The triage's identical case exited 0 until 2026-08-19, which recorded a healthy run
# whose proposals nobody was ever told about. The classification work IS done and the
# documents ARE staged — but a run that could not notify is not a run that succeeded.
has "and so does a triage that cannot notify" \
    "$(sed -n '/no base URL/,/^fi/p' "${SCRIPT_DIR}/pigeonhole.triage.sh")" "exit 1"
# ...and the paused summary goes out ABOVE that gate, because it carries no buttons
# and therefore needs no base URL — it is the one message that must survive the run
# where notification is otherwise impossible.
sps_at="$(grep -n '^sync_paused_summary$' "${SCRIPT_DIR}/pigeonhole.triage.sh" | head -1 | cut -d: -f1)"
gate_at="$(grep -n 'if ! BASE=' "${SCRIPT_DIR}/pigeonhole.triage.sh" | head -1 | cut -d: -f1)"
is  "the paused summary is unconditional, and above the gate" \
    "$([[ -n "$sps_at" && -n "$gate_at" ]] && (( sps_at < gate_at )) && echo above)" "above"
has "the retry's empty run clears it too" \
    "$(cat "${SCRIPT_DIR}/pigeonhole.triage.sh")" 'log "nothing parked"; sync_paused_summary'
has "and the sweep reconciles it after binning" \
    "$(cat "${SCRIPT_DIR}/pigeonhole.sweep.sh")" '(( DRY )) || sync_paused_summary'

has "triage claims the adhoc class"  "$(cat "${UNIT_DIR}/pigeonhole.triage.service")" "Class=adhoc"
has "apply claims the adhoc class"   "$(cat "${UNIT_DIR}/pigeonhole.apply.service")"  "Class=adhoc"
has "the adhoc class carries a start limit" "$ADHOC_POLICY" "StartLimitBurst"
has "…wide enough that a slow spin cannot evade it" "$ADHOC_POLICY" "StartLimitIntervalSec=1800"
# apply moves files but talks to no model; keeping the key out of it is deliberate.
is  "apply has no API key"           "$(grep -c '^EnvironmentFile=' "${UNIT_DIR}/pigeonhole.apply.service")" "0"
has "triage has the API key"         "$(cat "${UNIT_DIR}/pigeonhole.triage.service")" "EnvironmentFile=/etc/ai.env"
# The sweep is the same shape as apply: writes documents, holds no key — and it
# must run morning-side, because everything it does ends in a phone notification.
is  "sweep has no API key"           "$(grep -c '^EnvironmentFile=' "${UNIT_DIR}/pigeonhole.sweep.service")" "0"
has "sweep timer is morning-side SGT" "$(cat "${UNIT_DIR}/pigeonhole.sweep.timer")" "07:45:00 Asia/Singapore"

# A Caddyfile block whose port is not published fails SILENTLY and completely: the
# service is healthy, the container is fine, the notification renders, and the tap
# dies with "failed to connect" on the phone with nothing in any log on this box.
# That shipped on 2026-07-31 — the block and the container were added, the two lines
# in caddy's own compose entry were not. Both are needed: the env var, because the
# Caddyfile reads {$PIGEONHOLE_REVERSE_PROXY_PORT} from caddy's environment, and the
# publish, because otherwise nothing listens.
echo "a tap withdraws its own notification"
# buttons() lives in pigeonhole.lib.sh — one copy serves the triage and the sweep.
btn="$(sed -n '/^buttons() {/,/^}/p' "${SCRIPT_DIR}/pigeonhole.lib.sh")"
# NO button clears any more. clear=true dismisses on the TAP, before apply has done
# anything, so a refused move would leave you with a notification gone and a file
# unmoved. apply withdraws it after the move succeeds instead, which is what makes
# "the notification is gone" mean "it actually happened".
is "no button clears optimistically" "$(grep -c 'clear=true' <<<"$btn")" "0"
# Two buttons, one outcome each. Skip went on 2026-08-09: ignoring the notification
# already meant "leave it in staging", and each skip rewrote the record and so
# restarted the 7-day bin clock, which made the deadline unenforceable.
hasnt "and no Skip button survives"  "$btn" "Skip,"
hasnt "nor a skip route"             "$btn" "/skip"
ap="$(cat "${SCRIPT_DIR}/pigeonhole.apply.sh")"
hasnt "nor a skip arm in apply"      "$ap"  "      skip)"
# ...and it withdraws the message the tap actually CAME FROM, resolved before the
# move rewrites the record: a batch's message rides BATCH_NTFY_ID, never the batch
# record's uuid.
has "apply withdraws, and only when nothing refused" "$ap" '(( REFUSED == before )) && retract "$nid"'
has "and it withdraws what the tap rode"             "$ap" 'nid="$(notif_id '
# Nothing in this repo shouts. The refusal notification was the last `high` left
# anywhere in it — and a refusal is something you tapped and can tap again, not an
# emergency. Everything-loud is how a topic gets muted, and a muted topic loses the
# loud messages first.
hasnt "no notification is sent at high priority" "$ap" 'high warning'
has   "the refusal goes out at default priority" "$ap" '"" warning "$body"'

# The binned note is the one notification meant to outlive your attention, so it
# gets the two terminal choices and no Skip — sending it back to staging would
# restart a clock it already ran out.
bb="$(sed -n '/^bin_buttons() {/,/^}/p' "${SCRIPT_DIR}/pigeonhole.lib.sh")"
has   "the binned note offers Accept" "$bb" "Accept,"
has   "and Delete"                    "$bb" "Delete,"
hasnt "and no Skip"                   "$bb" "Skip,"
hasnt "and no Discard"                "$bb" "Discard,"
has   "the sweep uses it"             "$(cat "${SCRIPT_DIR}/pigeonhole.sweep.sh")" 'bin_buttons "$id"'

echo "a superseded notification is withdrawn"
# ntfy has no message TTL and no scheduled delete: a notification only disappears
# if something sends a DELETE addressed to its sequence id. Hence the X-Sequence-ID on
# every message a later one replaces.
is "a uuid survives intact"   "$(ntfy_id_safe '3f2a-9c1e_ok.v2')"  '3f2a-9c1e_ok.v2'
is "a slash cannot escape"    "$(ntfy_id_safe 'a/../b')"           'a..b'
# The charset alone leaves ".." whole, and DELETE on <topic>/.. addresses the
# topic root rather than a message. Emptied here; retract() declines an empty id.
is "a bare traversal empties" "$(ntfy_id_safe '../..')"            ''

# notify/retract now live in the shared transport, so these read it there. The
# assertions are unchanged and still earn their place: they are what stops someone
# "simplifying" X-Sequence-ID to the X-ID ntfy accepts and silently ignores, or
# dropping the mute seam that keeps a full test run off the live topic — which this
# suite, running the real triage and apply, learned the expensive way.
NTFY_LIB="/zpool/catallenya/ntfy/ntfy.lib.sh"
nt="$(sed -n '/^notify() {/,/^}/p' "$NTFY_LIB")"
has "notify can carry an id"  "$nt" 'X-Sequence-ID:'
# X-ID is accepted with a 200 and silently ignored — the message stores no
# sequence_id and every retract then addresses nothing. Verified against 2.27.0.
hasnt "and not the header that looks right" "$nt" 'X-ID:'
has "and sanitises it"        "$nt" 'ntfy_id_safe "$6"'

# One live batch message, addressed by a stable literal rather than by whichever
# record id happened to carry it — the sweep has to withdraw the previous batch
# without looking up which one that was.
tri="$(cat "${SCRIPT_DIR}/pigeonhole.triage.sh")"
swp="$(cat "${SCRIPT_DIR}/pigeonhole.sweep.sh")"
has "triage tags the batch"   "$tri" 'buttons "$bid" 1)" "$BATCH_NTFY_ID"'
has "sweep tags the batch"    "$swp" 'buttons "$bid" 1)" "$BATCH_NTFY_ID"'
has "the binned note is tagged" "$swp" '"$(bin_buttons "$id" "$offer_accept")" "$id"'

# The delete route has to exist on the container or the button is dead on arrival —
# and the container must NOT be where the bin/-only rule lives.
apsrc="$(cat "${SELF_DIR}/../approve/src/server.ts")"
has   "the container accepts a delete tap" "$apsrc" '"delete"'
hasnt "but does not police it"             "$apsrc" "BIN_DIR"

# This suite runs the real triage and apply, so the mute is the only thing between
# a test run and the owner's phone. Assert it on both wire calls, and that the
# suite still sets it — removing either line makes every future run publish for
# real, and nothing else would notice.
rt="$(sed -n '/^retract() {/,/^}/p' "$NTFY_LIB")"
has "notify is muteable"      "$nt" 'ntfy_muted && return 0'
has "retract is muteable"     "$rt" 'ntfy_muted && return 0'
has "the suite sets the mute" "$(cat "${BASH_SOURCE[0]}")" 'export NTFY_DISABLE=1'
NTFY_DISABLE=1 notify "probe" "" x "body" "" "probe-id"; is "muted notify still exits 0" "$?" "0"
NTFY_DISABLE=1 retract "probe-id";                       is "muted retract still exits 0" "$?" "0"

echo "caddy reaches the approve container"
cd="$(cat "${SELF_DIR}/../../caddy/Caddyfile")"
cm="$(cat "${SELF_DIR}/../../docker-compose.yml")"
has "Caddyfile has a pigeonhole block" "$cd" 'PIGEONHOLE_REVERSE_PROXY_PORT}'
has "and proxies to the container"     "$cd" "reverse_proxy pigeonhole-approve:8080"
has "caddy gets the port in its env"   "$cm" "PIGEONHOLE_REVERSE_PROXY_PORT: \${PIGEONHOLE_REVERSE_PROXY_PORT}"
has "caddy publishes the port"         "$cm" "127.0.0.1:\${PIGEONHOLE_REVERSE_PROXY_PORT}:\${PIGEONHOLE_REVERSE_PROXY_PORT}"

# The container's authority is its mount list. Test the mount, not the code.
echo "container confinement"
compose="$(cat "${SELF_DIR}/../../docker-compose.yml")"
approve="$(awk '/^  pigeonhole-approve:/{f=1} f&&/^  [a-z]/&&!/pigeonhole-approve/{f=0} f' <<<"$compose")"
is  "approve mounts exactly one path" "$(grep -c '^      - \${ZPOOL_VOLUME}' <<<"$approve")" "1"
has "and it is the approvals dir"     "$approve" "intake-state/approvals:/approvals"
has "approve is read_only"            "$approve" "read_only: true"
has "approve drops all caps"          "$approve" "cap_drop"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
