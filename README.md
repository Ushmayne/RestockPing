# RestockPing

Back-in-stock alerts for Shopify stores. When a product is sold out, shoppers can leave
their email on the product page. When the merchant restocks it, RestockPing emails them,
then tracks which of those emails turned into orders.

It's a Rails app embedded in the Shopify admin, built on Shopify's current app platform:
managed installation, token exchange, expiring offline tokens, and the GraphQL Admin API.

## Status

Built in phases. Each phase ships with tests.

| # | Phase | Status |
|---|-------|--------|
| 1 | Rails app, embedded auth (token exchange), encrypted token storage | Done |
| 2 | `inventory_levels/update` webhook: HMAC verification, dedup, 0 → >0 restock detection | Done |
| 3 | Theme app extension (signup form) + app proxy endpoint | Done |
| 4 | Sidekiq jobs that send restock emails, with retries | Planned |
| 5 | Order webhooks to attribute conversions to alerts | Planned |
| 6 | Admin analytics page | Planned |
| 7 | Full test coverage, CI, deployment notes | Planned |

## Stack

- Ruby 3.4, Rails 8.1, PostgreSQL 16
- `shopify_app` 23 / `shopify_api` 16, Admin API version `2026-10` (GraphQL only, REST disabled)
- App Bridge from Shopify's CDN
- Redis + Sidekiq (from Phase 4)
- Minitest + WebMock

## How authentication works

There is no OAuth redirect flow. Shopify handles installation from the scopes in
`shopify.app.toml` (`use_legacy_install_flow = false`), and the app authenticates every
request with token exchange:

1. Inside the Shopify admin, App Bridge gives the page a short-lived **ID token**: a JWT
   signed with the app's client secret. App Bridge attaches it to every `fetch` as
   `Authorization: Bearer <token>`. The first document load gets it as an `id_token` param.
2. `AuthenticatedController` (via `ShopifyApp::EnsureHasSession`) verifies the JWT.
   The signature is checked with HS256 (algorithm pinned), plus `exp`/`nbf`, and `aud`
   must equal our client ID. It also rejects requests whose `shop` param doesn't match
   the token's shop.
3. If the shop has no stored token, or its token has expired, the app exchanges the ID
   token at `/admin/oauth/access_token` for an **expiring offline access token**
   (1 hour) plus a **refresh token** (90 days).
4. Tokens live on the `Shop` row, encrypted with Active Record Encryption.
5. Background work with no merchant present (webhooks, jobs) calls
   `shop.with_shopify_session`. That refreshes the token under a row lock, so two
   concurrent jobs can't both spend the same single-use refresh token.

## How restock detection works

Every subscribed topic is delivered to `POST /api/webhooks` (see `shopify.app.toml`).

1. **Verify.** HMAC-SHA256 over the raw request body with the client secret, compared
   in constant time against `X-Shopify-Hmac-Sha256`. The previous secret is also
   accepted during a rotation. A bad signature gets `401` and nothing else runs.
2. **Deduplicate** on `X-Shopify-Webhook-Id`. Shopify retries failed deliveries 8 times
   over 4 hours and can send a delivery more than once.
3. **Re-fetch.** The `inventory_levels/update` payload only carries the new `available`
   count for one location. Deliveries can be coalesced and sometimes lack
   `location_id`. So the webhook is treated as "this inventory item changed", and each
   variant's total `inventoryQuantity` is fetched from the GraphQL Admin API. The call
   runs outside any DB transaction and refreshes an expired access token first.
4. **Detect,** in one transaction with the dedup row (`WebhookDelivery.process_once`):
   - `INSERT … ON CONFLICT DO NOTHING` creates the variant's stock row if it's missing.
     A first sighting is only a baseline and never counts as a restock.
   - `SELECT … FOR UPDATE` serialises concurrent webhooks for the same variant, so
     only one of them can see the old `0`.
   - A reading observed earlier than the stored one is discarded (stale response).
   - `previous <= 0 && current > 0` creates a `RestockEvent`. Negative counts mean
     oversold, which is still out of stock.
5. **Respond** `200`. Any error returns `500` with nothing recorded (the dedup row
   rolls back with everything else), so Shopify's retry processes it again.

`app/uninstalled` deletes the shop, its tokens and its data. The mandatory compliance
topics (`customers/data_request`, `customers/redact`, `shop/redact`) are verified and
handled the same way.

## How storefront signup works

A theme app extension (`extensions/restock-notify`) adds a **Back-in-stock alert** block
that merchants place on the product page in the theme editor.

1. **Render.** Liquid outputs a small form plus a JSON map of `variant id → available`.
   `restockping.js` shows the form only while the selected variant is sold out.
   Shopify documents no variant-change event for app blocks, so the script follows the
   add-to-cart form's `id` input and the `?variant=` URL param.
2. **Submit.** The form POSTs to `/apps/restockping/subscriptions` on the shop's own
   domain. That's the same origin, so there's no CORS and nothing secret in the browser.
3. **Proxy.** Shopify forwards it to `/proxy/subscriptions` and adds `shop`,
   `logged_in_customer_id`, `path_prefix`, `timestamp` and `signature` to the query string.
4. **Verify** (`ShopifyAppProxyVerifier`). Hex HMAC-SHA256 over the sorted `key=value`
   query params, joined with no separator, compared in constant time. Timestamps older than
   5 minutes are rejected (replay). Only the query string is signed, so `shop` and
   `logged_in_customer_id` are read from `request.query_parameters` and never from
   `params`, which would fall back to the unsigned body for any key the query lacks.
   The verifier is pinned to Shopify's published worked examples.
5. **Abuse controls.** Rate limits per shopper (first `X-Forwarded-For` entry, because
   `remote_ip` resolves to Shopify's proxy) and per shop (a ceiling that can't be dodged by
   spoofing IPs). A honeypot field gets a fake success. New and repeat signups get the
   same response, so the form can't be used to check who's subscribed.
6. **Subscribe** (`SubscribeToRestock`). The GraphQL Admin API confirms the variant
   belongs to this shop, tracks inventory, and is sold out. That count becomes the
   `VariantStock` baseline the restock webhook needs. The subscription is upserted with
   `create_or_find_by` on a unique index, and re-armed if the shopper was already notified
   for an earlier restock.

Emails are encrypted with **deterministic** Active Record Encryption, so the unique index
and `customers/redact` lookups (`WHERE email = ?`) still work. `customers/redact` deletes a
customer's subscriptions by customer id or email.

## Security notes

- Access and refresh tokens are encrypted at rest (`encrypts :shopify_token, :refresh_token`).
- `id_token` and other token params are filtered from logs.
- A unique index on `shops.shopify_domain` makes concurrent first-install requests safe.
  The loser of the race hits `RecordNotUnique` and is handled, instead of creating a
  duplicate shop.
- Webhooks are verified before anything is parsed or stored, and the endpoint inherits
  from `ActionController::API` (no cookies, sessions or CSRF surface).
- Shopper emails are customer personal data: encrypted at rest (deterministic, for
  equality lookups), normalised before encryption, and deleted on `customers/redact`.
- Rails host authorization stays on for every route except `/proxy/*`. Proxied requests
  carry the shop's domain in `X-Forwarded-Host`, which would otherwise be rejected with a
  403. Those requests are authenticated by the proxy signature instead.
- Brakeman and bundler-audit run as part of the Rails toolchain.

## Local development

Developed in WSL2 (Ubuntu 24.04). Native Windows works poorly with Redis, native gems,
and the Shopify CLI's file watching.

**Prerequisites**

- Ruby 3.4 and Node 22 LTS (installed with [mise](https://mise.jdx.dev))
- PostgreSQL and Redis running locally
- [Shopify CLI](https://shopify.dev/docs/api/shopify-cli) (`npm install -g @shopify/cli`)
- A Shopify Partner account and a dev store

**Setup**

```sh
git clone https://github.com/Ushmayne/RestockPing.git
cd RestockPing
bundle install
bin/rails db:prepare
```

Encryption keys for Active Record Encryption go in your Rails credentials:

```sh
bin/rails db:encryption:init        # prints a key set
EDITOR=nano bin/rails credentials:edit   # paste it under active_record_encryption:
```

Link the project to your own app in the Shopify Dev Dashboard, then start it:

```sh
shopify app config link
shopify app dev --store <your-store>.myshopify.com
```

`shopify app dev` opens a Cloudflare tunnel, injects `SHOPIFY_API_KEY`,
`SHOPIFY_API_SECRET`, `HOST`, `SCOPES` and `PORT`, and starts Rails using
`shopify.web.toml`. Press `p` to open the app and install it on your store.

To add the signup form, open the theme editor with the block pre-selected:

```
https://<your-store>.myshopify.com/admin/themes/current/editor?template=product&addAppBlockId=<client_id>/notify_me&target=mainSection
```

Development notes:

- An app proxy's `prefix`/`subpath` apply to new installs. If the app was installed
  before `[app_proxy]` existed, reinstall it.
- Editing extension files while `shopify app dev` is running triggers "Updated dev
  preview". After that, webhook deliveries can stop until `shopify app dev` is restarted.

## Tests

```sh
bin/rails test
```

No test touches the network. WebMock blocks real HTTP, and the tests sign their own ID
tokens. Current coverage:

- `test/models/shop_test.rb`: session storage, tokens encrypted at rest, token refresh
  (still valid, expired, refresh token also expired), refresh inside `with_shopify_session`
- `test/integration/embedded_auth_test.rb`: first-install token exchange (asserts
  `expiring=1`), returning shop, expired stored token, forged signature, wrong audience,
  expired ID token, shop/token mismatch, and the bounce page for document loads with no token
- `test/services/shopify_webhook_verifier_test.rb`: valid signature, wrong secret,
  tampered or re-serialised body, missing header, secret rotation
- `test/models/variant_stock_test.rb`: baseline, 0 → n, oversold → n, n → m, sell-out,
  repeated cycles, stale readings
- `test/models/variant_stock_concurrency_test.rb`: two webhooks racing on one variant
  produce exactly one restock. Real threads, separate DB connections, and a hook that
  pauses one transaction between its read and its write.
- `test/models/webhook_delivery_test.rb`: process-once semantics and rollback on failure
- `test/controllers/webhooks_controller_test.rb`: end to end. Restock, multi-location
  totals, duplicates, bad or tampered HMAC, throttled API then a successful retry,
  token refresh, unknown shop or topic, uninstall and compliance topics

- `test/services/shopify_app_proxy_verifier_test.rb`: Shopify's published worked examples
  (logged-in and anonymous), tampered shop or customer, wrong secret, replayed timestamp,
  secret rotation
- `test/models/subscription_test.rb`: emails encrypted at rest, normalised before
  encryption, lookup by email, per-variant uniqueness, malformed emails
- `test/controllers/proxy_subscriptions_controller_test.rb`: signup end to end (including
  signup → inventory webhook → restock), idempotent repeats, re-arming, in-stock, unknown or
  untracked variants, unsigned, forged or replayed requests, identity smuggled in the body,
  honeypot, and both rate limits behind a modelled Shopify proxy and load balancer
- `test/integration/host_authorization_test.rb`: Rails' real host-authorization middleware
  with the `/proxy/*` exclusion. The test environment allows every host, so this is the
  only thing that would catch a regression.

The security-critical safeguards were mutation-checked: removing the row lock, the
stale-read guard, the `<= 0` rule, the proxy timestamp check, the honeypot, signed-only
identity params, or the shopper-IP rate-limit key each makes a test fail.

Linting and security scans:

```sh
bin/rubocop
bin/brakeman
```

## Project layout

```
app/controllers/authenticated_controller.rb  base class for admin requests (ID token auth)
app/controllers/home_controller.rb           embedded landing page, GraphQL shop query
app/controllers/webhooks_controller.rb       single webhook endpoint: verify, dedup, dispatch by topic
app/controllers/proxy_subscriptions_controller.rb  storefront signups via the app proxy
app/services/shopify_app_proxy_verifier.rb   app proxy signature + replay window
app/services/subscribe_to_restock.rb         variant check, stock baseline, idempotent signup
app/models/subscription.rb                   shopper waiting on a variant (encrypted email)
extensions/restock-notify/                   theme app extension: block, JS, CSS, locales
app/services/shopify_webhook_verifier.rb     HMAC-SHA256 check over the raw body
app/services/webhooks/                       one handler per topic (inventory, uninstall, compliance)
app/models/shop.rb                           installed shops + encrypted session storage
app/models/webhook_delivery.rb               processed webhook IDs, process_once
app/models/variant_stock.rb                  last known stock per variant, restock rule
app/models/restock_event.rb                  detected restocks (consumed in Phase 4)
config/initializers/shopify_app.rb           auth strategy, API version, token expiry
shopify.app.toml                             app config pushed to Shopify (scopes, install flow)
shopify.web.toml                             how the Shopify CLI starts Rails
```
