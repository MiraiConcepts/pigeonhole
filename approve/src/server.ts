// pigeonhole-approve — the entire HTTP surface of the documents approve/discard flow.
//
// It does ONE thing: on an ntfy button tap, write a marker naming the action.
//
// WHAT IT DELIBERATELY CANNOT DO. It cannot read a document, name one, choose a
// destination, create a folder, or move anything. Its only mount is the approvals
// directory, which contains nothing but markers — master/documents is not visible
// to this process at all. The move is performed by pigeonhole.apply.service, a
// hardened systemd oneshot with ProtectSystem=strict that runs for a second and is
// unreachable from the network.
//
// That split is the whole security argument, and it exists because this container
// is the opposite of the oneshot in every relevant way: long-lived, reachable by
// anything on the tailnet, and gated by ntfy, which has no authentication. A
// compromised container can write "proposal <uuid> was accepted" — it cannot say
// which file that is or where it goes, because the triage decided both before the
// notification was ever sent, and the apply step re-verifies against its own record.
//
// The <id> in the callback URLs is an unguessable UUID, so the callbacks are
// capability URLs: on the tailnet, "whoever knows the id" is effectively the owner.
// Same trust model as capture and every other service here.

import { writeFile, rename, mkdir } from "node:fs/promises";

const DIR = process.env.APPROVALS_DIR ?? "/approvals";
const PORT = Number(process.env.DOCUMENTS_PORT ?? 8080);
// The ONE browser origin allowed to satisfy the X-Documents preflight. The ntfy web
// UI taps buttons via browser fetch, so CORS applies to it; the phone app does
// native HTTP and never sees this. Any other page is still refused.
const NTFY_ORIGIN = process.env.NTFY_ORIGIN ?? "";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
// "delete" is destructive, and this container is deliberately not the thing that
// decides that. It writes the same inert marker it writes for the other three; the
// hardened apply oneshot is what enforces that only a document already sitting in
// bin/ can be deleted. A compromised container can therefore ask for a delete it
// was never offered — and be refused, because the check is not here.
// No "skip". It meant "leave it in staging and ask me later", which is exactly what
// IGNORING the notification already does — so its only remaining effect was to
// dismiss a notification without deciding anything, and each one restarted the
// 7-day bin clock, so a document could be snoozed forever. Removed 2026-08-09.
const ACTIONS = new Set(["accept", "discard", "delete"]);

const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

await mkdir(DIR, { recursive: true }).catch(() => {});

// ONE marker per proposal at a time, holding the latest action. The apply step
// consumes and DELETES it, so a later tap writes a fresh one — which is exactly how
// undo works: accept, apply moves the file, then discard writes a new marker and
// apply moves it to bin.
//
// Written to a temp name and renamed, never in place. pigeonhole.apply.path watches
// this directory with PathExistsGlob, so a partially written file would be visible
// to a triggered run the instant it is created; rename(2) within one filesystem is
// atomic, so apply only ever sees a complete marker. Same trap capture hit with
// uploads, where a read raced the write and produced a truncated screenshot.
async function mark(id: string, action: string): Promise<Response> {
  const body = JSON.stringify({ action, at: new Date().toISOString() });
  const tmp = `${DIR}/.part-${id}`;
  try {
    await writeFile(tmp, body, "utf8");
    await rename(tmp, `${DIR}/${id}.json`);
  } catch (e) {
    console.error(`mark ${id} ${action}: ${(e as Error)?.message}`);
    return json({ error: "could not record" }, 500);
  }
  return json({ ok: true, id, action });
}

Bun.serve({
  port: PORT,
  error(e: Error) {
    console.error(`unhandled: ${e?.message}`);
    return json({ error: "internal" }, 500);
  },
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/healthz") return new Response("ok");

    const origin = req.headers.get("origin") ?? "";
    const originOk = NTFY_ORIGIN !== "" && origin === NTFY_ORIGIN;
    if (req.method === "OPTIONS") {
      if (!originOk) return json({ error: "origin not allowed" }, 403);
      return new Response(null, {
        status: 204,
        headers: {
          "access-control-allow-origin": origin,
          "access-control-allow-methods": "POST",
          "access-control-allow-headers": "X-Documents, Content-Type",
          "access-control-max-age": "86400",
        },
      });
    }

    const m = url.pathname.match(/^\/documents\/([^/]+)\/([a-z]+)\/?$/);
    if (!m) return json({ error: "not found" }, 404);

    // Required on every route. This is NOT authentication — anyone who can read the
    // ntfy topic has the callback ids, and ntfy is unauthenticated (accepted risk).
    // What it kills is the no-preflight vector: a bare POST with no custom header is
    // a CORS "simple request", so any page open on any tailnet device could fire one
    // cross-origin, and the .ts.net hostname is in Certificate Transparency logs
    // rather than secret. Requiring a custom header forces a preflight this server
    // answers for exactly one origin.
    if (req.headers.get("x-documents") !== "1") {
      return json({ error: "missing x-documents header" }, 403);
    }

    const [, id, action] = m;
    // Reject path traversal before the id reaches a filename. Belt to the mount's
    // braces: even a traversal here could only write inside a directory holding
    // markers, but "only" is doing unearned work in that sentence.
    if (!UUID.test(id)) return json({ error: "bad id" }, 400);
    if (!ACTIONS.has(action)) return json({ error: "bad action" }, 400);
    if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

    const res = await mark(id, action);
    // Without this the browser blocks the caller from reading its own response, so a
    // tap that actually worked still reports a network error.
    if (originOk) res.headers.set("access-control-allow-origin", origin);
    return res;
  },
});

console.log(`pigeonhole-approve listening on :${PORT}, markers -> ${DIR}`);
