#!/bin/bash
# pigeonhole.sweep.sh — nightly lifecycle for staged proposals. Run at 07:45 SGT by
# pigeonhole.sweep.timer — morning-side, because everything it does ends in a phone
# notification, and fifteen minutes after capture's so the two bursts stay
# distinguishable.
#
# The triage only runs when a document arrives, so it cannot manage the life of a
# proposal that is sitting in staging unanswered. This does, mirroring
# afterimage.sweep.sh:
#
#   1. RE-NOTIFY once at RENOTIFY_AFTER_HOURS. "No tap" is ambiguous — ignored, or
#      never seen (phone off, ntfy's 12h cache expired). One nudge separates the
#      two. Clean proposals re-batch into one message, exactly as the triage first
#      sent them; flagged and blocked ones re-send individually, with the same
#      buttons (no Accept on a blocked one).
#   2. BIN at BIN_AFTER_DAYS: a proposal untouched for a week moves to bin/ with a
#      final note. The record is updated the way a Discard tap would update it, so
#      every button keeps working — Accept on the final note (or on the original,
#      still-live notification) files the document straight out of bin/.
#   3. NEVER empties bin/. Nothing in this pipeline destroys a document without a
#      tap, and the sweep taps nothing.
#
# Ages are measured from the record file's mtime — the time of the last state
# change, which apply rewrites on every tap — and the re-notify itself resets the
# clock, so a nudged proposal bins a week after the nudge rather than a week after
# it was staged. Nothing else moves a document back to staged any more: `skip` was
# the only action that did, and it is gone (2026-08-09), which is what turned the
# 7-day bin into a deadline rather than something a tap could postpone forever.
#
# Makes no API calls and holds no API key — pure filesystem + ntfy.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/zpool/catallenya/pigeonhole/scripts/pigeonhole.lib.sh
source "${SELF_DIR}/pigeonhole.lib.sh"

RENOTIFY_AFTER_HOURS=24
BIN_AFTER_DAYS=7
# How long the binned note stays on the phone before it withdraws itself. Mirrors
# the staging week deliberately: one week to decide, one week to rescue. After that
# the DOCUMENT is untouched — it lives in bin/ exactly as before, and bin/ is still
# never emptied by anything but a Delete tap — but the notification stops being a
# thing you scroll past. This is the last notification in either pipeline that can
# outlive its decision, so it is the last one that needed a clock.
BIN_NOTE_DAYS=7

DRY=0
usage() { printf 'usage: %s [--dry-run]\n' "${0##*/}" >&2; }
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: ${arg}" ;;
    esac
done
(( DRY )) && log "DRY RUN — nothing will be moved or notified"

command -v jq >/dev/null || die "jq not found"
mkdir -p "$PROPOSALS_DIR" "$STAGING_DIR" "$BIN_DIR"

# Own lock, so a slow sweep never blocks a triage or an apply — and flock rather
# than nothing, so two sweeps (timer + a manual run) cannot bin the same file.
exec 9>"${STATE_DIR}/.sweep.lock"
flock -n 9 || { log "another sweep holds the lock; exiting"; exit 0; }

# shellcheck disable=SC2034  # BASE is consumed by buttons() in pigeonhole.lib.sh
if ! BASE="$(documents_base_url)"; then
    # Without a base URL every button would be dead on arrival. Renotifying with
    # dead buttons is worse than staying quiet a day; binning still needs the
    # final note's buttons, so it waits too.
    #
    # EXIT 1, not 0. Exiting successfully told systemd the sweep had done its work,
    # so ExecStartPost wrote a completion stamp and the watchdog reported the job
    # fresh — while nothing was nudged, nothing was binned, and documents piled up
    # in staging indefinitely with no signal at all.
    #
    # "Nothing to sweep" is still a success and still exits 0 further down; this is
    # the different case of not being ABLE to sweep. A broken precondition must fail
    # loudly: OnFailure= then fires, and the missing stamp makes the watchdog say so
    # too.
    log "  !! no base URL — cannot renotify or bin, failing loudly rather than"
    log "     reporting a sweep that did not happen (check TAILNET_DOMAIN,"
    log "     TAILNET_DNS_NAME and PIGEONHOLE_REVERSE_PROXY_PORT in .env)"
    exit 1
fi

now=$(date +%s)
renotified=0; binned=0; batch_members=()

# stamp <record-file> [jq args...] <filter> — rewrite the record in place.
# Values go in via --arg, NEVER interpolated into the filter: staged_path can be an
# ORIGINAL filename off another device, and a quote in it would otherwise become
# jq syntax.
stamp() {
    local rf="$1"; shift
    local tmp="${rf}.tmp"
    jq -c "$@" "$rf" > "$tmp" && mv "$tmp" "$rf"
}

shopt -s nullglob
for f in "${PROPOSALS_DIR}"/*.json; do
    rec="$(cat "$f")"
    [[ "$(jq -r '.state // ""' <<<"$rec")" == "staged" ]] || continue
    [[ "$(jq -r '.kind  // ""' <<<"$rec")" == "batch"  ]] && continue
    # Paused records are handled below, on their own clock. Ageing them from the file
    # mtime like a proposal would be wrong twice: a retry rewrites the record, so the
    # nudge would fire on the wrong day, and there is nothing to nudge anyway — no
    # proposal, no buttons, and nothing the owner can do except top up.
    [[ "$(jq -r '.paused // "null"' <<<"$rec")" != "null" ]] && continue
    id="$(basename "$f" .json)"
    age_h=$(( (now - $(stat -c %Y "$f" 2>/dev/null || echo "$now")) / 3600 ))

    sp="$(jq -r '.at // .staged_path // empty' <<<"$rec")"
    cur="${DOCS}/${sp}"
    [[ -n "$sp" && -f "$cur" ]] || continue      # vanished from another device
    sha="$(jq -r '.sha256 // empty' <<<"$rec")"
    if [[ -n "$sha" && "$(sha256_of "$cur")" != "$sha" ]]; then
        # Same rule as apply: never act on a proposal whose document changed
        # underneath it. A changed staged file has no path back through the
        # pipeline, so this is worth a log line, not silence.
        log "  !! ${sp}: contents changed since proposed — leaving for a human"
        continue
    fi

    orig="$(jq -r '.original_name // "?"' <<<"$rec")"
    bl="$(jq -r '.blocked // "null"' <<<"$rec")"
    fl="$(jq -r '.flags[]?' <<<"$rec" | flags_sentence)"

    # --- a week untouched: move to bin/, with a final note ------------------
    if (( age_h >= BIN_AFTER_DAYS * 24 )); then
        dest="${BIN_DIR}/$(basename "$cur")"
        [[ -e "$dest" ]] && dest="${BIN_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$cur")"
        if (( DRY )); then
            log "would bin ${sp} (${age_h}h staged)"
            continue
        fi
        if mv -n -- "$cur" "$dest" 2>/dev/null && [[ -f "$dest" && ! -e "$cur" ]]; then
            stamp "$f" --arg at "${dest#"${DOCS}/"}" '. + {state:"binned", at:$at}'
            binned=$((binned + 1)); log "binned ${sp} (${age_h}h staged)"
            offer_accept=1; [[ "$bl" != "null" ]] && offer_accept=0
            binbody="1\. $(md_escape "$orig")

"
            [[ "$bl" != "null" ]] && binbody+="$(reason_text "$bl")

"
            if (( offer_accept )); then
                binbody+="_In bin/ after $(( age_h / 24 )) days with no decision. Accept still files it; Delete removes it for good._"
            else
                binbody+="_In bin/ after $(( age_h / 24 )) days with no decision. Delete removes it for good._"
            fi
            # Withdraw this document's own earlier message (its blocked/review
            # proposal, or its nudge) and let the binned note stand in its place.
            # Safe to do unconditionally: the note below carries the SAME buttons,
            # so the undo handle survives — and a clean document never had a solo
            # message at all, which makes this a free no-op for it.
            retract "$id"
            # bin_buttons, not buttons: this note is the document's last handle, so
            # it offers the two terminal choices and no Skip. It is also the ONE
            # notification that is meant to outlive your attention — everything else
            # here is withdrawn the moment it stops being actionable.
            notify "Binned: 1 Document" "" wastebasket "$binbody" "$(bin_buttons "$id" "$offer_accept")" "$id"
        else
            log "  !! could not bin ${sp}"
        fi
        continue
    fi

    # --- one nudge at 24h ---------------------------------------------------
    if (( age_h >= RENOTIFY_AFTER_HOURS )) && [[ "$(jq -r '.renotified_at // ""' <<<"$rec")" == "" ]]; then
        if (( DRY )); then
            log "would re-notify ${sp} (${age_h}h)"
            continue
        fi
        if [[ "$bl" != "null" ]]; then
            retract "$id"
            notify "Pending Blocked: 1 Document" "" warning \
                "1\. $(md_escape "$(basename "$sp")")

$(reason_text "$bl")" "$(buttons "$id" 0)" "$id"
        elif [[ -n "$fl" ]]; then
            retract "$id"
            notify "Pending Review: 1 Document" "" question \
                "$(batch_list "$f")

${fl}" "$(buttons "$id" 1)" "$id"
        else
            batch_members+=("$id")      # clean ones re-batch below, as one message
        fi
        stamp "$f" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '. + {renotified_at:$t}'
        renotified=$((renotified + 1))
        log "re-notified ${sp} (${age_h}h)"
    fi
done

# Clean proposals renotify as ONE batch, the shape the triage first sent them in —
# with a fresh batch record so its Accept covers exactly these members, and older
# batch snapshots retired the same way the triage retires them.
if (( ${#batch_members[@]} )); then
    for old in "${PROPOSALS_DIR}"/*.json; do
        [[ "$(jq -r '.kind // ""' "$old")" == "batch" ]] || continue
        [[ "$(jq -r '.state // ""' "$old")" == "staged" ]] || continue
        stamp "$old" '. + {state:"superseded"}'
    done
    bid="$(new_uuid)"
    bfiles=()
    for rid in "${batch_members[@]}"; do bfiles+=("${PROPOSALS_DIR}/${rid}.json"); done
    jq -nc --arg i "$bid" \
        --argjson m "$(printf '%s\n' "${batch_members[@]}" | jq -R -s -c 'split("\n")|map(select(length>0))')" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{id:$i, kind:"batch", state:"staged", members:$m, staged_at:$t}' \
        > "${PROPOSALS_DIR}/${bid}.json"
    retract "$BATCH_NTFY_ID"
    notify "Pending Staged: ${#batch_members[@]} Document$( (( ${#batch_members[@]} == 1 )) || printf s )" \
        "" clipboard "$(batch_list "${bfiles[@]}")" \
        "$(buttons "$bid" 1)" "$BATCH_NTFY_ID"
fi

# --- withdraw a binned note that has had its week ---------------------------
# The binned note is the only notification left that outlives its decision, and
# this is its clock. It withdraws the MESSAGE and nothing else: the document stays
# in bin/ untouched, and the only thing that ever removes a document is a Delete
# tap. Age is the record's mtime, which the bin move rewrote, so a document you
# tapped back out of bin/ is not counted here at all — its state stops being
# "binned" and this pass skips it.
#
# note_withdrawn guards it, so the DELETE is sent once rather than every night for
# the life of the record.
for f in "${PROPOSALS_DIR}"/*.json; do
    rec="$(cat "$f")"
    [[ "$(jq -r '.state // ""' <<<"$rec")" == "binned" ]] || continue
    [[ "$(jq -r '.note_withdrawn // false' <<<"$rec")" == "true" ]] && continue
    age_d=$(( (now - $(stat -c %Y "$f" 2>/dev/null || echo "$now")) / 86400 ))
    (( age_d >= BIN_NOTE_DAYS )) || continue
    id="$(basename "$f" .json)"
    if (( DRY )); then
        log "would withdraw the binned note for ${id:0:8} (${age_d}d in bin/)"
        continue
    fi
    retract "$id"
    stamp "$f" '. + {note_withdrawn:true}'
    log "withdrew the binned note for ${id:0:8} (${age_d}d in bin/) — document untouched"
done

# --- paused: bin at seven days, retry everything younger ---------------------
# Order matters. Binning runs FIRST so a document about to reach day 7 is not sent for
# one more model call it will never use, and the retry then covers exactly what is
# still worth retrying.
#
# The clock is first_failed_at, written once by the triage and never rewritten. The
# record's own mtime is useless here: every retry touches it, so ageing from it would
# restart the seven days on each attempt and nothing would ever reach day 7 — the
# defect that got `skip` deleted.
paused_binned=0
for f in "${PROPOSALS_DIR}"/*.json; do
    rec="$(cat "$f")"
    [[ "$(jq -r '.state  // ""' <<<"$rec")" == "staged" ]] || continue
    ff="$(jq -r '.first_failed_at // empty' <<<"$rec")"
    [[ -n "$ff" ]] || continue
    [[ "$(jq -r '.paused // "null"' <<<"$rec")" != "null" ]] || continue
    id="$(basename "$f" .json)"
    sp="$(jq -r '.at // .staged_path // empty' <<<"$rec")"
    cur="${DOCS}/${sp}"
    [[ -n "$sp" && -f "$cur" ]] || continue
    age_d=$(( (now - $(date -d "$ff" +%s 2>/dev/null || echo "$now")) / 86400 ))
    (( age_d >= BIN_AFTER_DAYS )) || continue

    dest="${BIN_DIR}/$(basename "$cur")"
    [[ -e "$dest" ]] && dest="${BIN_DIR}/$(date -u +%Y%m%dT%H%M%SZ)-$(basename "$cur")"
    if (( DRY )); then log "would bin ${sp} (${age_d}d paused)"; continue; fi
    if mv -n -- "$cur" "$dest" 2>/dev/null && [[ -f "$dest" && ! -e "$cur" ]]; then
        stamp "$f" --arg at "${dest#"${DOCS}/"}" '. + {state:"binned", at:$at}'
        paused_binned=$((paused_binned + 1)); log "binned ${sp} (${age_d}d paused)"
        # No Accept: there is no proposal to accept, because the model never answered.
        # Delete is the only arm, and the document itself stays in bin/ until you tap it.
        retract "$id"
        notify "Binned: 1 Document" "" wastebasket \
            "1\. $(md_escape "$(basename "$sp")")

_The API could not read it in $(( age_d )) days. In bin/ now; nothing is deleted without a tap._" \
            "$(bin_buttons "$id" 0)" "$id"
    else
        log "  !! could not bin ${sp}"
    fi
done

# Retrying is NOT done here, and that is a boundary rather than an omission. This
# sweep holds no ANTHROPIC_API_KEY — its unit has no EnvironmentFile and its header
# has said so since it was written — because it reads records, moves files and posts
# to ntfy, and has no reason to be able to spend money. Calling the triage from here
# would either fail at runtime or force the key into a job that has never needed it.
#
# pigeonhole.retry.timer owns that instead: same script, same key handling as the
# triage, its own unit and its own completion stamp, so the watchdog notices if it
# stops running. It fires at 07:50, five minutes after this, so the day-7 binning
# above has already removed anything not worth another model call.

# --- withdraw a batch message that has outlived its members ------------------
# The batch notification is the one message that does not belong to a single
# document, so nothing above can retire it: its members leave staging one at a
# time, by tap or by bin, and the message sits there listing documents that have
# all moved on. When the LAST member is gone it is pure clutter — and unlike a
# solo proposal there is no replacement message to inherit the undo handle, which
# is fine, because a batch whose members are all filed has nothing left to undo.
#
# A batch that still has one live member is left alone. Rebuilding its body on
# every departure would be the tidier result and a good deal more code; the stale
# entry meanwhile stays correct for the members it still lists, and the ones it
# no longer should list are all Accept-able from bin/ anyway.
for b in "${PROPOSALS_DIR}"/*.json; do
    [[ "$(jq -r '.kind  // ""' "$b")" == "batch"  ]] || continue
    [[ "$(jq -r '.state // ""' "$b")" == "staged" ]] || continue
    live=0
    while read -r m; do
        [[ -n "$m" ]] || continue
        [[ "$(jq -r '.state // ""' "${PROPOSALS_DIR}/${m}.json" 2>/dev/null)" == "staged" ]] && { live=1; break; }
    done < <(jq -r '.members[]?' "$b")
    (( live )) && continue
    if (( DRY )); then
        log "would withdraw the batch notification (no members still staged)"
        continue
    fi
    retract "$BATCH_NTFY_ID"
    stamp "$b" '. + {state:"superseded"}'
    log "withdrew the batch notification (no members still staged)"
done

(( renotified || binned || paused_binned )) && \
    log "sweep: ${renotified} re-notified, ${binned} binned, ${paused_binned} binned after an outage"
exit 0
