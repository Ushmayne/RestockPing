# frozen_string_literal: true

# During `shopify app dev`, the Shopify CLI injects SHOPIFY_API_KEY, SHOPIFY_API_SECRET,
# HOST and SCOPES into the environment, using shopify.app.toml and the Dev Dashboard.
# In production you set these yourself on the host.
ShopifyApp.configure do |config|
  config.application_name = "RestockPing"

  # shopify.app.toml ([access_scopes]) is the source of truth: Shopify's managed install
  # grants exactly those. This value is what the gem compares a stored token's scopes
  # against, so a scope added in the toml forces a fresh token exchange.
  config.scope = ENV.fetch("SCOPES", "read_products,read_inventory,write_app_proxy")
  config.reauth_on_access_scope_changes = true

  # Embedded in the Shopify admin, authenticated with ID tokens + token exchange
  # (Shopify managed installation) instead of the legacy OAuth redirect flow.
  config.embedded_app = true
  config.new_embedded_auth_strategy = true

  # Offline tokens expire after 1 hour. When an admin request arrives with an expired
  # stored token, do a fresh token exchange instead of failing on the API call.
  config.check_session_expiry_date = true

  config.api_version = "2026-10"
  config.shop_session_repository = "Shop"
  config.after_authenticate_job = false
  config.log_level = :info

  # Webhook subscriptions get declared in shopify.app.toml in Phase 2. Leaving this
  # empty stops the gem from registering subscriptions through the API after install.
  config.webhooks = []

  config.api_key = ENV.fetch("SHOPIFY_API_KEY", "").presence
  config.secret = ENV.fetch("SHOPIFY_API_SECRET", "").presence
  # Previous secret, used while rotating the client secret so in-flight tokens still verify.
  config.old_secret = ENV.fetch("SHOPIFY_API_SECRET_OLD", "")

  if defined? Rails::Server
    raise("Missing SHOPIFY_API_KEY. Run the app with `shopify app dev`.") unless config.api_key
    raise("Missing SHOPIFY_API_SECRET. Run the app with `shopify app dev`.") unless config.secret
  end
end

Rails.application.config.after_initialize do
  if ShopifyApp.configuration.api_key.present? && ShopifyApp.configuration.secret.present?
    ShopifyAPI::Context.setup(
      api_key: ShopifyApp.configuration.api_key,
      api_secret_key: ShopifyApp.configuration.secret,
      old_api_secret_key: ShopifyApp.configuration.old_secret.presence,
      api_version: ShopifyApp.configuration.api_version,
      # The app's public URL, which only the OAuth redirect flow uses. The CLI sets
      # HOST for the web process, but not for Sidekiq or `rails runner`. Without a
      # fallback, ShopifyAPI::Context.setup? raises (T.must(nil)) on every token
      # refresh in a background job.
      host: ENV.fetch("HOST", "https://localhost"),
      scope: ShopifyApp.configuration.scope,
      is_private: false,
      is_embedded: ShopifyApp.configuration.embedded_app,
      # Sends `expiring=1` on token exchange, so Shopify returns a 1-hour access token
      # plus a 90-day refresh token. Required for new apps.
      expiring_offline_access_tokens: true,
      # GraphQL only. The REST Admin API is legacy, and this makes any REST call raise.
      rest_disabled: true,
      log_level: :info,
      logger: Rails.logger,
      user_agent_prefix: "RestockPing ShopifyApp/#{ShopifyApp::VERSION}",
    )
  end
end
