# frozen_string_literal: true

# A webhook delivery we've already processed, keyed by X-Shopify-Webhook-Id.
class WebhookDelivery < ApplicationRecord
  # Runs the block at most once per webhook_id, in the same transaction as the
  # dedup row. Either both the side effects and the dedup row commit, or neither
  # does. So:
  #   - if the block raises, nothing is recorded and Shopify's retry reprocesses it
  #   - if two copies of a delivery race, the unique index rejects the second insert
  #
  # Returns the block's value, or :duplicate if this delivery was already processed.
  def self.process_once(webhook)
    transaction do
      create!(
        webhook_id: webhook.webhook_id,
        topic: webhook.topic,
        shop_domain: webhook.shop_domain,
        triggered_at: webhook.triggered_at,
      )
      yield
    end
  rescue ActiveRecord::RecordNotUnique
    # The whole transaction (including any side effects) has rolled back already.
    :duplicate
  end
end
