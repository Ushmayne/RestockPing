# frozen_string_literal: true

module Webhooks
  # Mandatory privacy webhooks (required for every App Store app):
  #   customers/data_request  a customer asked what data we hold on them
  #   customers/redact        erase a customer's data
  #   shop/redact             erase all of a shop's data (48h after uninstall)
  #
  # Until Phase 3 we store no customer data, and app/uninstalled already deletes
  # shop data. So these record the delivery and acknowledge. Phase 3 adds
  # subscriber lookup and erasure here.
  class Compliance
    def initialize(webhook)
      @webhook = webhook
    end

    def call
      WebhookDelivery.process_once(@webhook) do
        case @webhook.topic
        when "shop/redact"
          Shop.find_by(shopify_domain: @webhook.shop_domain)&.destroy!
        end
        Rails.logger.info("[webhooks] #{@webhook.topic} for #{@webhook.shop_domain} handled")
      end
    end
  end
end
