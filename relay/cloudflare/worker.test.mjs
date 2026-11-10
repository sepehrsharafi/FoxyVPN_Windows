// node --test relay/cloudflare/worker.test.mjs
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import worker from "./worker.js";

const env = { SECRET: "s3cret" };
const BASE = "https://relay.example.workers.dev/";
let calls;

function mockUpstream(handler) {
  globalThis.fetch = async (url, init) => {
    const u = new URL(url);
    calls.push({ url: u, init });
    return handler(u, init);
  };
}

beforeEach(() => {
  calls = [];
  mockUpstream(() => new Response("{}", { status: 200 }));
});

const relay = (query, init = {}) => worker.fetch(new Request(BASE + query, init), env);

test("refuses without a configured secret", async () => {
  const res = await worker.fetch(new Request(BASE + "?health=1"), {});
  assert.equal(res.status, 503);
});

test("refuses a wrong or missing secret", async () => {
  assert.equal((await relay("?secret=nope&health=1")).status, 403);
  assert.equal((await relay("?health=1")).status, 403);
  assert.equal(calls.length, 0);
});

test("accepts the secret as a header and does not forward it", async () => {
  const res = await relay("?url=" + encodeURIComponent("https://vpn.mozilla.org/api/v1/fpn/token"), {
    headers: { "X-Relay-Secret": "s3cret", Authorization: "Bearer t" },
  });
  assert.equal(res.status, 200);
  assert.equal(calls[0].init.headers.get("x-relay-secret"), null);
  assert.equal(calls[0].init.headers.get("authorization"), "Bearer t");
});

test("health answers locally", async () => {
  const res = await relay("?secret=s3cret&health=1");
  assert.equal(res.status, 200);
  assert.equal((await res.json()).relay, "foxyvpn");
  assert.equal(calls.length, 0);
});

test("only forwards https to Mozilla hosts", async () => {
  for (const [url, status] of [
    ["https://example.com/", 403],
    ["https://mozilla.org.evil.com/", 403],
    ["http://vpn.mozilla.org/", 400],
    ["https://vpn.mozilla.org:8443/", 400],
    ["https://u:p@vpn.mozilla.org/", 400],
    ["not a url", 400],
  ]) {
    assert.equal((await relay("?secret=s3cret&url=" + encodeURIComponent(url))).status, status, url);
  }
  assert.equal(calls.length, 0);
});

test("forwards method, body and headers; strips hop headers; marks the response", async () => {
  mockUpstream(() => new Response('{"ok":1}', { status: 201, headers: { "x-quota-limit": "5" } }));
  const res = await relay("?secret=s3cret&url=" + encodeURIComponent("https://api.accounts.firefox.com/v1/account/login"), {
    method: "POST",
    body: '{"email":"a"}',
    headers: { "Content-Type": "application/json", "X-Forwarded-For": "1.2.3.4", "CF-Connecting-IP": "1.2.3.4" },
  });
  assert.equal(res.status, 201);
  assert.equal(res.headers.get("x-foxy-relay"), "1");
  assert.equal(res.headers.get("x-quota-limit"), "5");
  const { init } = calls[0];
  assert.equal(init.method, "POST");
  assert.equal(new TextDecoder().decode(init.body), '{"email":"a"}');
  assert.equal(init.redirect, "manual");
  assert.equal(init.headers.get("x-forwarded-for"), null);
  assert.equal(init.headers.get("cf-connecting-ip"), null);
});

test("retries Guardian 451 with a doubled leading slash", async () => {
  mockUpstream((u) => new Response("", { status: u.pathname.startsWith("//") ? 200 : 451 }));
  const res = await relay("?secret=s3cret&url=" + encodeURIComponent("https://vpn.mozilla.org/api/v1/fpn/token"));
  assert.equal(res.status, 200);
  assert.deepEqual(calls.map((c) => c.url.pathname), ["/api/v1/fpn/token", "//api/v1/fpn/token"]);
});

test("keeps the original 451 when the doubled path is refused too", async () => {
  mockUpstream(() => new Response("", { status: 451 }));
  const res = await relay("?secret=s3cret&url=" + encodeURIComponent("https://vpn.mozilla.org/api/v1/fpn/token"));
  assert.equal(res.status, 451);
  assert.equal(calls.length, 2);
});

test("an unreachable upstream is a 502 from the relay", async () => {
  mockUpstream(() => { throw new Error("down"); });
  const res = await relay("?secret=s3cret&url=" + encodeURIComponent("https://vpn.mozilla.org/"));
  assert.equal(res.status, 502);
  assert.equal(res.headers.get("x-foxy-relay"), null);
});
