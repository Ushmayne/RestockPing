# frozen_string_literal: true

module Webhooks
  # Mandatory privacy webhooks (required for every App Store app):
  #   customers/data_request  a customer asked what data we hold on them
  #   customers/redact        erase a customer's data
  #   shop/redact             erase all of a shop's data (48h after uninstall)
  #
  # The only customer data RestockPing stores is Subscription rows (email,
  # optional customer id, which variant they're waiting on).
  class Compliance
    def initialize(webhook)
      @webhook = webhook
    end

    def call
      WebhookDelivery.process_once(@webhook) do
        shop = Shop.find_by(shopify_domain: @webhook.shop_domain)
        next if shop.nil? # already erased on uninstall

        case @webhook.topic
        when "customers/redact" then redact_customer(shop)
        when "customers/data_request" then report_customer_data(shop)
        when "shop/redact" then shop.destroy!
        end
      end
    end

    private

    # Matches on customer id OR email. Guest signups have no customer id, and a
    # customer may have signed up with an email before creating an account.
    def customer_subscriptions(shop)
      customer = @webhook.payload.fetch("customer", {})
      matches = []
      matches << shop.subscriptions.where(customer_id: customer["id"]) if customer["id"].present?
      # Deterministic encryption: this WHERE matches on ciphertext.
      matches << shop.subscriptions.where(email: customer["email"]) if customer["email"].present?
      matches.reduce { |all, relation| all.or(relation) } || Subscription.none
    end

    def redact_customer(shop)
      deleted = customer_subscriptions(shop).delete_all
      Rails.logger.info("[compliance] customers/redact #{shop.shopify_domain}: deleted #{deleted} subscription(s)")
    end

    # Shopify expects the app to send the data to the merchant within 30 days.
    # This logs what we hold, and the request id, so it can be fulfilled. There's
    # no automated export yet.
    def report_customer_data(shop)
      rows = customer_subscriptions(shop).pluck(:variant_gid, :status, :created_at)
      request_id = @webhook.payload.dig("data_request", "id")
      Rails.logger.info("[compliance] customers/data_request #{request_id} #{shop.shopify_domain}: " \
                        "#{rows.size} subscription(s) #{rows.inspect}")
    end
  end
end
