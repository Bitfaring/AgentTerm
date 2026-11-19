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
| `POST /v1/push` | `{token, ticket, expires, activity: {token, event, state, mac}}` | The Live Activity (#168): `liveactivity` to the activity's own token (or its push-to-start token for `start`), at `<topic>.push-type.liveactivity`, priority 5 (10 to start); `state` is `AgentsStatus`, in the clear, since iOS draws the activity from it |
| `POST /v1/push` | `{token, ticket, expires, payload, collapse?}` | `{ok: true}`; 400 for a payload that is not a sealed notice (base64, 3000 characters at most); 401 for a ticket it did not sign or that expired; 410 for a token APNs no longer knows; 429 for more than 30 a minute to one device; 502 with APNs' reason otherwise |

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
Until then the released app's switch says that the Mac has no relay set up.

Once Apple grants the filtering entitlement, `npx wrangler deploy --var FILTERING:on`, with the
entitlement added to the extension's entitlements, takes notifications back at once.

Changing `TICKET_SECRET` makes every ticket invalid: each iPhone registers
again the next time it connects to its Mac.
