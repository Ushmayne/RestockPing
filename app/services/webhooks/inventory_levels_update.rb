# frozen_string_literal: true

module Webhooks
  # inventory_levels/update: fires when a variant's `available` count changes at
  # one location.
  #
  # The payload only carries the *new* per-location number. It can be coalesced
  # (two quick changes, both deliveries showing the final value) or missing
  # location_id. So it's treated as "this inventory item changed", and the
  # current total for each variant is re-fetched from the Admin API.
  class InventoryLevelsUpdate
    class GraphqlError < StandardError; end

    QUERY = <<~GRAPHQL
      query RestockPingInventoryItem($id: ID!) {
        inventoryItem(id: $id) {
          id
          tracked
          variants(first: 50) {
            nodes {
              id
              inventoryQuantity
              product { id }
            }
          }
        }
      }
    GRAPHQL

    def initialize(webhook)
      @webhook = webhook
    end

    # Returns the RestockEvents created (possibly none), or :duplicate.
    def call
      shop = Shop.find_by(shopify_domain: @webhook.shop_domain)
      return [] if shop.nil? # app was uninstalled, nothing to update

      item_id = @webhook.payload["inventory_item_id"]
      return WebhookDelivery.process_once(@webhook) { [] } if item_id.blank?

      # Timestamp taken *before* the request, so any reading we store is at
      # least this fresh. VariantStock uses it to drop out-of-order reads.
      observed_at = Time.current
      # Network call happens outside the DB transaction, so no row lock or DB
      # connection is held while waiting on Shopify.
      item = fetch_inventory_item(shop, item_id)

      WebhookDelivery.process_once(@webhook) do
        # Deleted item, or one whose inventory isn't tracked (its quantity is
        # meaningless). Record the delivery and do nothing.
        next [] if item.nil? || !item["tracked"]

        item.dig("variants", "nodes").filter_map do |variant|
          VariantStock.observe!(
            shop: shop,
            variant_gid: variant["id"],
            product_gid: variant.dig("product", "id"),
            inventory_item_gid: item["id"],
            quantity: variant["inventoryQuantity"].to_i,
            observed_at: observed_at,
          )
        end
      end
    end

    private

    def fetch_inventory_item(shop, item_id)
      # with_shopify_session refreshes an expired access token first (row-locked,
      # see Phase 1). A webhook has no merchant in the browser to re-authenticate.
      shop.with_shopify_session do |session|
        client = ShopifyAPI::Clients::Graphql::Admin.new(session: session)
        response = client.query(query: QUERY, variables: { id: "gid://shopify/InventoryItem/#{item_id}" })

        # GraphQL reports errors such as THROTTLED with HTTP 200. Raising turns
        # them into a 500, so Shopify retries later instead of the change being lost.
        errors = response.body["errors"]
        raise GraphqlError, errors.to_json if errors.present?

        response.body.dig("data", "inventoryItem")
      end
    end
  end
end
