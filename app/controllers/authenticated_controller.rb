# frozen_string_literal: true

# Base class for every admin-facing controller that touches shop data.
#
# EnsureHasSession (with new_embedded_auth_strategy) adds an around_action that:
#   1. reads the ID token from `Authorization: Bearer ...`, or from the `id_token` URL param
#      on the first document load inside the admin
#   2. verifies the JWT (signature with our client secret, expiry, audience)
#   3. loads the Shop for that token, or runs token exchange if there's none or it's expired
#   4. rejects the request (401) if a `shop` param disagrees with the token's shop
#   5. activates the session, so `current_shopify_session` and API clients work in the action
# A missing or invalid token gets a 401 with X-Shopify-Retry-Invalid-Session-Request
# (fetch/XHR) or a redirect to the bounce page (document loads), so App Bridge can retry.
class AuthenticatedController < ApplicationController
  include ShopifyApp::EnsureHasSession
end
