require "test_helper"

# Full request path: HMAC check -> dedup -> GraphQL re-fetch -> restock detection.
class WebhooksControllerTest < ActionDispatch::IntegrationTest
  include ShopifyIdTokenHelper
  include ShopifyWebhookHelper

  ITEM_ID = 808_950_810
  VARIANT = "gid://shopify/ProductVariant/4242"
  PRODUCT = "gid://shopify/Product/42"

  setup { @shop = shops(:regular_shop) }

  def inventory_body(available: 5)
    {
      inventory_item_id: ITEM_ID, location_id: 24_826_418, available: available,
      updated_at: Time.current.iso8601,
      admin_graphql_api_id: "gid://shopify/InventoryLevel/24826418?inventory_item_id=#{ITEM_ID}"
    }.to_json
  end

  def deliver(body, topic: "inventory_levels/update", shop: @shop.shopify_domain, **header_opts)
    post shopify_webhooks_path, params: body, headers: shopify_webhook_headers(body, topic: topic, shop: shop, **header_opts)
  end

  def baseline!(quantity)
    VariantStock.create!(shop: @shop, variant_gid: VARIANT, product_gid: PRODUCT,
                         inventory_item_gid: "gid://shopify/InventoryItem/#{ITEM_ID}",
                         quantity: quantity, observed_at: 1.hour.ago)
  end

  def graphql_url(shop = @shop) = "https://#{shop.shopify_domain}/admin/api/2026-10/graphql.json"

  # --- restock detection ---------------------------------------------------

  test "variant at 0 comes back: 200 and one RestockEvent" do
    baseline!(0)
    stub_inventory_item(shop: @shop.shopify_domain, inventory_item_id: ITEM_ID,
                        variants: [ { id: VARIANT, quantity: 5, product_id: PRODUCT } ])

    deliver(inventory_body)

    assert_response :ok
    event = RestockEvent.sole
    assert_equal [ VARIANT, 0, 5 ], [ event.variant_gid, event.previous_quantity, event.new_quantity ]
    assert_equal 5, VariantStock.find_by!(variant_gid: VARIANT).quantity
  end

  test "uses the API's total, not the payload's per-location number" do
    baseline!(0)
    # Payload says 0 available at this location, but another location got stock.
    stub_inventory_item(shop: @shop.shopify_domain, inventory_item_id: ITEM_ID,
                        variants: [ { id: VARIANT, quantity: 12, product_id: PRODUCT } ])

    deliver(inventory_body(available: 0))

    assert_equal 12, RestockEvent.sole.new_quantity
  end

  test "first webhook for a variant stores a baseline only" do
    stub_inventory_item(shop: @shop.shopify_domain, inventory_item_id: ITEM_ID,
                        variants: [ { id: VARIANT, quantity: 5, product_id: PRODUCT } ])

    deliver(inventory_body)

    assert_response :ok
    assert_equal 5, VariantStock.find_by!(variant_gid: VARIANT).quantity
    assert_equal 0, RestockEvent.count
  end

  test "untracked inventory: delivery recorded, nothing stored" do
    stub_inventory_item(shop: @shop.shopify_domain, inventory_item_id: ITEM_ID, tracked: false,
                        variants: [ { id: VARIANT, quantity: 0, product_id: PRODUCT } ])

    deliver(inventory_body)

    assert_response :ok
    assert_equal 1, WebhookDelivery.count
    assert_equal 0, VariantStock.count
  end

  # --- deduplication -------------------------------------------------------

  test "the same delivery twice (Shopify retry) is processed once" do
    baseline!(0)
    stub_inventory_item(shop: @shop.shopify_domain, inventory_item_id: ITEM_ID,
                        variants: [ { id: VARIANT, quantity: 5, product_id: PRODUCT } ])

    2.times { deliver(inventory_body, webhook_id: "same-delivery-id") }

    assert_response :ok
    assert_equal 1, RestockEvent.count
    assert_requested :post, graphql_url, times: 1
  end

  # --- verification --------------------------------------------------------

  test "invalid HMAC: 401, no API call, nothing recorded" do
    deliver(inventory_body, hmac: shopify_hmac(inventory_body, secret: "forged"))

    assert_response :unauthorized
    assert_not_requested :post, graphql_url
    assert_equal 0, WebhookDelivery.count
  end

  test "body altered after signing: 401" do
    body = inventory_body
    headers = shopify_webhook_headers(body, topic: "inventory_levels/update", shop: @shop.shopify_domain)

    post shopify_webhooks_path, params: body.sub('"available":5', '"available":500'), headers: headers

    assert_response :unauthorized
  end

  test "missing X-Shopify-Webhook-Id: 400" do
    deliver(inventory_body, webhook_id: "")

    assert_response :bad_request
  end

  # --- failure handling ----------------------------------------------------

  test "Shopify API throttled: 500, delivery NOT recorded, so the retry succeeds" do
    baseline!(0)
    throttled = { errors: [ { message: "Throttled", extensions: { code: "THROTTLED" } } ] }
    stub_inventory_item(shop: @shop.shopify_domain, inventory_item_id: ITEM_ID, variants: [], body: throttled)

    assert_raises(Webhooks::InventoryLevelsUpdate::GraphqlError) do
      deliver(inventory_body, webhook_id: "retry-me")
    end
    assert_equal 0, WebhookDelivery.count

    # Shopify retries the same delivery a bit later, when the API answers normally.
    WebMock.reset!
    stub_inventory_item(shop: @shop.shopify_domain, inventory_item_id: ITEM_ID,
                        variants: [ { id: VARIANT, quantity: 5, product_id: PRODUCT } ])
    deliver(inventory_body, webhook_id: "retry-me")

    assert_response :ok
    assert_equal 1, RestockEvent.count
  end

  test "expired access token is refreshed before the GraphQL call" do
    shop = shops(:expired_token_shop)
    stub_shopify_token_endpoint(shop: shop.shopify_domain, access_token: "shpat_refreshed_for_webhook")
    stub_inventory_item(shop: shop.shopify_domain, inventory_item_id: ITEM_ID,
                        variants: [ { id: VARIANT, quantity: 5, product_id: PRODUCT } ])

    deliver(inventory_body, shop: shop.shopify_domain)

    assert_response :ok
    assert_requested(:post, graphql_url(shop)) do |req|
      req.headers["X-Shopify-Access-Token"] == "shpat_refreshed_for_webhook"
    end
  end

  test "webhook for a shop we don't know (already uninstalled): 200, ignored" do
    deliver(inventory_body, shop: "gone-shop.myshopify.com")

    assert_response :ok
    assert_not_requested :post, "https://gone-shop.myshopify.com/admin/api/2026-10/graphql.json"
  end

  test "unknown topic: 200 so Shopify stops retrying" do
    deliver("{}", topic: "products/create")

    assert_response :ok
  end

  # --- lifecycle and compliance --------------------------------------------

  test "app/uninstalled deletes the shop, its tokens and its data" do
    baseline!(3)

    deliver({ id: 1, domain: @shop.shopify_domain }.to_json, topic: "app/uninstalled")

    assert_response :ok
    refute Shop.exists?(@shop.id)
    assert_equal 0, VariantStock.where(shop_id: @shop.id).count
  end

  test "shop/redact erases the shop's data" do
    deliver({ shop_id: 1, shop_domain: @shop.shopify_domain }.to_json, topic: "shop/redact")

    assert_response :ok
    refute Shop.exists?(@shop.id)
  end

  test "customers/data_request and customers/redact are verified and acknowledged" do
    %w[customers/data_request customers/redact].each do |topic|
      deliver({ shop_domain: @shop.shopify_domain, customer: { id: 1, email: "x@example.com" } }.to_json,
              topic: topic)
      assert_response :ok, topic
    end
    assert Shop.exists?(@shop.id), "customer requests must not delete the shop"
  end

  test "customers/redact deletes that customer's subscriptions by id or email, and nobody else's" do
    sub = ->(email, customer_id = nil) do
      @shop.subscriptions.create!(email: email, customer_id: customer_id, variant_gid: "gid://shopify/ProductVariant/#{SecureRandom.hex(3)}",
                                  product_gid: PRODUCT)
    end
    sub.call("ana@example.com")              # guest signup, matched by email
    sub.call("ana.work@example.com", 555)    # logged-in signup, matched by customer id
    keep = sub.call("bob@example.com", 777)

    body = { shop_domain: @shop.shopify_domain, customer: { id: 555, email: "ANA@example.com" } }.to_json
    deliver(body, topic: "customers/redact")

    assert_response :ok
    assert_equal [ keep.id ], @shop.subscriptions.pluck(:id)
  end

  test "compliance webhook with a bad HMAC gets 401 (required by Shopify's app review)" do
    body = { shop_domain: @shop.shopify_domain }.to_json

    deliver(body, topic: "shop/redact", hmac: "bm90LXRoZS1yaWdodC1kaWdlc3Q=")

    assert_response :unauthorized
    assert Shop.exists?(@shop.id)
  end
end
