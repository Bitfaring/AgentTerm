// The push relay of AgentTerm (#66): a Cloudflare Worker that holds the APNs
// key, so that no app has to. A host hands it a notice it has already
// encrypted for one iPhone; the relay sends it to Apple as it is. It keeps
// nothing: no notice, no device token, no log of either.
//
// POST /v1/register  {token}                              -> {ticket, expires}
// POST /v1/push      {token, ticket, expires, payload,
//                     collapse?, category?}                -> {ok: true} | {error, reason}
// POST /v1/push      {token, ticket, expires, gone}       takes back the
//                     notification named `gone`, handled on another device
// POST /v1/push      {token, ticket, expires, activity: {token, event,
//                     state, mac}}                         updates, starts or
//                     ends the device's Live Activity (#168): `token` is the
//                     activity's own, signed for by the device's ticket
//
// The iPhone registers its device token and gets a ticket, which it hands to
// the host it is paired with. A push is sent only with a ticket the relay
// signed for that token and that has not expired.
//
// Settings (wrangler.toml and `wrangler secret put`):
//   APNS_KEY       secret: the .p8 key's text
//   TICKET_SECRET  secret: any long random string, the key tickets are signed with
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC
//   APNS_HOST      api.push.apple.com, or api.sandbox.push.apple.com
//   PUSH_LIMIT     optional: a rate limiting binding, keyed by device token
//   REGISTER_LIMIT optional: a rate limiting binding for /v1/register, keyed
//                  by the caller's address, so that tickets are not handed
//                  out in bulk
//   FILTERING      "on" once the app has Apple's filtering entitlement: a
//                  notification is then taken back by an alert push its
//                  extension removes it with and shows nothing for; until
//                  then by a background push that wakes the app.

const TICKET_DAYS = 30;
const JWT_SECONDS = 50 * 60; // Apple takes a token for an hour at most, and refuses one renewed more often than every 20 minutes.
const MAX_PAYLOAD = 3000; // characters of the encrypted notice, base64; APNs takes 4 KB in all.
const TOKEN = /^[0-9a-f]{64,200}$/;

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      return reply(500, { error: "relay", reason: String(error?.message ?? error) });
    }
  },
};

async function route(request, env) {
  const url = new URL(request.url);
  if (request.method !== "POST") return reply(405, { error: "method" });
  let body;
  try {
    body = await request.json();
  } catch {
    return reply(400, { error: "body", reason: "not JSON" });
  }
  if (url.pathname === "/v1/register") return register(body, env, request.headers.get("cf-connecting-ip") ?? "unknown");
  if (url.pathname === "/v1/push") return push(body, env);
  return reply(404, { error: "path" });
}

async function register(body, env, caller) {
  const token = String(body?.token ?? "").toLowerCase();
  if (!TOKEN.test(token)) return reply(400, { error: "token", reason: "not a device token" });
  if (env.REGISTER_LIMIT) {
    const { success } = await env.REGISTER_LIMIT.limit({ key: caller });
    if (!success) return reply(429, { error: "limit", reason: "too many registrations from this address" });
  }
  const expires = Math.floor(Date.now() / 1000) + TICKET_DAYS * 86400;
  return reply(200, { ticket: await sign(env, token, expires), expires });
}

async function push(body, env) {
  const token = String(body?.token ?? "").toLowerCase();
  const expires = Number(body?.expires);
  const payload = body?.payload;
  if (!TOKEN.test(token)) return reply(400, { error: "token", reason: "not a device token" });
  if (!Number.isInteger(expires) || expires < Date.now() / 1000) return reply(401, { error: "ticket", reason: "expired" });
  if (!(await verify(env, token, expires, String(body?.ticket ?? "")))) return reply(401, { error: "ticket", reason: "not signed by this relay" });
  if (body?.gone !== undefined) return takeBack(token, String(body.gone), env);
  if (body?.activity !== undefined) return activity(token, body.activity, env);
  if (typeof payload !== "string" || payload.length === 0 || payload.length > MAX_PAYLOAD || !/^[A-Za-z0-9+/=]+$/.test(payload)) {
    return reply(400, { error: "payload", reason: "not an encrypted notice" });
  }
  if (env.PUSH_LIMIT) {
    const { success } = await env.PUSH_LIMIT.limit({ key: token });
    if (!success) return reply(429, { error: "limit", reason: "too many pushes to this device" });
  }
  const collapse = typeof body?.collapse === "string" ? body.collapse.slice(0, 64) : undefined;
  const category = typeof body?.category === "string" ? body.category.slice(0, 64) : undefined;
  // What a device shows when its extension cannot decrypt the notice: the
  // extension replaces it with the notice itself.
  const aps = { alert: { title: "AgentTerm", body: "An agent needs you" }, sound: "default", "mutable-content": 1 };
  if (category) aps.category = category;
  // `i` names the notification for the extension, as the collapse identifier does for iOS.
  return send(token, env, "alert", "10", collapse, collapse ? { aps, e: payload, i: collapse } : { aps, e: payload });
}

// A notification handled on another device, taken back from this one.
async function takeBack(token, gone, env) {
  if (!/^[A-Za-z0-9-]{1,64}$/.test(gone)) return reply(400, { error: "gone", reason: "not a notification's name" });
  if (env.PUSH_LIMIT) {
    const { success } = await env.PUSH_LIMIT.limit({ key: token });
    if (!success) return reply(429, { error: "limit", reason: "too many pushes to this device" });
  }
  const filtering = env.FILTERING === "on";
  const aps = filtering ? { alert: { title: "AgentTerm", body: "" }, "mutable-content": 1 } : { "content-available": 1 };
  return send(token, env, filtering ? "alert" : "background", filtering ? "10" : "5", undefined, { aps, g: gone });
}

// The Live Activity of the agents on a Mac (#168): what it shows is in the
// clear, since iOS draws it from the push; it holds counts and session
// names only, never what an agent said.
async function activity(deviceToken, body, env) {
  const token = String(body?.token ?? "").toLowerCase();
  const event = body?.event;
  if (!TOKEN.test(token)) return reply(400, { error: "activity", reason: "not an activity token" });
  if (!["update", "end", "start"].includes(event)) return reply(400, { error: "activity", reason: "not an event" });
  const state = body?.state;
  if (typeof state !== "object" || state === null || JSON.stringify(state).length > 2000) return reply(400, { error: "activity", reason: "not a state" });
  if (env.PUSH_LIMIT) {
    const { success } = await env.PUSH_LIMIT.limit({ key: deviceToken });
    if (!success) return reply(429, { error: "limit", reason: "too many pushes to this device" });
  }
  const now = Math.floor(Date.now() / 1000);
  const aps = { timestamp: now, event, "content-state": state, "stale-date": now + 30 * 60 };
  if (event === "end") aps["dismissal-date"] = now + 15 * 60;
  if (event === "start") {
    aps["attributes-type"] = "AgentsActivityAttributes";
    aps.attributes = { mac: String(body?.mac ?? "the Mac").slice(0, 80) };
    aps.alert = { title: "AgentTerm", body: "Agents are at work" };
  }
  return send(token, env, "liveactivity", event === "start" ? "10" : "5", undefined, { aps }, `${env.APNS_TOPIC}.push-type.liveactivity`);
}

async function send(token, env, type, priority, collapse, payload, topic = env.APNS_TOPIC) {
  const headers = {
    authorization: `bearer ${await providerToken(env)}`,
    "apns-topic": topic,
    "apns-push-type": type,
    "apns-priority": priority,
    "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600),
    "content-type": "application/json",
  };
  if (collapse) headers["apns-collapse-id"] = collapse;
  const host = env.APNS_HOST || "api.push.apple.com";
  const answer = await fetch(`https://${host}/3/device/${token}`, { method: "POST", headers, body: JSON.stringify(payload) });
  if (answer.status === 200) return reply(200, { ok: true });
  let reason = "";
  try {
    reason = (await answer.json())?.reason ?? "";
  } catch {}
  if (reason === "ExpiredProviderToken") cachedJWT = null;
  // 410 is a token the device no longer has: the host forgets it.
  const status = answer.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered" ? 410 : 502;
  return reply(status, { error: "apns", reason: reason || `HTTP ${answer.status}` });
}

// MARK: tickets

async function hmacKey(env) {
  if (!env.TICKET_SECRET) throw new Error("TICKET_SECRET is not set");
  return crypto.subtle.importKey("raw", new TextEncoder().encode(env.TICKET_SECRET), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
    "verify",
  ]);
}

async function sign(env, token, expires) {
  const mac = await crypto.subtle.sign("HMAC", await hmacKey(env), new TextEncoder().encode(`${token}.${expires}`));
  return base64url(new Uint8Array(mac));
}

async function verify(env, token, expires, ticket) {
  let mac;
  try {
    mac = fromBase64url(ticket);
  } catch {
    return false;
  }
  return crypto.subtle.verify("HMAC", await hmacKey(env), mac, new TextEncoder().encode(`${token}.${expires}`));
}

// MARK: the provider token, a JWT signed with the .p8 key (ES256)

let cachedJWT = null;

async function providerToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJWT && cachedJWT.key === env.APNS_KEY_ID && now - cachedJWT.issued < JWT_SECONDS) return cachedJWT.value;
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID || !env.APNS_TOPIC) throw new Error("the APNs key is not set up");
  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const key = await crypto.subtle.importKey("pkcs8", fromBase64(pem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = base64url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = base64url(new TextEncoder().encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now })));
  // WebCrypto gives the signature as r and s side by side, which is what a JWT wants.
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${claims}`));
  const value = `${head}.${claims}.${base64url(new Uint8Array(signature))}`;
  cachedJWT = { value, issued: now, key: env.APNS_KEY_ID };
  return value;
}

// MARK: helpers

function reply(status, value) {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}

function base64url(bytes) {
  let text = "";
  for (const byte of bytes) text += String.fromCharCode(byte);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromBase64url(text) {
  return fromBase64(text.replace(/-/g, "+").replace(/_/g, "/"));
}

function fromBase64(text) {
  const raw = atob(text);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

// For the tests only.
export function _resetForTests() {
  cachedJWT = null;
}
