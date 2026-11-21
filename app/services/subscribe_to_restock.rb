# frozen_string_literal: true

# Signs a shopper up for a back-in-stock email on one variant.
#
# Verifies with the Admin API that the variant belongs to this shop, tracks
# inventory, and is actually sold out. That count becomes the VariantStock
# baseline, so the next inventory webhook can recognise the 0 -> >0 restock.
class SubscribeToRestock
  # Outcomes: :subscribed, :invalid_email, :unknown_variant, :not_tracked, :in_stock
  Result = Data.define(:status, :subscription)

  QUERY = <<~GRAPHQL
    query RestockPingVariant($id: ID!) {
      productVariant(id: $id) {
        id
        inventoryQuantity
        product { id }
        inventoryItem { id tracked }
      }
    }
  GRAPHQL

  class GraphqlError < StandardError; end

  def initialize(shop:)
    @shop = shop
  end

  def call(variant_id:, email:, customer_id: nil)
    customer_id = Integer(customer_id.to_s, exception: false)
    # Validate the cheap things before spending an API call.
    numeric_id = Integer(variant_id.to_s, exception: false)
    return Result.new(:unknown_variant, nil) unless numeric_id&.positive?

    # Run the model's email rules (normalisation + format) without saving anything.
    draft = @shop.subscriptions.new(email: email.to_s)
    draft.validate
    return Result.new(:invalid_email, nil) if draft.errors[:email].any?

    observed_at = Time.current
    variant = fetch_variant("gid://shopify/ProductVariant/#{numeric_id}")
    # Another shop's variant id returns null under this shop's token.
    return Result.new(:unknown_variant, nil) if variant.nil?
    return Result.new(:not_tracked, nil) unless variant.dig("inventoryItem", "tracked")

    quantity = variant["inventoryQuantity"].to_i
    return Result.new(:in_stock, nil) if quantity.positive?

    subscription = Subscription.transaction do
      VariantStock.observe!(shop: @shop, variant_gid: variant["id"], product_gid: variant.dig("product", "id"),
                            inventory_item_gid: variant.dig("inventoryItem", "id"),
                            quantity: quantity, observed_at: observed_at)
      upsert_subscription(variant, draft.email, customer_id)
    end
    Result.new(:subscribed, subscription)
  end

  private

  # Idempotent: a double-click, a retry or a second visit leaves one row. If the
  # shopper was already emailed for an earlier restock, it re-arms the subscription.
  def upsert_subscription(variant, email, customer_id)
    # create_or_find_by tries the INSERT first and falls back to SELECT on the
    # unique-index violation. No check-then-insert race between two requests.
    subscription = @shop.subscriptions.create_or_find_by!(variant_gid: variant["id"], email: email) do |s|
      s.product_gid = variant.dig("product", "id")
      s.customer_id = customer_id
    end
    subscription.update!(status: "pending", notified_at: nil, customer_id: customer_id || subscription.customer_id)
    subscription
  end

  def fetch_variant(gid)
    @shop.with_shopify_session do |session|
      response = ShopifyAPI::Clients::Graphql::Admin.new(session: session).query(query: QUERY, variables: { id: gid })
      errors = response.body["errors"]
      raise GraphqlError, errors.to_json if errors.present?

      response.body.dig("data", "productVariant")
    end
  end
end
