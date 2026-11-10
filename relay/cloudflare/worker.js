// FoxyVPN control-plane relay (Cloudflare Worker).
//
// Carries only Mozilla's sign-in, Guardian (proxy pass) and server-list
// requests for clients whose region Mozilla refuses (HTTP 451). VPN traffic
// never goes through it.
//
//   GET  /?secret=S              plain-text status (open it in a browser)
//   GET  /?secret=S&health=1     JSON health check; contacts nobody
//   GET  /?secret=S&trace=1      where this Worker exits (Cloudflare trace)
//   ANY  /?secret=S&url=<https>  forwards method, headers and body to <https>
//
// The secret may also be sent as the X-Relay-Secret header instead of ?secret=.
// Set it as a Worker secret named SECRET (Settings > Variables and Secrets, or
// `npx wrangler secret put SECRET`). Without it the relay forwards nothing.

const VERSION = 1;

// Hosts the relay forwards to (and their subdomains). Nothing else.
const ALLOWED_DOMAINS = ["mozilla.org", "mozilla.com", "firefox.com"];

// Guardian's edge refuses some regions on the literal path; the origin serves
// the same handler for a doubled leading slash.
const GUARDIAN_HOST = "vpn.mozilla.org";

// Request headers that describe the hop to this Worker, not the request.
const DROP_REQUEST = new Set([
  "host", "connection", "content-length", "keep-alive", "proxy-authenticate",
  "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade",
  "forwarded", "x-forwarded-for", "x-forwarded-proto", "x-forwarded-host",
  "x-real-ip", "true-client-ip", "x-relay-secret",
]);

function text(status, body, extra = {}) {
  return new Response(body + "\n", {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", ...extra },
  });
}

function fail(status, why) {
  return text(status, why, { "X-Relay-Error": why });
}

function json(body) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

// Constant-time comparison, so the secret cannot be guessed byte by byte.
function sameSecret(given, expected) {
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ b[i];
  return diff === 0;
}

function allowedHost(host) {
  return ALLOWED_DOMAINS.some((d) => host === d || host.endsWith("." + d));
}

function parseTarget(raw) {
  let target;
  try {
    target = new URL(raw);
  } catch {
    return [null, "url must be an https URL"];
  }
  if (target.protocol !== "https:") return [null, "url must be an https URL"];
  if (target.username || target.password || target.hash || (target.port && target.port !== "443")) {
    return [null, "url must not contain credentials, a fragment or a port"];
  }
  if (!allowedHost(target.hostname.toLowerCase())) return [null, "host not allowed: " + target.hostname];
  return [target, null];
}

async function trace() {
  const res = await fetch("https://www.cloudflare.com/cdn-cgi/trace");
  const fields = Object.fromEntries(
    (await res.text()).trim().split("\n").map((line) => line.split("=", 2)),
  );
  return json({ colo: fields.colo, loc: fields.loc, ip: fields.ip });
}

async function forward(request, target) {
  const headers = new Headers();
  for (const [name, value] of request.headers) {
    const lower = name.toLowerCase();
    if (DROP_REQUEST.has(lower) || lower.startsWith("cf-")) continue;
    headers.set(name, value);
  }
  // Control-plane bodies are small JSON: read whole so a retry can resend it.
  const body = request.method === "GET" || request.method === "HEAD" ? undefined : await request.arrayBuffer();
  const send = (url) => fetch(url, { method: request.method, headers, body, redirect: "manual" });

  let upstream = await send(target);
  if (upstream.status === 451 && target.hostname === GUARDIAN_HOST && !target.pathname.startsWith("//")) {
    const doubled = new URL(target);
    doubled.pathname = "/" + target.pathname;
    const retry = await send(doubled);
    if (retry.status !== 451) upstream = retry;
  }

  const out = new Headers(upstream.headers);
  // Marks a response that Mozilla sent, as opposed to an error page Cloudflare
  // generated before this Worker ran (quota exhausted, Worker down, ...).
  out.set("X-Foxy-Relay", String(VERSION));
  return new Response(upstream.body, { status: upstream.status, statusText: upstream.statusText, headers: out });
}

export default {
  async fetch(request, env = {}) {
    const here = new URL(request.url);
    const params = here.searchParams;
    const expected = env.SECRET || "";
    if (!expected) return fail(503, "no SECRET is set on this Worker");
    const given = request.headers.get("X-Relay-Secret") ?? params.get("secret") ?? "";
    if (!sameSecret(given, expected)) return fail(403, "wrong secret");

    if (params.get("health") === "1") {
      return json({ relay: "foxyvpn", version: VERSION, ready: true, colo: request.cf?.colo ?? null });
    }
    if (params.get("trace") === "1") {
      try {
        return await trace();
      } catch {
        return fail(502, "trace failed");
      }
    }
    if (!params.has("url")) return text(200, "FoxyVPN relay is working. Put this address in the app.");

    const [target, why] = parseTarget(params.get("url"));
    if (!target) return fail(why.startsWith("host") ? 403 : 400, why);
    try {
      return await forward(request, target);
    } catch {
      return fail(502, "upstream request failed");
    }
  },
};
