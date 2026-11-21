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
| 2 | `inventory_levels/update` webhook: HMAC verification, dedup, 0 → >0 restock detection | Planned |
| 3 | Theme app extension (signup form) + app proxy endpoint | Planned |
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

## Security notes

- Access and refresh tokens are encrypted at rest (`encrypts :shopify_token, :refresh_token`).
- `id_token` and other token params are filtered from logs.
- A unique index on `shops.shopify_domain` makes concurrent first-install requests safe.
  The loser of the race hits `RecordNotUnique` and is handled, instead of creating a
  duplicate shop.
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

Linting and security scans:

```sh
bin/rubocop
bin/brakeman
```

## Project layout

```
app/controllers/authenticated_controller.rb  base class for admin requests (ID token auth)
app/controllers/home_controller.rb           embedded landing page, GraphQL shop query
app/models/shop.rb                           installed shops + encrypted session storage
config/initializers/shopify_app.rb           auth strategy, API version, token expiry
shopify.app.toml                             app config pushed to Shopify (scopes, install flow)
shopify.web.toml                             how the Shopify CLI starts Rails
```
