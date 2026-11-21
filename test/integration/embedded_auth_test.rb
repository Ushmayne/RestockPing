require "test_helper"

# End-to-end checks of the embedded auth flow through HomeController
# (AuthenticatedController -> ShopifyApp::EnsureHasSession -> token exchange).
class EmbeddedAuthTest < ActionDispatch::IntegrationTest
  include ShopifyIdTokenHelper

  test "valid ID token for an installed shop: uses the stored token, no exchange" do
    shop = shops(:regular_shop)
    stub_shop_graphql(shop: shop.shopify_domain, name: "Regular Shop")

    get root_path, headers: bearer(shopify_id_token(shop: shop.shopify_domain))

    assert_response :ok
    assert_includes response.body, "Regular Shop"
    assert_requested(:post, "https://#{shop.shopify_domain}/admin/api/2026-10/graphql.json") do |req|
      req.headers["X-Shopify-Access-Token"] == "valid-access-token"
    end
    assert_not_requested :post, "https://#{shop.shopify_domain}/admin/oauth/access_token"
  end

  test "first load after install: exchanges the ID token and stores an expiring offline token" do
    domain = "brand-new.myshopify.com"
    stub_shopify_token_endpoint(shop: domain, access_token: "shpat_fresh", refresh_token: "shprt_fresh")
    stub_shop_graphql(shop: domain, name: "Brand New")

    # The first document load inside the admin carries the ID token as a URL param.
    get root_path, params: { id_token: shopify_id_token(shop: domain), shop: domain, embedded: "1" }

    assert_response :ok
    assert_requested(:post, "https://#{domain}/admin/oauth/access_token") do |req|
      body = JSON.parse(req.body)
      body["grant_type"] == "urn:ietf:params:oauth:grant-type:token-exchange" &&
        body["requested_token_type"] == "urn:shopify:params:oauth:token-type:offline-access-token" &&
        body["expiring"] == 1
    end
    shop = Shop.find_by!(shopify_domain: domain)
    assert_equal "shpat_fresh", shop.shopify_token
    assert_equal "shprt_fresh", shop.refresh_token
    assert_not_nil shop.expires_at
  end

  test "stored token has expired: a fresh token exchange runs before the action" do
    shop = shops(:expired_token_shop)
    exchange = stub_shopify_token_endpoint(shop: shop.shopify_domain, access_token: "shpat_reexchanged")
    stub_shop_graphql(shop: shop.shopify_domain)

    get root_path, headers: bearer(shopify_id_token(shop: shop.shopify_domain))

    assert_response :ok
    assert_requested exchange
    assert_equal "shpat_reexchanged", shop.reload.shopify_token
  end

  test "ID token signed with the wrong secret: 401 plus the App Bridge retry header" do
    forged = shopify_id_token(shop: shops(:regular_shop).shopify_domain, secret: "not-our-secret")

    get root_path, headers: bearer(forged)

    assert_response :unauthorized
    # App Bridge sees this header, fetches a fresh ID token and retries the request once.
    assert_equal "1", response.headers["X-Shopify-Retry-Invalid-Session-Request"].to_s
  end

  test "ID token issued for a different app (aud mismatch) is rejected" do
    other_app = shopify_id_token(shop: shops(:regular_shop).shopify_domain, aud: "someone-elses-client-id")

    get root_path, headers: bearer(other_app)

    assert_response :unauthorized
  end

  test "expired ID token is rejected" do
    stale = shopify_id_token(shop: shops(:regular_shop).shopify_domain, expires_in: -120)

    get root_path, headers: bearer(stale)

    assert_response :unauthorized
  end

  test "shop param that disagrees with the token's shop is rejected (tenant confusion)" do
    token = shopify_id_token(shop: shops(:regular_shop).shopify_domain)

    get root_path, params: { shop: shops(:expired_token_shop).shopify_domain }, headers: bearer(token)

    assert_response :unauthorized
  end

  test "embedded document load with no ID token goes to the bounce page to fetch one" do
    domain = shops(:regular_shop).shopify_domain

    get root_path, params: { shop: domain, embedded: "1", host: Base64.strict_encode64("#{domain}/admin") }

    assert_response :redirect
    assert_match %r{/patch_shopify_id_token\?}, response.location
    assert_includes response.location, "shopify-reload"
  end

  private

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end
end
