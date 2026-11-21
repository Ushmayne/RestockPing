# frozen_string_literal: true

# One verified webhook delivery: the Shopify headers we use, plus the parsed body.
ShopifyWebhook = Data.define(:topic, :shop_domain, :webhook_id, :triggered_at, :api_version, :payload) do
  def self.from_request(request)
    new(
      topic: request.headers["X-Shopify-Topic"].to_s,
      shop_domain: request.headers["X-Shopify-Shop-Domain"].to_s,
      webhook_id: request.headers["X-Shopify-Webhook-Id"].to_s,
      triggered_at: parse_time(request.headers["X-Shopify-Triggered-At"]),
      api_version: request.headers["X-Shopify-API-Version"].to_s,
      payload: JSON.parse(request.raw_post.presence || "{}"),
    )
  end

  def self.parse_time(value)
    Time.iso8601(value) if value.present?
  rescue ArgumentError
    nil
  end
end
