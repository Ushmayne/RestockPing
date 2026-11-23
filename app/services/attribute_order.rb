# frozen_string_literal: true

# Decides which restock emails a paid order should be credited to.
#
# A sent notification gets the credit when all of these hold:
#   1. same shopper: the order's customer id OR email matches the subscriber
#   2. same variant: the order contains the variant the email was about
#   3. in the window: the email went out at most WINDOW before the order,
#      and not after it
#
# If several emails qualify for one variant (a shopper re-subscribed and was
# emailed twice), the most recent one gets it (last touch). An order with two
# restocked variants can credit two emails. Each email converts at most once,
# enforced by the unique index on conversions.notification_id.
class AttributeOrder
  WINDOW = 7.days

  # order: the orders/paid webhook payload (REST-shaped JSON, string keys).
  def initialize(shop:, order:)
    @shop = shop
    @order = order
  end

  # Returns the number of conversions recorded.
  def call
    revenue = revenue_by_variant
    return 0 if revenue.empty?

    shopper = matching_subscriptions
    return 0 if shopper.nil?

    ordered_at = order_time
    candidates = @shop.notifications.sent
                      .where(sent_at: (ordered_at - WINDOW)..ordered_at)
                      .joins(:subscription)
                      .merge(shopper)
                      .where(subscriptions: { variant_gid: revenue.keys })
                      .order(sent_at: :desc, id: :desc)
                      .pluck("notifications.id", "subscriptions.variant_gid")
    # Newest first, so the first row per variant is the last touch.
    winners = candidates.uniq { |_id, variant_gid| variant_gid }
    return 0 if winners.empty?

    rows = winners.map do |notification_id, variant_gid|
      {
        shop_id: @shop.id, notification_id: notification_id,
        order_id: @order.fetch("id"), order_name: @order["name"],
        revenue: revenue.fetch(variant_gid), currency: @order["currency"],
        test_order: @order["test"] == true, ordered_at: ordered_at,
        # The paid order may already be cancelled by the time we see it.
        cancelled_at: parse_time(@order["cancelled_at"])
      }
    end
    # ON CONFLICT (notification_id) DO NOTHING: an email that already converted
    # keeps its first order. Also makes a repeated orders/paid harmless, whatever
    # its webhook id.
    Conversion.insert_all(rows, unique_by: :notification_id).length
  end

  private

  # Who is the buyer? Logged-in signups stored a customer id. Guest signups
  # only have the email. Either can match.
  #
  # Without Level 2 protected customer data access, Shopify redacts the email
  # fields in the payload, so only the customer id can match.
  def matching_subscriptions
    customer_id = @order.dig("customer", "id")
    email = [ @order["email"], @order["contact_email"], @order.dig("customer", "email") ].find(&:present?)

    conditions = []
    conditions << Subscription.where(customer_id: customer_id) if customer_id.present?
    # Subscription normalizes the email before encrypting, and Rails applies
    # that to this WHERE too, so "Ana@Example.com" finds "ana@example.com".
    # Deterministic encryption turns it into a ciphertext equality match.
    conditions << Subscription.where(email: email) if email.present?
    conditions.reduce { |all, condition| all.or(condition) }
  end

  # { "gid://shopify/ProductVariant/1" => BigDecimal }, for line items that
  # are real variants. Custom line items have variant_id null.
  def revenue_by_variant
    Array(@order["line_items"]).each_with_object(Hash.new(0)) do |item, totals|
      next if item["variant_id"].blank?

      gross = money(item.dig("price_set", "shop_money", "amount") || item["price"]) * item["quantity"].to_i
      # Covers both line-level and order-level discounts allocated to this line.
      discounts = Array(item["discount_allocations"]).sum do |allocation|
        money(allocation.dig("amount_set", "shop_money", "amount") || allocation["amount"])
      end
      totals["gid://shopify/ProductVariant/#{item["variant_id"]}"] += gross - discounts
    end
  end

  # When the shopper placed the order. orders/paid can arrive much later
  # (bank transfer), and the window is about when they decided to buy.
  def order_time
    parse_time(@order["processed_at"]) || parse_time(@order["created_at"]) || Time.current
  end

  # Strings to BigDecimal: never floats for money.
  def money(value)
    BigDecimal(value.to_s.presence || "0")
  end

  def parse_time(value)
    Time.iso8601(value) if value.present?
  rescue ArgumentError
    nil
  end
end
