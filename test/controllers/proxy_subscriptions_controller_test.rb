require "test_helper"

# Storefront signup through the app proxy, end to end.
class ProxySubscriptionsControllerTest < ActionDispatch::IntegrationTest
  include ShopifyIdTokenHelper
  include ShopifyAppProxyHelper
  include ShopifyWebhookHelper

  VARIANT_ID = 777
  VARIANT_GID = "gid://shopify/ProductVariant/#{VARIANT_ID}"

  setup do
    @shop = shops(:regular_shop)
    Rails.application.config.x.rate_limit_store.clear
  end

  # Production path: shopper -> Shopify's proxy -> our load balancer -> Rails.
  # Shopify puts the shopper's IP in X-Forwarded-For, the load balancer appends
  # Shopify's IP, and the TCP peer is the load balancer (a private, trusted
  # address). Rails' remote_ip picks the rightmost untrusted entry, which is
  # Shopify's IP, identical for every shopper. That's why the controller reads
  # the first entry instead.
  SHOPIFY_PROXY_IP = "35.190.10.20"
  LOAD_BALANCER_IP = "10.0.0.5"

  def signup(email: "ana@example.com", variant_id: VARIANT_ID, query: nil, ip: "203.0.113.7", **form)
    query ||= app_proxy_query(shop: @shop.shopify_domain)
    post "/proxy/subscriptions?#{query}",
         params: { email: email, variant_id: variant_id }.merge(form),
         headers: { "X-Forwarded-For" => "#{ip}, #{SHOPIFY_PROXY_IP}", "Accept" => "application/json" },
         env: { "REMOTE_ADDR" => LOAD_BALANCER_IP }
  end

  def json = JSON.parse(response.body)

  # --- the happy path ------------------------------------------------------

  test "sold-out variant: subscribes the shopper and records the stock baseline" do
    stub_product_variant(shop: @shop.shopify_domain, variant_id: VARIANT_ID, quantity: 0)

    signup(email: " Ana@Example.com ")

    assert_response :ok
    assert_equal "subscribed", json["status"]
    subscription = @shop.subscriptions.sole
    assert_equal [ VARIANT_GID, "ana@example.com", "pending" ],
                 [ subscription.variant_gid, subscription.email, subscription.status ]
    assert_equal 0, VariantStock.find_by!(variant_gid: VARIANT_GID).quantity
  end

  test "signup then restock: the inventory webhook now detects 0 -> >0" do
    stub_product_variant(shop: @shop.shopify_domain, variant_id: VARIANT_ID, quantity: 0, inventory_item_id: 4242)
    signup
    stub_inventory_item(shop: @shop.shopify_domain, inventory_item_id: 4242,
                        variants: [ { id: VARIANT_GID, quantity: 3, product_id: "gid://shopify/Product/42" } ])

    body = { inventory_item_id: 4242, location_id: 1, available: 3 }.to_json
    post shopify_webhooks_path, params: body,
         headers: shopify_webhook_headers(body, topic: "inventory_levels/update", shop: @shop.shopify_domain)

    assert_response :ok
    assert_equal [ VARIANT_GID, 0, 3 ], RestockEvent.sole.then { |e| [ e.variant_gid, e.previous_quantity, e.new_quantity ] }
  end

  test "logged-in customer id comes from the signed query and is stored" do
    stub_product_variant(shop: @shop.shopify_domain, variant_id: VARIANT_ID, quantity: 0)

    signup(query: app_proxy_query(shop: @shop.shopify_domain, customer_id: 9001))

    assert_equal 9001, @shop.subscriptions.sole.customer_id
  end

  test "signing up twice keeps one row, and the response doesn't reveal it was a repeat" do
    stub_product_variant(shop: @shop.shopify_domain, variant_id: VARIANT_ID, quantity: 0)

    signup
    first = response.body
    signup(email: "ANA@example.com")

    assert_response :ok
    assert_equal first, response.body
    assert_equal 1, @shop.subscriptions.count
  end

  test "re-subscribing after a past notification re-arms the subscription" do
    stub_product_variant(shop: @shop.shopify_domain, variant_id: VARIANT_ID, quantity: 0)
    @shop.subscriptions.create!(email: "ana@example.com", variant_gid: VARIANT_GID, product_gid: "gid://shopify/Product/42",
                                status: "notified", notified_at: 1.day.ago)

    signup

    assert_equal [ "pending", nil ], @shop.subscriptions.sole.then { |s| [ s.status, s.notified_at ] }
  end

  # --- validation ----------------------------------------------------------

  test "invalid email: 422 without calling Shopify" do
    signup(email: "not-an-email")

    assert_response :unprocessable_content
    assert_equal "invalid_email", json["error"]
    assert_not_requested :post, "https://#{@shop.shopify_domain}/admin/api/2026-10/graphql.json"
  end

  test "variant already in stock: 422 in_stock, nothing stored" do
    stub_product_variant(shop: @shop.shopify_domain, variant_id: VARIANT_ID, quantity: 4)

    signup

    assert_response :unprocessable_content
    assert_equal "in_stock", json["error"]
    assert_equal 0, Subscription.count
  end

  test "variant id that isn't this shop's (API returns null): 422" do
    stub_product_variant(shop: @shop.shopify_domain, variant_id: VARIANT_ID, quantity: 0, exists: false)

    signup

    assert_response :unprocessable_content
    assert_equal 0, Subscription.count
  end

  test "untracked inventory: 422, we'd never see it restock" do
    stub_product_variant(shop: @shop.shopify_domain, variant_id: VARIANT_ID, quantity: 0, tracked: false)

    signup

    assert_response :unprocessable_content
  end

  test "non-numeric variant id: 422 without calling Shopify" do
    signup(variant_id: "1 OR 1=1")

    assert_response :unprocessable_content
    assert_not_requested :post, "https://#{@shop.shopify_domain}/admin/api/2026-10/graphql.json"
  end

  # --- authenticity --------------------------------------------------------

  test "unsigned request straight to our server: 401" do
    post "/proxy/subscriptions?shop=#{@shop.shopify_domain}", params: { email: "ana@example.com", variant_id: VARIANT_ID }

    assert_response :unauthorized
    assert_equal 0, Subscription.count
  end

  test "signature from a different secret: 401" do
    signup(query: app_proxy_query(shop: @shop.shopify_domain, secret: "attacker"))

    assert_response :unauthorized
  end

  test "replayed request with an old timestamp: 401" do
    signup(query: app_proxy_query(shop: @shop.shopify_domain, timestamp: 10.minutes.ago.to_i))

    assert_response :unauthorized
  end

  test "identity in the POST body is ignored: shop and customer come only from the signed query" do
    other_shop = shops(:expired_token_shop)
    stub_product_variant(shop: @shop.shopify_domain, variant_id: VARIANT_ID, quantity: 0)
    # A validly signed query that doesn't carry logged_in_customer_id. With plain
    # `params`, the unsigned body's value would fill that gap.
    query = app_proxy_query(shop: @shop.shopify_domain, customer_id: nil)

    signup(query: query, shop: other_shop.shopify_domain, logged_in_customer_id: "666")

    assert_response :ok
    assert_equal 1, @shop.subscriptions.count
    assert_equal 0, other_shop.subscriptions.count
    assert_nil @shop.subscriptions.sole.customer_id, "customer id must not come from the unsigned body"
  end

  test "signed request for a shop that isn't installed: 404" do
    signup(query: app_proxy_query(shop: "not-installed.myshopify.com"))

    assert_response :not_found
  end

  # --- abuse ---------------------------------------------------------------

  test "honeypot field filled: looks successful, stores nothing, no API call" do
    signup(website: "http://spam.example")

    assert_response :ok
    assert_equal "subscribed", json["status"]
    assert_equal 0, Subscription.count
    assert_not_requested :post, "https://#{@shop.shopify_domain}/admin/api/2026-10/graphql.json"
  end

  test "rate limit: the 6th signup from one shopper IP within a minute gets 429" do
    5.times { signup(email: "not-an-email") }
    assert_response :unprocessable_content

    signup(email: "not-an-email")
    assert_response :too_many_requests
    assert_equal "rate_limited", json["error"]

    # A different shopper (same Shopify proxy IP, different X-Forwarded-For) isn't affected.
    signup(email: "not-an-email", ip: "198.51.100.9")
    assert_response :unprocessable_content
  end

  test "per-shop ceiling: rotating shopper IPs doesn't get past 120 per minute" do
    120.times { |i| signup(email: "not-an-email", ip: "198.51.#{i / 250}.#{i % 250}") }
    assert_response :unprocessable_content

    signup(email: "not-an-email", ip: "192.0.2.1")
    assert_response :too_many_requests
  end
end
