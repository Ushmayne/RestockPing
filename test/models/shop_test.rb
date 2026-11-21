require "test_helper"

class ShopTest < ActiveSupport::TestCase
  include ShopifyIdTokenHelper

  test "store persists every field of an expiring offline session" do
    session = ShopifyAPI::Auth::Session.new(
      shop: "new-shop.myshopify.com",
      access_token: "shpat_new",
      scope: "read_products,read_inventory",
      expires: 1.hour.from_now,
      refresh_token: "shprt_new",
      refresh_token_expires: 90.days.from_now,
    )

    Shop.store(session)

    shop = Shop.find_by!(shopify_domain: "new-shop.myshopify.com")
    assert_equal "shpat_new", shop.shopify_token
    assert_equal "shprt_new", shop.refresh_token
    assert_equal "read_products,read_inventory", shop.access_scopes
    assert_in_delta 1.hour.from_now, shop.expires_at, 5.seconds
    assert_in_delta 90.days.from_now, shop.refresh_token_expires_at, 5.seconds
  end

  test "store updates the existing row on reinstall instead of creating a duplicate" do
    session = ShopifyAPI::Auth::Session.new(shop: shops(:regular_shop).shopify_domain, access_token: "shpat_rotated")

    assert_no_difference -> { Shop.count } do
      Shop.store(session)
    end
    assert_equal "shpat_rotated", shops(:regular_shop).reload.shopify_token
  end

  test "access and refresh tokens are encrypted at rest" do
    shop = shops(:regular_shop)
    raw = Shop.connection.select_one(
      "SELECT shopify_token, refresh_token FROM shops WHERE id = #{shop.id}",
    )

    refute_equal "valid-access-token", raw["shopify_token"]
    refute_equal "valid-refresh-token", raw["refresh_token"]
    refute_includes raw["shopify_token"], "valid-access-token"
    assert_equal "valid-access-token", shop.shopify_token # decrypts transparently
  end

  test "refresh_token_if_expired! does nothing while the access token is still valid" do
    # WebMock raises on any unstubbed request, so a refresh attempt would fail this test.
    shops(:regular_shop).refresh_token_if_expired!

    assert_equal "valid-access-token", shops(:regular_shop).reload.shopify_token
  end

  test "refresh_token_if_expired! swaps in new tokens when the access token has expired" do
    shop = shops(:expired_token_shop)
    stub = stub_shopify_token_endpoint(shop: shop.shopify_domain, access_token: "shpat_refreshed",
                                       refresh_token: "shprt_rotated")

    shop.refresh_token_if_expired!

    assert_requested stub
    assert_requested(:post, "https://#{shop.shopify_domain}/admin/oauth/access_token") do |req|
      body = JSON.parse(req.body)
      body["grant_type"] == "refresh_token" && body["refresh_token"] == "still-valid-refresh-token"
    end
    shop.reload
    assert_equal "shpat_refreshed", shop.shopify_token
    assert_equal "shprt_rotated", shop.refresh_token # refresh tokens rotate on every use
    assert_operator shop.expires_at, :>, 50.minutes.from_now
  end

  test "refresh_token_if_expired! raises when the refresh token itself has expired" do
    assert_raises(ShopifyApp::RefreshTokenExpiredError) do
      shops(:dead_refresh_shop).refresh_token_if_expired!
    end
  end

  test "with_shopify_session refreshes an expired token before running the block" do
    shop = shops(:expired_token_shop)
    stub_shopify_token_endpoint(shop: shop.shopify_domain, access_token: "shpat_for_job")

    token_seen_inside_block = nil
    shop.with_shopify_session do
      token_seen_inside_block = ShopifyAPI::Context.active_session.access_token
    end

    # This is the path background jobs (Phase 4) take.
    assert_equal "shpat_for_job", token_seen_inside_block
  end
end
