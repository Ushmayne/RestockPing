# frozen_string_literal: true

# Single endpoint for every Shopify webhook topic (see shopify.app.toml).
#
# Inherits from ActionController::API, not ApplicationController. Webhooks have no
# browser, cookies or CSRF token, and ApplicationController's `allow_browser`
# would answer Shopify's servers with 406.
class WebhooksController < ActionController::API
  HANDLERS = {
    "inventory_levels/update" => Webhooks::InventoryLevelsUpdate,
    "app/uninstalled" => Webhooks::AppUninstalled,
    "customers/data_request" => Webhooks::Compliance,
    "customers/redact" => Webhooks::Compliance,
    "shop/redact" => Webhooks::Compliance
  }.freeze

  before_action :verify_shopify_hmac!

  def receive
    webhook = ShopifyWebhook.from_request(request)
    return head(:bad_request) if webhook.webhook_id.blank? || webhook.shop_domain.blank?

    handler = HANDLERS[webhook.topic]
    if handler.nil?
      Rails.logger.warn("[webhooks] no handler for topic #{webhook.topic.inspect}")
      return head(:ok) # 2xx so Shopify doesn't keep retrying a topic we ignore
    end

    # Fast path for retries. process_once is still the real guarantee (unique index).
    return head(:ok) if WebhookDelivery.exists?(webhook_id: webhook.webhook_id)

    handler.new(webhook).call
    head :ok
    # Any exception propagates as a 500. Nothing was recorded (the transaction
    # rolled back, or never started), so Shopify's retry will process it again.
  end

  private

  def verify_shopify_hmac!
    # raw_post is the exact bytes Shopify signed. Re-serialising params would
    # change key order and whitespace and break the digest.
    return if ShopifyWebhookVerifier.valid?(
      raw_body: request.raw_post,
      hmac_header: request.headers["X-Shopify-Hmac-Sha256"],
    )

    Rails.logger.warn("[webhooks] rejected delivery with invalid HMAC")
    head :unauthorized # Shopify's compliance checks require 401 for a bad HMAC
  end
end
