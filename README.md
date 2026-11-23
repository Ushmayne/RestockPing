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
| 4 | Sidekiq jobs that send restock emails, with retries | Done |
| 5 | Order webhooks to attribute conversions to alerts | Done |
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

## How restock emails work

Sidekiq (Redis) runs the jobs through Active Job. A restock becomes emails in two steps.

1. **Enqueue after commit.** `RestockEvent` enqueues `NotifySubscribersJob` in
   `after_create_commit`. The event is created inside the webhook transaction, and Redis
   isn't part of it. A job pushed before `COMMIT` could run before the row is visible, or
   after a rollback.
2. **Fan-out** (`NotifySubscribersJob`). One GraphQL call snapshots what the email shows
   (store name, product, variant, image, link with `?variant=` preselected) onto the
   event, so 500 subscribers cost one API call. Then one transaction runs
   `SELECT … FOR UPDATE` on the variant's pending subscriptions, marks them notified, and
   inserts one `Notification` per subscriber. Two restocks of the same variant close
   together serialise on that lock. Postgres re-checks `status = 'pending'` for the
   second one, so each subscriber is claimed once. A unique index on
   `(subscription_id, restock_event_id)` makes a re-run insert nothing. Finally it enqueues
   one `SendRestockEmailJob` per notification that's still pending, in one bulk push.
3. **Send** (`SendRestockEmailJob`), inside `notification.with_lock`:
   - not pending any more → do nothing (a duplicate job)
   - variant sold out again → `canceled`, and the subscription is re-armed for the next restock
   - otherwise `deliver_now`, then mark `sent`

   A copy of the job running at the same time blocks on the lock, then sees `sent`.
   Delivery is **at-least-once**. If the process dies after the mail server accepted the
   message but before `COMMIT`, the retry sends a second copy. Marking `sent` before
   delivering would turn that into a lost email instead. Every copy carries the same
   `Message-ID`, which Gmail and other clients use to collapse duplicates.

**Retries.** Active Job owns them. Sidekiq is set to `retry: 0`, so the two retry systems
never multiply.

| Failure | Handling |
|---|---|
| Timeout, connection refused, SMTP 4xx | `retry_on`, polynomial backoff, 8 attempts (~80 min), then `failed` |
| SMTP 5xx (`550 no such user`) | `discard_on`: `failed` at once, no retry |
| Admin API throttled / 5xx (fan-out) | `retry_on`, 8 attempts |
| Record deleted (uninstall, `customers/redact`) | `discard_on ActiveJob::DeserializationError` |
| Anything else (bad credentials, a bug) | raised to Sidekiq's Dead set. The email stays `pending` |

**Lost jobs.** Open-source Sidekiq removes a job from Redis when a worker starts it, so a
killed process loses it. An enqueue can also fail when Redis is down right after a commit.
`RequeueStalledNotificationsJob` (`bin/rails restockping:requeue_stalled`, run from cron)
re-enqueues from the database:

- events with no `fanned_out_at` after 15 minutes
- notifications still pending after 2 hours (longer than the whole retry schedule)

It gives up on anything older than 3 days. Both jobs are idempotent, so a requeue that
wasn't needed is harmless.

**Rate limits** for storefront signups now live in Redis, shared by every process. If
Redis is down, they fail open (short timeouts, logged), so signups keep working.

## How conversions are attributed

`orders/paid` (needs `read_orders`) credits an order to the restock emails that led to it
(`AttributeOrder`). A **sent** notification gets the credit when:

1. **Same shopper.** The order's `customer.id` matches a logged-in signup, or its email
   matches a guest signup (normalised, matched as deterministic ciphertext).
2. **Same variant.** One of the order's line items is the variant the email was about.
3. **In the window.** The email went out at most **7 days** before the order was placed
   (`processed_at`), and not after it. An order placed by bank transfer before the email
   and paid after it doesn't count.

If a shopper was emailed more than once for a variant, the most recent email gets the
credit (last touch). Revenue is that variant's lines only: price × quantity minus its
discount allocations, in the shop currency, as `BigDecimal`. An email converts at most
once (unique `conversions.notification_id`, `INSERT … ON CONFLICT DO NOTHING`), so a
repeated `orders/paid` or a later second order can't count it twice.

`orders/cancelled` sets `cancelled_at` on that order's conversions. Test orders are
recorded with `test_order`. Phase 6 reports `Conversion.counted` (not cancelled, not test).

The payload has everything needed, so there's no API call. Matching runs in the same
transaction as the webhook's dedup row.

**Protected customer data.** Orders are protected customer data. The `Conversion` row
stores no customer fields (no email, name or address). The link to the shopper goes through
notification → subscription, so `customers/redact` erases the conversion along with the
subscription. Shopify only delivers `orders/*` once protected customer data access is
configured. Without Level 2 (email) access the order's email is redacted, and only
logged-in shoppers (customer id) can be matched.

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

Emails need two more processes, each in its own terminal:

```sh
shopify app env pull   # once: writes the app credentials to .env (gitignored)
bin/worker             # Sidekiq, with .env loaded
mailpit                # local SMTP on :1025, inbox at http://localhost:8025
```

The CLI gives credentials only to the web process, so `bin/worker` loads them from `.env`.
Development sends real SMTP to [Mailpit](https://mailpit.axllent.org). Stop Mailpit and
you can watch `SendRestockEmailJob` retry. Production reads `SMTP_ADDRESS`, `SMTP_PORT`,
`SMTP_USERNAME`, `SMTP_PASSWORD`, `MAIL_FROM` (a bare address on a domain with SPF/DKIM)
and `REDIS_URL`.

To add the signup form, open the theme editor with the block pre-selected:

```
https://<your-store>.myshopify.com/admin/themes/current/editor?template=product&addAppBlockId=<client_id>/notify_me&target=mainSection
```

For conversion tracking, turn on protected customer data access first: Dev Dashboard →
your app → Settings → Access requests → Protected customer data → Manage. Select
customer data and the email field, give reasons, complete the data protection details,
and save. Development stores need no review. Then restart `shopify app dev`, so the
`read_orders` scope and the `orders/*` subscriptions are pushed, and open the app in the
admin to approve the new scope.

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

- `test/jobs/notify_subscribers_job_test.rb`: claims only that variant's pending
  subscribers, the email snapshot (including single-variant products), idempotent re-runs,
  a later restock not re-claiming anyone, deleted variant, throttled API
- `test/jobs/notify_subscribers_concurrency_test.rb`: two fan-outs for the same variant at
  once claim each subscriber exactly once (real threads, paused mid-transaction)
- `test/jobs/send_restock_email_job_test.rb`: sent, already sent, sold out again (canceled
  and re-armed), 4xx and connection refused retried with backoff, retries exhausted →
  failed, 550 → failed with no retry, unexpected error → Sidekiq, subscriber erased
- `test/jobs/send_restock_email_concurrency_test.rb`: two copies of one send job at once
  send one email
- `test/jobs/requeue_stalled_notifications_job_test.rb`: what the sweeper picks up, and
  what it leaves alone
- `test/mailers/restock_mailer_test.rb`: sender, reply-to, links, stable Message-ID, escaping
- `test/models/restock_event_test.rb`: enqueue after commit, nothing on rollback

- `test/services/attribute_order_test.rb`: match by email (any case) or customer id,
  strangers, no identity, other shops, other variants, revenue (quantity, discounts, custom
  lines), two variants in one order, both edges of the 7-day window, order placed before
  the email, unsent emails, last touch, replays, second orders, test and cancelled orders,
  no customer columns
- `test/controllers/webhooks_controller_test.rb` also covers `orders/paid` (no API call,
  retry dedup, bad HMAC), `orders/cancelled` (only that order), and `customers/redact`
  erasing conversions

The jobs tests use Active Job's test adapter, so the suite needs neither Redis nor a
mail server.

The security-critical safeguards were mutation-checked: removing the row lock, the
stale-read guard, the `<= 0` rule, the proxy timestamp check, the honeypot, signed-only
identity params, or the shopper-IP rate-limit key each makes a test fail. So do the Phase 4
ones: either `FOR UPDATE`, the pending check, the sold-out check, the exhaustion and 550
handlers, the snapshot-once guard, and the sweeper's status and age filters. And the
Phase 5 ones: either edge of the window, shop scoping, the variant filter, either identity
match, last touch, discounts, quantity, `ON CONFLICT`, and the cancel's order filter.

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
app/models/restock_event.rb                  detected restocks + email snapshot, enqueues the fan-out
app/models/notification.rb                   one email to one subscriber for one restock
app/jobs/application_job.rb                  retry policy: Active Job retries, Sidekiq retry: 0
app/jobs/notify_subscribers_job.rb           fan-out: snapshot, claim subscribers, enqueue sends
app/jobs/send_restock_email_job.rb           locked, idempotent send with retry rules
app/jobs/requeue_stalled_notifications_job.rb  re-enqueues lost jobs from the database
app/mailers/restock_mailer.rb                the back-in-stock email
app/services/attribute_order.rb              which restock emails a paid order is credited to
app/models/conversion.rb                     a paid order credited to one email (no customer data)
config/initializers/rate_limit.rb            Redis-backed rate-limit counters (fail open)
bin/worker                                   Sidekiq for development, loads .env
config/initializers/shopify_app.rb           auth strategy, API version, token expiry
shopify.app.toml                             app config pushed to Shopify (scopes, install flow)
shopify.web.toml                             how the Shopify CLI starts Rails
```
