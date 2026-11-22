# The push relay

A Cloudflare Worker that holds the APNs key of the released iPhone app (#66),
so that no app has to. A Mac's host hands it a notice it has already
encrypted for one iPhone; the relay passes it on to Apple as it is and keeps
nothing. `docs/DESIGN.md`, under "Through Apple, while the iPhone app is
asleep", says how the host and the iPhone use it.

Only the released build has a relay. A development build has none and sends
no push (principle 7); a build made from the source has none either.

## What it answers

| Request | Body | Answer |
|---|---|---|
| `POST /v1/register` | `{token}` | `{ticket, expires}`: an HMAC of the token and its expiry, 30 days |
| `POST /v1/push` | `{token, ticket, expires, gone}` | Takes back the notification named `gone`, handled on another device: a background push that wakes the app, or, with `FILTERING=on` once the app has Apple's filtering entitlement, an alert its extension removes it with and hides |
| `POST /v1/push` | `{token, ticket, expires, activity: {token, event, state, mac, urgent?}}` | The Live Activity (#168): `liveactivity` to the activity's own token (or its push-to-start token for `start`), at `<topic>.push-type.liveactivity`, priority 10 to start and for an update or end marked `urgent: true`, 5 otherwise (#233); `state` is `AgentsStatus`, in the clear, since iOS draws the activity from it |
| `POST /v1/push` | `{token, ticket, expires, payload, collapse?}` | An alert at priority 10, with sound, `interruption-level: time-sensitive` (#233); `{ok: true}`; 400 for a payload that is not a sealed notice (base64, 3000 characters at most); 401 for a ticket it did not sign or that expired; 410 for a token APNs no longer knows; 429 for more than 30 a minute to one device; 502 with APNs' reason otherwise |

## Priorities (#233)

Decided by the owner on 2026-11-22. What needs the user is high: a
notification (every notice a host pushes is an agent that asks or is done,
or a part that failed and stopped work) goes at `apns-priority: 10`, with
sound, time-sensitive, so that it shows during a Focus; a Live Activity's
start, and an update or end the host marks `urgent` (an agent starts or
stops asking, one becomes done, a failure appears), at 10 too. Everything
else is low: a Live Activity update at 5, which Apple delivers when it sees
fit, so that the high ones keep within the budget iOS gives an app for 10.
A relay of an earlier release does not read `urgent`, and sends every update
at 5 as it did; a host of an earlier release does not send it, and its
updates go at 5.

## Tests

```sh
node --test relay/test/*.test.js
```

`fetch` is replaced by a stand-in for APNs: nothing reaches Apple.
`wrangler dev` cannot reach APNs either, since local workerd has no HTTP/2
client. The relay is tried against Apple once it is deployed, with a
TestFlight build (PUSH-7 in `docs/TESTING.md`).

## Deploying (the owner)

Needs a Cloudflare account and the APNs key, which is kept in the owner's
private secrets and never in this repository.

```sh
cd relay
npx wrangler login
npx wrangler secret put APNS_KEY          # paste the .p8 file's text
npx wrangler secret put TICKET_SECRET     # a long random string: openssl rand -base64 48
npx wrangler deploy --var APNS_KEY_ID:<key id> --var APNS_TEAM_ID:<team id>
```

Then the relay's address goes into `PushRelay.release` in
`Sources/AgentTermProtocol/Push.swift`, and the next release carries it.

Deployed on 2026-11-19 at `https://agentterm-push.agentterm.workers.dev`
(the account's workers.dev subdomain is `agentterm`), with Workers Logs off.
Tried then with a made-up device token: `/v1/register` gave a ticket, and
`/v1/push` reached APNs Production over HTTP/2, which accepted the provider
token and refused the device token (`BadDeviceToken`).

Deployed again on 2026-11-22 with the priorities of #233 (version
`5de7c1de`), the secrets kept as they were, and tried the same way: a
ticket, then an `urgent` Live Activity update that reached APNs, which
refused the made-up token (`BadDeviceToken`).

Once Apple grants the filtering entitlement, `npx wrangler deploy --var FILTERING:on`, with the
entitlement added to the extension's entitlements, takes notifications back at once.

The limits (30 pushes a minute to one device, 5 registrations a minute from
one address) are asked of Cloudflare's rate limiting binding, which counts in
each of its locations and agrees between them later: it is approximate, and
was seen on 2026-11-19 to let 20 registrations a minute from one address
through. The relay asks it rightly; how closely it holds is Cloudflare's (the
owner's decision, 2026-11-19).

Changing `TICKET_SECRET` makes every ticket invalid: each iPhone registers
again the next time it connects to its Mac.
