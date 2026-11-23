# frozen_string_literal: true

module Webhooks
  # orders/paid: an order is fully paid. Credits it to the restock emails that
  # led to it (AttributeOrder).
  #
  # Unlike inventory_levels/update, the payload has everything we need (buyer,
  # line items, prices), so there's no API call. It all runs in one DB
  # transaction with the dedup row.
  class OrdersPaid
    def initialize(webhook)
      @webhook = webhook
    end

    def call
      shop = Shop.find_by(shopify_domain: @webhook.shop_domain)
      return 0 if shop.nil?

      WebhookDelivery.process_once(@webhook) do
        AttributeOrder.new(shop: shop, order: @webhook.payload).call
      end
    end
  end
end
