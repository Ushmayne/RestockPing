# frozen_string_literal: true

module Webhooks
  # app/uninstalled: the merchant removed the app. Our access token is already
  # revoked, so delete the shop row (tokens included). Its stock and restock rows
  # go with it. If the merchant reinstalls, token exchange creates a fresh row.
  class AppUninstalled
    def initialize(webhook)
      @webhook = webhook
    end

    def call
      WebhookDelivery.process_once(@webhook) do
        Shop.find_by(shopify_domain: @webhook.shop_domain)&.destroy!
      end
    end
  end
end
