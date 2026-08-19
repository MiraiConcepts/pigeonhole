#!/bin/bash
# pigeonhole.apply.sh — perform the move a button tap asked for.
#
# Fired by pigeonhole.apply.path whenever the approve container drops a marker in
# intake-state/approvals/. Drains every marker, then exits.
#
# HARD INVARIANT — every marker MUST be deleted before this script exits, on every
# branch. PathExistsGlob re-fires for as long as a file remains, so a marker left in
# place spins systemd. Unlike the triage this costs no API calls, but a unit
# restarting forever is still a unit nobody can read the logs of.
#
# WHY THE MOVE LIVES HERE AND NOT IN THE CONTAINER. The container is long-lived,
# reachable by anything on the tailnet, and gated by ntfy, which has no
# authentication. This is a oneshot with ProtectSystem=strict that runs for a second
# and is unreachable. So the container writes "proposal <uuid> was accepted" and
# this decides what that means — reading the destination from the record the TRIAGE
# wrote, never from anything the container could influence. A compromised container
# can replay an approval; it cannot invent one, redirect one, or name a path.
#
# THE STATE RULE. Each action means "put this document into the state that action
# names, from wherever it is now":
#
#            accept              discard          delete
#   staged   -> dest             -> bin/          refused
#   filed    no-op               -> bin/          refused
#   binned   -> dest             no-op            -> gone
#
# Two columns left this table on 2026-08-09, both because a tap now WITHDRAWS its
# own notification (see the drain loop) and neither survived that:
#
#   the undo. `filed → discard` walked a document back out, and fell out of the
#   state rule for free. It only worked because the notification stayed live after
#   a tap — which also meant every document ever filed left one behind forever.
#
#   `skip`. It meant "leave it in staging and ask me later", which is exactly what
#   IGNORING the notification already does, so its one distinct effect was to
#   dismiss a notification without deciding anything. It also rewrote the record,
#   restarting the 7-day bin clock, so a document could be snoozed indefinitely and
#   never bin. Its `filed → staging` and `binned → staging` arms went with it:
#   Accept already files a document straight out of bin/, which is the case they
#   actually served.
#
# The rule itself is unchanged and the remaining rows are still reachable by a
# fresh proposal. delete is restricted to binned deliberately — it is the one
# destructive arm, and a mis-tap on a document you are still working with must not
# be able to reach it.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/pigeonhole/scripts/pigeonhole.lib.sh
source "${SELF_DIR}/pigeonhole.lib.sh"

command -v jq >/dev/null || die "jq not found"
mkdir -p "$APPROVALS_DIR" "$PROPOSALS_DIR" "$STAGING_DIR" "$BIN_DIR"

exec 9>"${STATE_DIR}/.apply.lock"
flock -n 9 || { log "another apply holds the lock; exiting"; exit 0; }

FILED=0; BINNED=0; DELETED=0; REFUSED=0
REFUSALS=""

# move_verified <src> <dst> <expected-sha> -> 0 on success
# The move half is apply.sh's, unchanged and for the same reasons: mv -n never
# clobbers, and the read-back is what turns "mv returned 0" into "the document is
# actually there and is actually the document". A rename that half-succeeds across
# a full disk is exactly the case a bare exit code misses.
move_verified() {
    local src="$1" dst="$2" want="$3"
    mkdir -p "$(dirname "$dst")" || return 1
    mv -n -- "$src" "$dst" 2>/dev/null || return 1
    [[ -f "$dst" && ! -e "$src" ]] || return 1
    [[ -z "$want" || "$(sha256_of "$dst")" == "$want" ]]
}

# where_is <record-json> -> absolute path of the document right now, or empty.
#
# Reads `at`, which every move below WRITES. An earlier version derived the path
# from the state instead — staging_path when staged, dest_path when filed, and for
# binned it reconstructed ${BIN_DIR}/$(basename staged_path). That last one is
# wrong: the discard arm adds a timestamp prefix when bin/ already holds that name,
# so a document binned through the collision path could never be found again and
# both un-discard paths refused with "no longer where it was". Recording where a
# file actually landed beats deriving where it probably went.
where_is() {
    local r="$1" at sp dp
    at="$(jq -r '.at // empty' <<<"$r")"
    [[ -n "$at" ]] && { printf '%s' "${DOCS}/${at}"; return; }
    # Fallback for the initial staged record, which has no `at` yet, and for any
    # record written before this field existed. Derives by state exactly as the old
    # version did — including the bin guess that motivated the change, since a wrong
    # guess only costs a refusal, whereas no guess at all costs one for every legacy
    # record.
    sp="$(jq -r '.staged_path // empty' <<<"$r")"
    dp="$(jq -r '.dest_path   // empty' <<<"$r")"
    case "$(jq -r '.state' <<<"$r")" in
        staged) [[ -n "$sp" ]] && printf '%s' "${DOCS}/${sp}" ;;
        filed)  [[ -n "$dp" ]] && printf '%s' "${DOCS}/${dp}" ;;
        binned) [[ -n "$sp" ]] && printf '%s' "${BIN_DIR}/$(basename "$sp")" ;;
    esac
}

refuse() { # $1=id $2=reason
    REFUSED=$((REFUSED+1)); REFUSALS+="$2
"
    log "  REFUSE ${1:0:8} — $2"
}

# apply_one <uuid> <action>
apply_one() {
    local id="$1" action="$2" rec f cur st sha dest
    f="${PROPOSALS_DIR}/${id}.json"
    [[ -f "$f" ]] || { refuse "$id" "No such proposal."; return; }
    rec="$(cat "$f")"

    # A batch is a list of member ids and nothing else. Members that have already
    # moved are skipped rather than failing the batch: an older notification stays
    # tappable after a newer one supersedes it, and re-verification is exactly the
    # mechanism that makes that harmless.
    if [[ "$(jq -r '.kind // ""' <<<"$rec")" == "batch" ]]; then
        local m
        while IFS= read -r m; do [[ -n "$m" ]] && apply_one "$m" "$action"; done \
            < <(jq -r '.members[]?' <<<"$rec")
        jq -c --arg a "$action" '. + {state:"applied", last_action:$a}' <<<"$rec" > "$f"
        return
    fi

    st="$(jq -r '.state' <<<"$rec")"
    sha="$(jq -r '.sha256 // empty' <<<"$rec")"
    cur="$(where_is "$rec")"

    # TAP-TIME RE-VERIFICATION. Hours pass between the proposal and the tap, and
    # master/documents is a Syncthing folder — the file may have been renamed,
    # replaced or removed from another device in between. Acting on a stale proposal
    # is how the wrong document gets filed under the right name.
    [[ -n "$cur" && -f "$cur" ]] || { refuse "$id" "$(jq -r .original_name <<<"$rec") — Document is no longer where it was."; return; }
    if [[ -n "$sha" && "$(sha256_of "$cur")" != "$sha" ]]; then
        refuse "$id" "$(jq -r .original_name <<<"$rec") — Document changed after it was proposed."; return
    fi

    case "$action" in
      accept)
        [[ "$st" == "filed" ]] && return 0                       # already there
        if [[ "$(jq -r '.blocked // "null"' <<<"$rec")" != "null" ]]; then
            refuse "$id" "$(jq -r .original_name <<<"$rec") — $(reason_text "$(jq -r .blocked <<<"$rec")")"; return
        fi
        dest="${DOCS}/$(jq -r '.dest_path // empty' <<<"$rec")"
        [[ "$dest" != "${DOCS}/" ]] || { refuse "$id" "No destination recorded."; return; }
        # Re-run the containment check at apply time. The triage already did it, but
        # this is the step that actually writes, and the record is a file on disk
        # that something else could have edited.
        under_docs "$dest" || { refuse "$id" "Destination escapes the documents tree."; return; }
        [[ -e "$dest" ]] && { refuse "$id" "$(jq -r .original_name <<<"$rec") — Something is already at ${dest#"${DOCS}/"}."; return; }
        if move_verified "$cur" "$dest" "$sha"; then
            FILED=$((FILED+1)); log "  FILED  ${dest#"${DOCS}/"}"
            jq -c --arg at "${dest#"${DOCS}/"}" '. + {state:"filed", at:$at}' <<<"$rec" > "$f"
        else
            refuse "$id" "$(jq -r .original_name <<<"$rec") — Move failed verification."
        fi ;;

      discard)
        [[ "$st" == "binned" ]] && return 0
        # bin_dest, shared with the sweep's two binning passes: all three agree on
        # what a name collision in bin/ becomes, and the record stores the answer.
        dest="$(bin_dest "$cur")"
        if move_verified "$cur" "$dest" "$sha"; then
            BINNED=$((BINNED+1)); log "  BINNED ${dest#"${DOCS}/"}"
            jq -c --arg at "${dest#"${DOCS}/"}" '. + {state:"binned", at:$at}' <<<"$rec" > "$f"
        else
            refuse "$id" "$(jq -r .original_name <<<"$rec") — Could not move to bin."
        fi ;;

      delete)
        # The only arm that destroys anything. Reachable solely from the note a
        # document gets after a week in bin/ — by then it has been decided against
        # twice, once by a week of silence and once by this tap.
        #
        # The bin/ restriction is the safety property, and it is checked HERE rather
        # than trusted from the button: a marker is just a filename the container
        # wrote, so "the UI only offers Delete on a binned note" is not a guarantee
        # this script may rely on. Anything not currently in bin/ is refused.
        [[ "$st" == "deleted" ]] && return 0
        [[ "$cur" == "${BIN_DIR}/"* ]] || {
            refuse "$id" "$(jq -r .original_name <<<"$rec") — Only a document in bin/ can be deleted."; return; }
        if rm -f -- "$cur" && [[ ! -e "$cur" ]]; then
            DELETED=$((DELETED+1)); log "  DELETED ${cur#"${DOCS}/"}"
            # `at` goes with it: where_is reads that field, and a path that no longer
            # exists would make every later tap refuse with the wrong reason.
            jq -c '. + {state:"deleted"} | del(.at)' <<<"$rec" > "$f"
        else
            refuse "$id" "$(jq -r .original_name <<<"$rec") — Could not delete."
        fi ;;

      *) refuse "$id" "unknown action: ${action}" ;;
    esac
}

# --- drain the markers -----------------------------------------------------

shopt -s nullglob
markers=("${APPROVALS_DIR}"/*.json)
(( ${#markers[@]} )) || { log "no markers"; exit 0; }
log "draining ${#markers[@]} marker(s)"

for mk in "${markers[@]}"; do
    id="$(basename "$mk" .json)"
    action="$(jq -r '.action // ""' "$mk" 2>/dev/null)"
    # Delete FIRST. Every branch below must leave the marker gone, and doing it here
    # rather than in each arm is the only version of that which cannot be forgotten
    # in a later edit. The action is already in hand; losing the file loses nothing.
    rm -f "$mk"
    [[ -n "$action" ]] || { log "  !! unreadable marker ${id:0:8} — dropped"; continue; }
    # WHICH MESSAGE this tap came from, resolved BEFORE the move rewrites the record.
    # A batch's message rides BATCH_NTFY_ID, never the batch record's uuid, so
    # retracting "$id" for one addressed an id nothing was ever published under: the
    # batch notification survived the tap that emptied it, and its Accept button then
    # answered "No such proposal." for every document it listed.
    nid="$(notif_id "${PROPOSALS_DIR}/${id}.json")"
    before=$REFUSED
    apply_one "$id" "$action"
    # Withdraw the notification this tap came from — but ONLY if the action actually
    # happened. A refused tap keeps its notification, because the document did not
    # move and those buttons are still the way to act on it. That conditional is
    # what lets a notification's disappearance mean "done" rather than "tapped".
    #
    # Comparing the REFUSED counter is deliberate: apply_one reports failure by
    # incrementing it, not by a return code, and a batch that refuses one member of
    # five must not withdraw the notification covering the other four.
    (( REFUSED == before )) && retract "$nid"
done

log "filed ${FILED}, binned ${BINNED}, deleted ${DELETED}, refused ${REFUSED}"

# Silent on success — the button clearing is the confirmation, and a ping per tap is
# how a useful topic becomes one you mute. A refusal is the opposite: you tapped,
# nothing happened, and without this you would never know why.
if (( REFUSED > 0 )); then
    # Refusal lines arrive as "name — Reason." (or a bare reason when there is no
    # name to blame). Rendered as a markdown ordered list matching batch_list:
    # a literal "1." (escaped so no renderer restyles it), the name, a hard
    # break (trailing two spaces), and the reason hanging beneath on NBSP
    # indentation. Names are md_escaped rather than code-spanned — the owner
    # dropped the spans 2026-08-01, and a filename is untrusted text.
    body=""
    n=0
    pad=$'    '
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        n=$((n+1))
        line="$(md_escape "$line")"
        if [[ "$line" == *" — "* ]]; then
            body+="${n}\. ${line%% — *}  
${pad}${line#* — }
"
        else
            body+="${n}\. ${line}
"
        fi
    done <<<"$REFUSALS"
    # Default priority, like every other notification in this repo. This was the last
    # `high` left anywhere in it, and it was the wrong place for one twice over: a
    # refusal is a thing you tapped and can tap again, not an emergency, and
    # everything-shouts is how a topic gets muted — after which the loud messages are
    # the first thing lost. Urgency belongs in what the message says.
    notify "Refused: ${REFUSED} Document$( (( REFUSED == 1 )) || printf s )" \
        "" warning "$body"
fi

left="$(find "$APPROVALS_DIR" -maxdepth 1 -name '*.json' | wc -l)"
(( left == 0 )) || log "  !! ${left} marker(s) remain — path unit will re-fire"
exit 0
