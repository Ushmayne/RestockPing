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

# Builds app proxy query strings the way Shopify signs them. Checked against
# Shopify's published examples in ShopifyAppProxyVerifierTest, so this helper
# isn't simply agreeing with our own implementation.
module ShopifyAppProxyHelper
  # customer_id: nil leaves logged_in_customer_id out of the query entirely.
  def app_proxy_query(shop:, customer_id: "", timestamp: Time.current.to_i,
                      secret: ENV.fetch("SHOPIFY_API_SECRET"), extra: {})
    params = {
      "shop" => shop,
      "logged_in_customer_id" => customer_id&.to_s,
      "path_prefix" => "/apps/restockping",
      "timestamp" => timestamp.to_s
    }.compact.merge(extra)
    message = params.map { |key, value| "#{key}=#{Array(value).join(",")}" }.sort.join
    Rack::Utils.build_query(params.merge("signature" => OpenSSL::HMAC.hexdigest("SHA256", secret, message)))
  end

  # The Admin API's answer to SubscribeToRestock::QUERY.
  def stub_product_variant(shop:, variant_id:, quantity:, tracked: true, exists: true,
                           product_id: 42, inventory_item_id: 4242)
    gid = "gid://shopify/ProductVariant/#{variant_id}"
    variant = exists && {
      id: gid, inventoryQuantity: quantity, product: { id: "gid://shopify/Product/#{product_id}" },
      inventoryItem: { id: "gid://shopify/InventoryItem/#{inventory_item_id}", tracked: tracked }
    }
    stub_request(:post, "https://#{shop}/admin/api/2026-10/graphql.json")
      .with { |req| JSON.parse(req.body).dig("variables", "id") == gid }
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { data: { productVariant: variant || nil } }.to_json)
  end
end

# Builds webhook deliveries the way Shopify sends them: HMAC-SHA256 over the raw
# body with the client secret, base64-encoded, plus the X-Shopify-* headers.
module ShopifyWebhookHelper
  def shopify_hmac(body, secret: ENV.fetch("SHOPIFY_API_SECRET"))
    Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, body))
  end

  def shopify_webhook_headers(body, topic:, shop:, webhook_id: SecureRandom.uuid, hmac: shopify_hmac(body))
    {
      "Content-Type" => "application/json",
      "X-Shopify-Topic" => topic,
      "X-Shopify-Shop-Domain" => shop,
      "X-Shopify-Webhook-Id" => webhook_id,
      "X-Shopify-Event-Id" => SecureRandom.uuid,
      "X-Shopify-API-Version" => "2026-10",
      "X-Shopify-Triggered-At" => Time.current.utc.iso8601(6),
      "X-Shopify-Hmac-Sha256" => hmac
    }
  end

  # The Admin API's answer to Webhooks::InventoryLevelsUpdate::QUERY.
  def stub_inventory_item(shop:, inventory_item_id:, variants:, tracked: true, status: 200, body: nil)
    item_gid = "gid://shopify/InventoryItem/#{inventory_item_id}"
    body ||= {
      data: {
        inventoryItem: {
          id: item_gid,
          tracked: tracked,
          variants: {
            nodes: variants.map do |v|
              { id: v.fetch(:id), inventoryQuantity: v.fetch(:quantity), product: { id: v.fetch(:product_id) } }
            end
          }
        }
      }
    }
    stub_request(:post, "https://#{shop}/admin/api/2026-10/graphql.json")
      .with { |req| JSON.parse(req.body).dig("variables", "id") == item_gid }
      .to_return(status: status, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end
end

# Builds the state the restock email jobs start from, and stubs the Admin API
# call NotifySubscribersJob makes.
module RestockEmailHelper
  VARIANT = "gid://shopify/ProductVariant/4242"
  PRODUCT = "gid://shopify/Product/42"

  # A restock that already happened: stock row at `quantity`, plus its event.
  # Creating the event enqueues a NotifySubscribersJob (after commit).
  def restock!(shop:, variant_gid: VARIANT, quantity: 5, **event_attributes)
    VariantStock.find_or_initialize_by(shop: shop, variant_gid: variant_gid)
                .update!(product_gid: PRODUCT, inventory_item_gid: "gid://shopify/InventoryItem/4242",
                         quantity: quantity, observed_at: 1.minute.ago)
    RestockEvent.create!(shop: shop, variant_gid: variant_gid, product_gid: PRODUCT,
                         previous_quantity: 0, new_quantity: quantity, **event_attributes)
  end

  def subscribe!(shop:, email:, variant_gid: VARIANT, status: "pending")
    shop.subscriptions.create!(variant_gid: variant_gid, product_gid: PRODUCT, email: email, status: status)
  end

  # A fanned-out restock with one pending email, ready for SendRestockEmailJob.
  # in_stock: the variant's current quantity when the email job runs.
  def pending_notification!(shop:, email: "ana@example.com", in_stock: 5)
    event = restock!(shop: shop, quantity: in_stock, fanned_out_at: Time.current,
                     shop_name: "Snow Co", shop_contact_email: "help@snow.example",
                     product_title: "Liquid Snowboard", variant_title: "158cm",
                     product_url: "https://snow.example/products/liquid?variant=4242",
                     image_url: "https://cdn.shopify.com/liquid.jpg")
    subscription = subscribe!(shop: shop, email: email, status: "notified")
    Notification.create!(shop: shop, subscription: subscription, restock_event: event)
  end

  # The Admin API's answer to NotifySubscribersJob::QUERY.
  def stub_email_details(shop:, variant_title: "158cm", variant_image: nil, exists: true, body: nil)
    variant = {
      title: variant_title,
      image: variant_image && { url: variant_image },
      product: {
        title: "Liquid Snowboard", handle: "liquid",
        featuredMedia: { preview: { image: { url: "https://cdn.shopify.com/featured.jpg" } } }
      }
    }
    body ||= {
      data: {
        shop: { name: "Snow Co", contactEmail: "help@snow.example", primaryDomain: { url: "https://snow.example" } },
        productVariant: exists ? variant : nil
      }
    }
    stub_request(:post, "https://#{shop.shopify_domain}/admin/api/2026-10/graphql.json")
      .with { |req| JSON.parse(req.body)["query"].include?("RestockPingEmailDetails") }
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json)
  end
end

# A delivery method that raises, to simulate an SMTP server refusing or failing.
class FailingDelivery
  class << self
    attr_accessor :error
  end

  def initialize(_settings); end

  def deliver!(_mail)
    raise self.class.error
  end
end
ActionMailer::Base.add_delivery_method :failing, FailingDelivery
