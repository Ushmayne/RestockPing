# frozen_string_literal: true

module Webhooks
  # orders/cancelled: stop counting conversions from this order. The row is kept
  # (with cancelled_at) rather than deleted, so a re-delivered orders/paid
  # can't re-insert it, and the history stays visible.
  class OrdersCancelled
    def initialize(webhook)
      @webhook = webhook
    end

    def call
      shop = Shop.find_by(shopify_domain: @webhook.shop_domain)
      return 0 if shop.nil?

      WebhookDelivery.process_once(@webhook) do
        cancelled_at = ShopifyWebhook.parse_time(@webhook.payload["cancelled_at"]) || Time.current
        # Only orders we attributed have rows. Every other cancellation updates nothing.
        shop.conversions.where(order_id: @webhook.payload["id"], cancelled_at: nil)
            .update_all(cancelled_at: cancelled_at, updated_at: Time.current)
      end
    end
  end
end
