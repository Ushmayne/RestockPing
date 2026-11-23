require "test_helper"

# Full request path: HMAC check -> dedup -> GraphQL re-fetch -> restock detection.
class WebhooksControllerTest < ActionDispatch::IntegrationTest
  include ShopifyIdTokenHelper
  include ShopifyWebhookHelper
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper
  include RestockEmailHelper
  include ShopifyOrderHelper

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

  test "end to end: restock webhook -> fan-out job -> email in the subscriber's inbox" do
    baseline!(0)
    @shop.subscriptions.create!(variant_gid: VARIANT, product_gid: PRODUCT, email: "ana@example.com")
    stub_inventory_item(shop: @shop.shopify_domain, inventory_item_id: ITEM_ID,
                        variants: [ { id: VARIANT, quantity: 5, product_id: PRODUCT } ])
    stub_email_details(shop: @shop)

    # The webhook only enqueues. Nothing is sent inside the request.
    assert_no_emails { deliver(inventory_body) }
    assert_response :ok
    assert_enqueued_with(job: NotifySubscribersJob)

    # Fan-out runs and enqueues the send. Then the send runs.
    perform_enqueued_jobs(only: NotifySubscribersJob)
    assert_emails(1) { perform_enqueued_jobs(only: SendRestockEmailJob) }
    assert_equal [ "ana@example.com" ], ActionMailer::Base.deliveries.last.to
    assert_equal "sent", Notification.sole.status
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

  # --- conversions ---------------------------------------------------------

  def sent_email!(email: "ana@example.com")
    pending_notification!(shop: @shop, email: email).tap { |n| n.update!(status: "sent", sent_at: 1.hour.ago) }
  end

  def paid_order(**options)
    order_payload(email: "ana@example.com", line_items: [ { variant_id: 4242, price: "80.00" } ], **options)
  end

  test "orders/paid from a shopper we emailed: one conversion, no API call" do
    notification = sent_email!

    deliver(paid_order.to_json, topic: "orders/paid")

    assert_response :ok
    assert_equal notification, Conversion.sole.notification
    assert_equal BigDecimal("80"), Conversion.sole.revenue
    assert_not_requested :post, graphql_url
  end

  test "orders/paid delivered twice (Shopify retry, same webhook id): one conversion" do
    sent_email!
    body = paid_order.to_json
    webhook_id = SecureRandom.uuid

    2.times { deliver(body, topic: "orders/paid", webhook_id: webhook_id) }

    assert_response :ok
    assert_equal 1, Conversion.count
  end

  test "orders/paid with a bad HMAC: 401, nothing recorded" do
    sent_email!

    deliver(paid_order.to_json, topic: "orders/paid", hmac: "bm90LXRoZS1yaWdodC1kaWdlc3Q=")

    assert_response :unauthorized
    assert_equal 0, Conversion.count
  end

  test "orders/cancelled marks that order's conversions cancelled, and only that order's" do
    sent_email!(email: "ana@example.com")
    sent_email!(email: "ben@example.com")
    deliver(paid_order(id: 1).to_json, topic: "orders/paid")
    deliver(paid_order(id: 2, email: "ben@example.com").to_json, topic: "orders/paid")

    deliver({ id: 1, cancelled_at: Time.current.iso8601, cancel_reason: "customer" }.to_json, topic: "orders/cancelled")

    assert_response :ok
    assert Conversion.find_by!(order_id: 1).cancelled_at.present?
    assert_nil Conversion.find_by!(order_id: 2).cancelled_at
    assert_equal [ 2 ], Conversion.counted.pluck(:order_id)
  end

  test "orders/cancelled for an order we never attributed: 200, nothing to do" do
    deliver({ id: 12_345, cancelled_at: Time.current.iso8601 }.to_json, topic: "orders/cancelled")

    assert_response :ok
  end

  test "customers/redact also erases the shopper's conversions (through their subscription)" do
    sent_email!
    deliver(paid_order.to_json, topic: "orders/paid")

    deliver({ shop_domain: @shop.shopify_domain, customer: { email: "ana@example.com" } }.to_json,
            topic: "customers/redact")

    assert_equal 0, Conversion.count
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
