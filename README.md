# pigeonhole

> A pipeline of [catallenya](https://github.com/carrein/catallenya), mirrored from
> `pigeonhole/`. Force-synced by CI — open issues and pull requests on the parent
> repo, not here. The document corpus itself stays in a Syncthing folder named
> `documents` — that is the drop zone, not this code.

Drop a document anywhere it syncs; approve where it goes with one tap.

To pigeonhole something is to sort it into a compartment. That is the whole job —
and the compartment is a real directory, not a database row.

```
you, anywhere ──▶ <documents folder>/Some Scan 2024.pdf
                        │  a path unit fires on the drop zone
                        ▼
                  triage — ONE model call
                        │  proposes folder, type, owner, date, filename
                        ▼
                  staging/2024-03-11 Tax Assessment (IRAS).pdf
                        │  already renamed. notification: [Accept] [Discard]
                        │
                  you tap ─┴──▶ 04 Tax/  or  bin/
```

## State is the filesystem

There is no database, no ledger, no state file sitting beside the state. A document
is wherever it currently is, and the three places mean three things:

| Location | Meaning |
|---|---|
| the folder root | arrived, not yet looked at |
| `staging/` | classified and renamed, waiting on you |
| a numbered folder | filed |
| `bin/` | rejected, or aged out of staging — **never emptied automatically** |

So `ls` answers "what is this system doing" completely and instantly, and nothing
can drift out of sync with anything else, because there is no second copy of the
truth to drift.

Each button means *"put this in the state I name, from wherever it is"* — not "undo
the last thing" or "advance one step". That phrasing is what makes the buttons work
identically on a freshly staged document and on one rescued from `bin/` a week later.

## Nothing files itself

The model proposes; a human decides. Every document waits in `staging/` — **already
renamed to its proposed filename**, so what you are approving is visible in the
filename rather than described in a notification.

Clean proposals batch into one message. Anything doubtful gets its own: a new folder,
no identifiable owner, no date printed on the document itself, or a name that looks
like a family member's. A proposal that fails a safety check gets a notification with
**no Accept button at all** — you can see it was refused and why, and there is nothing
to tap.

Ignoring a notification is a valid outcome, not a dropped ball. The document stays in
`staging/` and reappears in the next batch.

## Two buttons, one outcome each

Accept and Discard. There is deliberately no undo and no skip.

The undo used to exist and fell out of the state rule for free — filing something and
then discarding it is just another move. It was removed because it only worked if the
notification stayed live after a tap, which meant a permanent notification on every
document ever filed.

Skip went because ignoring a notification already meant "leave it in staging". Its
one distinct effect was dismissing a notification without deciding — and each skip
rewrote the record, which restarted the seven-day clock. A deadline a daily tap can
postpone forever is not a deadline.

Recovery for a misfile is **moving the file**. It is in Syncthing on every device,
`bin/` is never auto-emptied, and snapshots plus offsite backups sit behind all of it.

## A notification lives exactly as long as its decision is outstanding

Every tap withdraws its own notification — but only when nothing was refused. A
refused tap moved nothing, and its buttons are still the way to act, so the message
stays.

That conditional is the entire point: a notification disappearing means *the thing
happened*, not merely *you tapped something*. One still sitting there means it did
not. No button sets `clear=true`, because that dismisses on the tap, before the move
has been attempted, and would make a refused move look like a completed one.

## Clocks

| When | What |
|---|---|
| 24h in `staging/` | one nudge, replacing the original notification |
| 7d in `staging/` | moved to `bin/`, with a note offering Accept or Delete |
| 7d after that note | the **message** is withdrawn — the document stays in `bin/` |

The sweep never empties `bin/`. The only thing that ever removes a document is a
Delete tap. "Nothing is destroyed without a tap" is the rule, and Delete is the tap.

There is also a nightly backstop run, which is **not** a schedule for the pipeline —
that is event-driven. It exists for what the path-unit globs cannot see, such as a
file whose extension matches nothing. It fires the same triage, which exits in
milliseconds having found nothing.

## The container holds nothing — do not "clean this up"

This pipeline's sibling, [afterimage](https://github.com/MiraiConcepts/afterimage),
runs a container that holds a full-scope calendar credential and performs the write
itself. This one is the opposite by design:

- The approval container can do exactly one thing: write a **zero-byte marker** into
  an approvals directory. It holds no secret, and mounts nothing else.
- The moves are performed by hardened host oneshots that no network packet can reach.

They look like one container's worth of code, and merging them would hand the
calendar credential to the surface that currently holds nothing at all. The asymmetry
is the security design, not an accident.

The consequence that matters: a marker is just a filename that the container wrote,
so the mover **never trusts it**. "The interface only offers Delete on a binned
document" is not a guarantee the mover may rely on — the bin-only restriction for
deletion is enforced in the mover, and tested from both directions.

## What guards the filenames

The classification vocabulary does not gate anything. With a human tap in front of
every move, the folder, document type and qualifier are free text, and the model may
propose a folder that does not exist yet.

Two functions are what the old closed vocabulary used to guarantee: one validates that
a proposed path segment is a legal, safe filename component, and one asserts the
resolved destination is still inside the documents tree. They are the security
boundary. Do not weaken them.

## Scope

A component of [catallenya](https://github.com/carrein/catallenya), published for
reading rather than installation. It is not standalone: it expects a specific host
filesystem layout, a file-sync tree to watch, a container definition that lives in
the parent repository's compose file, and a systemd policy contract it inherits
rather than declares.

It is one of two pipelines built to the same design — the other is
[afterimage](https://github.com/MiraiConcepts/afterimage), which files calendar
events instead of documents. Drop zone, one AI call, buttons whose meaning is a
target state, a hardened writer, a morning-side sweep: the shared shape and the
reasoning behind each rule are in the parent repo's `docs/intake-playbook.md`.
