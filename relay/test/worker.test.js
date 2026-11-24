// The relay's tests, with Node's own runner: `node --test relay/test`.
// Apple is not reached: `fetch` is replaced by a stand-in for APNs.

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import worker, { _resetForTests } from "../worker.js";

const TOKEN = "a".repeat(64);
let sent = [];
let apnsAnswer = () => new Response("", { status: 200 });
let publicKey;
let env;

globalThis.fetch = async (url, init) => {
  sent.push({ url: String(url), ...init });
  return apnsAnswer();
};

async function setUp() {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  publicKey = pair.publicKey;
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(pkcs8).toString("base64")}\n-----END PRIVATE KEY-----\n`;
  env = {
    APNS_KEY: pem,
    APNS_KEY_ID: "KEYID12345",
    APNS_TEAM_ID: "TEAMID1234",
    APNS_TOPIC: "com.example.app",
    APNS_HOST: "apns.test",
    TICKET_SECRET: "a secret for the tests only",
  };
}

beforeEach(async () => {
  sent = [];
  apnsAnswer = () => new Response("", { status: 200 });
  _resetForTests();
  await setUp();
});

function call(path, body, ip = "192.0.2.1") {
  return worker.fetch(
    new Request(`https://relay.test${path}`, {
      method: "POST",
      body: typeof body === "string" ? body : JSON.stringify(body),
      headers: { "cf-connecting-ip": ip },
    }),
    env,
  );
}

async function ticket(token = TOKEN) {
  const answer = await call("/v1/register", { token });
  assert.equal(answer.status, 200);
  return answer.json();
}

test("RELAY-1 a device token gets a ticket; something else does not", async () => {
  const { ticket: t, expires } = await ticket();
  assert.ok(t.length > 20);
  assert.ok(expires > Date.now() / 1000 + 29 * 86400);
  assert.equal((await call("/v1/register", { token: "not a token" })).status, 400);
  assert.equal((await call("/v1/register", "{")).status, 400);
});

test("RELAY-2 a push with its ticket reaches APNs as it was encrypted, signed with the key", async () => {
  const { ticket: t, expires } = await ticket();
  const answer = await call("/v1/push", { token: TOKEN, ticket: t, expires, payload: "AAAA", collapse: "mac-7", category: "reply" });
  assert.equal(answer.status, 200);
  assert.equal(sent.length, 1);
  const request = sent[0];
  assert.equal(request.url, `https://apns.test/3/device/${TOKEN}`);
  assert.equal(request.headers["apns-topic"], "com.example.app");
  assert.equal(request.headers["apns-push-type"], "alert");
  assert.equal(request.headers["apns-collapse-id"], "mac-7");
  const body = JSON.parse(request.body);
  assert.equal(body.e, "AAAA");
  assert.equal(body.i, "mac-7");
  assert.equal(body.aps["mutable-content"], 1);
  assert.equal(body.aps.category, "reply");
  assert.equal(body.aps.alert.body, "An agent needs you");
  // RELAY-12 (#233): every notice pushed needs the user: at once, with
  // sound, time-sensitive so that it shows during a Focus.
  assert.equal(request.headers["apns-priority"], "10");
  assert.equal(body.aps.sound, "default");
  assert.equal(body.aps["interruption-level"], "time-sensitive");
  // The JWT: its header names the key, and the key's public half verifies it.
  const [head, claims, signature] = request.headers.authorization.replace("bearer ", "").split(".");
  const decode = (part) => Buffer.from(part, "base64url");
  assert.deepEqual(JSON.parse(decode(head)), { alg: "ES256", kid: "KEYID12345" });
  assert.equal(JSON.parse(decode(claims)).iss, "TEAMID1234");
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    decode(signature),
    new TextEncoder().encode(`${head}.${claims}`),
  );
  assert.ok(ok, "the JWT is signed with the key");
});

test("RELAY-3 no push without the relay's ticket for that token, or with an expired one", async () => {
  const { ticket: t, expires } = await ticket();
  const forged = await call("/v1/push", { token: TOKEN, ticket: "x" + t.slice(1), expires, payload: "AAAA" });
  assert.equal(forged.status, 401);
  const other = await call("/v1/push", { token: "b".repeat(64), ticket: t, expires, payload: "AAAA" });
  assert.equal(other.status, 401);
  const later = await call("/v1/push", { token: TOKEN, ticket: t, expires: expires + 1, payload: "AAAA" });
  assert.equal(later.status, 401);
  const old = await call("/v1/push", { token: TOKEN, ticket: t, expires: 1000, payload: "AAAA" });
  assert.equal(old.status, 401);
  assert.equal(sent.length, 0);
});

test("RELAY-4 a payload that is not an encrypted notice, or too large, is refused", async () => {
  const { ticket: t, expires } = await ticket();
  for (const payload of ["", "plain text!", "A".repeat(3001), 42]) {
    assert.equal((await call("/v1/push", { token: TOKEN, ticket: t, expires, payload })).status, 400);
  }
  assert.equal(sent.length, 0);
});

test("RELAY-5 a token APNs no longer knows is answered 410, so the host forgets it", async () => {
  const { ticket: t, expires } = await ticket();
  apnsAnswer = () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 });
  const answer = await call("/v1/push", { token: TOKEN, ticket: t, expires, payload: "AAAA" });
  assert.equal(answer.status, 410);
  assert.equal((await answer.json()).reason, "Unregistered");
  apnsAnswer = () => new Response(JSON.stringify({ reason: "TooManyRequests" }), { status: 429 });
  const busy = await call("/v1/push", { token: TOKEN, ticket: t, expires, payload: "AAAA" });
  assert.equal(busy.status, 502);
  assert.equal((await busy.json()).reason, "TooManyRequests");
});

test("RELAY-6 the provider token is made once and used again", async () => {
  const { ticket: t, expires } = await ticket();
  await call("/v1/push", { token: TOKEN, ticket: t, expires, payload: "AAAA" });
  await call("/v1/push", { token: TOKEN, ticket: t, expires, payload: "AAAA" });
  assert.equal(sent[0].headers.authorization, sent[1].headers.authorization);
});

test("RELAY-7 a device over its limit is refused before APNs", async () => {
  const { ticket: t, expires } = await ticket();
  env.PUSH_LIMIT = { limit: async ({ key }) => ({ success: key !== TOKEN }) };
  const answer = await call("/v1/push", { token: TOKEN, ticket: t, expires, payload: "AAAA" });
  assert.equal(answer.status, 429);
  assert.equal(sent.length, 0);
});

test("RELAY-8 a relay without its key says so", async () => {
  const { ticket: t, expires } = await ticket();
  delete env.APNS_KEY;
  const answer = await call("/v1/push", { token: TOKEN, ticket: t, expires, payload: "AAAA" });
  assert.equal(answer.status, 500);
  assert.match((await answer.json()).reason, /APNs key is not set up/);
});

test("RELAY-9 a notification handled elsewhere is taken back by a background push, or with filtering by an alert the extension hides", async () => {
  const { ticket: t, expires } = await ticket();
  const answer = await call("/v1/push", { token: TOKEN, ticket: t, expires, gone: "mac-7" });
  assert.equal(answer.status, 200);
  assert.equal(sent[0].headers["apns-push-type"], "background");
  assert.equal(sent[0].headers["apns-priority"], "5");
  assert.deepEqual(JSON.parse(sent[0].body), { aps: { "content-available": 1 }, g: "mac-7" });
  env.FILTERING = "on";
  await call("/v1/push", { token: TOKEN, ticket: t, expires, gone: "mac-7" });
  assert.equal(sent[1].headers["apns-push-type"], "alert");
  assert.equal(JSON.parse(sent[1].body).aps["mutable-content"], 1);
  assert.equal((await call("/v1/push", { token: TOKEN, ticket: t, expires, gone: "not a name!" })).status, 400);
  assert.equal((await call("/v1/push", { token: TOKEN, ticket: "x", expires, gone: "mac-7" })).status, 401);
});

test("RELAY-10 a Live Activity is updated, started and ended with its own token, at its own topic; at 10 when urgent, else 5 (#233)", async () => {
  const { ticket: t, expires } = await ticket();
  const activityToken = "c".repeat(64);
  const state = { working: 2, permission: 0, asking: 1, done: 0, failed: 0, waiting: ["deploy"], doneNames: [] };
  const answer = await call("/v1/push", { token: TOKEN, ticket: t, expires, activity: { token: activityToken, event: "update", state, mac: "Studio" } });
  assert.equal(answer.status, 200);
  assert.equal(sent[0].url, `https://apns.test/3/device/${activityToken}`);
  assert.equal(sent[0].headers["apns-push-type"], "liveactivity");
  assert.equal(sent[0].headers["apns-topic"], "com.example.app.push-type.liveactivity");
  assert.equal(sent[0].headers["apns-priority"], "5");
  const aps = JSON.parse(sent[0].body).aps;
  assert.equal(aps.event, "update");
  assert.deepEqual(aps["content-state"], state);
  assert.ok(aps["stale-date"] > aps.timestamp);
  await call("/v1/push", { token: TOKEN, ticket: t, expires, activity: { token: activityToken, event: "start", state, mac: "Studio" } });
  const start = JSON.parse(sent[1].body).aps;
  assert.equal(start["attributes-type"], "AgentsActivityAttributes");
  assert.deepEqual(start.attributes, { mac: "Studio" });
  assert.equal(sent[1].headers["apns-priority"], "10");
  await call("/v1/push", { token: TOKEN, ticket: t, expires, activity: { token: activityToken, event: "end", state, mac: "Studio" } });
  assert.ok(JSON.parse(sent[2].body).aps["dismissal-date"]);
  assert.equal(sent[2].headers["apns-priority"], "5");
  // Marked urgent by the host (an agent starts or stops asking, is done, a
  // part failed): at 10, an update or an end; a start always is.
  const urgent = (event, value) => call("/v1/push", { token: TOKEN, ticket: t, expires, activity: { token: activityToken, event, state, mac: "Studio", urgent: value } });
  await urgent("update", true);
  assert.equal(sent[3].headers["apns-priority"], "10");
  await urgent("end", true);
  assert.equal(sent[4].headers["apns-priority"], "10");
  await urgent("update", false);
  assert.equal(sent[5].headers["apns-priority"], "5");
  await urgent("start", false);
  assert.equal(sent[6].headers["apns-priority"], "10");
  // Only true itself is urgent.
  await urgent("update", "yes");
  assert.equal(sent[7].headers["apns-priority"], "5");
  // What the activity shows is not marked: `urgent` is not passed on.
  assert.equal(JSON.parse(sent[3].body).aps["content-state"].urgent, undefined);
  assert.equal(JSON.parse(sent[3].body).urgent, undefined);
  assert.equal((await call("/v1/push", { token: TOKEN, ticket: t, expires, activity: { token: "x", event: "update", state } })).status, 400);
  assert.equal((await call("/v1/push", { token: TOKEN, ticket: t, expires, activity: { token: activityToken, event: "explode", state } })).status, 400);
  assert.equal((await call("/v1/push", { token: TOKEN, ticket: "bad", expires, activity: { token: activityToken, event: "update", state } })).status, 401);
});

test("RELAY-11 registrations are limited by the caller's address", async () => {
  const counts = {};
  env.REGISTER_LIMIT = { limit: async ({ key }) => ({ success: (counts[key] = (counts[key] ?? 0) + 1) <= 2 }) };
  assert.equal((await call("/v1/register", { token: TOKEN }, "198.51.100.7")).status, 200);
  assert.equal((await call("/v1/register", { token: TOKEN }, "198.51.100.7")).status, 200);
  const third = await call("/v1/register", { token: TOKEN }, "198.51.100.7");
  assert.equal(third.status, 429);
  assert.match((await third.json()).reason, /too many registrations/);
  assert.equal((await call("/v1/register", { token: TOKEN }, "203.0.113.9")).status, 200, "another address is not held back");
});

test("RELAY-12 pushes are limited by the caller's address too, whatever the tokens (#312)", async () => {
  const counts = {};
  env.CALLER_LIMIT = { limit: async ({ key }) => ({ success: (counts[key] = (counts[key] ?? 0) + 1) <= 2 }) };
  const payload = "QUJD";
  // Tickets for three made-up tokens, pushed from one address.
  const tokens = ["b", "c", "d"].map((letter) => letter.repeat(64));
  const tickets = [];
  for (const token of tokens) tickets.push(await ticket(token));
  const answers = [];
  for (const [index, token] of tokens.entries()) {
    const { ticket: t, expires } = tickets[index];
    answers.push((await call("/v1/push", { token, ticket: t, expires, payload }, "198.51.100.8")).status);
  }
  assert.deepEqual(answers, [200, 200, 429], "a caller pushed to as many devices as it had tickets for");
  const { ticket: t, expires } = tickets[0];
  assert.equal((await call("/v1/push", { token: tokens[0], ticket: t, expires, payload }, "203.0.113.10")).status, 200, "another address is not held back");
});
