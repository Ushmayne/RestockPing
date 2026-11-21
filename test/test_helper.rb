ENV["RAILS_ENV"] ||= "test"
# Fake app credentials so ShopifyAPI::Context is configured in tests (see the initializer).
ENV["SHOPIFY_API_KEY"] ||= "test-api-key"
ENV["SHOPIFY_API_SECRET"] ||= "test-api-secret"
ENV["HOST"] ||= "https://restockping.test"
ENV["SCOPES"] ||= "read_products,read_inventory"

require_relative "../config/environment"
require "rails/test_help"
# Blocks all real HTTP. Every Shopify call in a test must be stubbed explicitly.
require "webmock/minitest"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all
  end
end

# Builds the JWT that App Bridge would hand our frontend inside the Shopify admin.
# Shopify signs it with HS256 using our client secret; we sign the same way in tests.
module ShopifyIdTokenHelper
  def shopify_id_token(shop:, secret: ENV.fetch("SHOPIFY_API_SECRET"), aud: ENV.fetch("SHOPIFY_API_KEY"),
                       expires_in: 60)
    now = Time.now.to_i
    payload = {
      iss: "https://#{shop}/admin",
      dest: "https://#{shop}",
      aud: aud,
      sub: "42",
      exp: now + expires_in,
      nbf: now - 5,
      iat: now - 5,
      jti: SecureRandom.uuid,
      sid: SecureRandom.hex(8)
    }
    JWT.encode(payload, secret, "HS256")
  end

  # Stubs Shopify's token endpoint (used by both token exchange and refresh).
  def stub_shopify_token_endpoint(shop:, access_token:, refresh_token: "refresh-#{SecureRandom.hex(4)}")
    stub_request(:post, "https://#{shop}/admin/oauth/access_token").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: {
        access_token: access_token,
        scope: "read_products,read_inventory",
        expires_in: 3600,
        refresh_token: refresh_token,
        refresh_token_expires_in: 7_776_000 # 90 days
      }.to_json,
    )
  end

  def stub_shop_graphql(shop:, name: "Test Store")
    stub_request(:post, "https://#{shop}/admin/api/2026-10/graphql.json").to_return(
      status: 200,
      headers: { "Content-Type" => "application/json" },
      body: { data: { shop: { name: name, myshopifyDomain: shop } } }.to_json,
    )
  end
end
