require "test_helper"

class AttributeOrderTest < ActiveSupport::TestCase
  include RestockEmailHelper
  include ShopifyOrderHelper

  VARIANT_ID = 4242 # RestockEmailHelper::VARIANT
  OTHER_VARIANT_ID = 777

  setup { @shop = shops(:regular_shop) }

  # A restock email that went out `sent_at`, for one shopper and one variant.
  def sent_notification!(email: "ana@example.com", customer_id: nil, sent_at: 1.day.ago,
                         variant_id: VARIANT_ID, shop: @shop, status: "sent")
    gid = "gid://shopify/ProductVariant/#{variant_id}"
    event = restock!(shop: shop, variant_gid: gid)
    subscription = shop.subscriptions.find_or_create_by!(variant_gid: gid, email: email) do |s|
      s.product_gid = PRODUCT
    end
    subscription.update!(customer_id: customer_id, status: "notified")
    Notification.create!(shop: shop, subscription: subscription, restock_event: event,
                         status: status, sent_at: status == "sent" ? sent_at : nil)
  end

  def attribute(order) = AttributeOrder.new(shop: @shop, order: order).call

  def buys(variant_id = VARIANT_ID, price: "100.00", quantity: 1, discounts: [])
    [ { variant_id: variant_id, price: price, quantity: quantity, discounts: discounts } ]
  end

  # --- who bought ----------------------------------------------------------

  test "guest signup: matched by email, whatever the case" do
    notification = sent_notification!(email: "ana@example.com")

    assert_equal 1, attribute(order_payload(email: "Ana@Example.com", line_items: buys))

    assert_equal notification, Conversion.sole.notification
  end

  test "logged-in signup: matched by customer id even if the order's email differs (or is redacted)" do
    notification = sent_notification!(email: "ana@example.com", customer_id: 555)

    attribute(order_payload(customer_id: 555, email: nil, line_items: buys))

    assert_equal notification, Conversion.sole.notification
  end

  test "someone else buying the variant is not a conversion" do
    sent_notification!(email: "ana@example.com", customer_id: 555)

    assert_equal 0, attribute(order_payload(customer_id: 999, email: "bob@example.com", line_items: buys))
  end

  test "no buyer identity at all (email redacted, guest checkout): nothing to match on" do
    sent_notification!

    assert_equal 0, attribute(order_payload(line_items: buys))
  end

  test "another shop's subscriber with the same email doesn't count" do
    sent_notification!(shop: shops(:expired_token_shop))

    assert_equal 0, attribute(order_payload(email: "ana@example.com", line_items: buys))
  end

  # --- what they bought ----------------------------------------------------

  test "buying something other than the restocked variant is not a conversion" do
    sent_notification!

    assert_equal 0, attribute(order_payload(email: "ana@example.com", line_items: buys(OTHER_VARIANT_ID)))
  end

  test "revenue counts only the restocked variant's lines, times quantity, minus its discounts" do
    sent_notification!

    attribute(order_payload(email: "ana@example.com", line_items: [
      { variant_id: VARIANT_ID, price: "40.00", quantity: 3, discounts: [ "10.00", "2.50" ] },
      { variant_id: OTHER_VARIANT_ID, price: "999.00" },
      { variant_id: nil, price: "5.00" } # custom line item (no variant), e.g. gift wrap
    ]))

    conversion = Conversion.sole
    assert_equal BigDecimal("107.50"), conversion.revenue
    assert_equal "USD", conversion.currency
    assert_equal "#1001", conversion.order_name
  end

  test "an order with two restocked variants credits both emails" do
    first = sent_notification!(variant_id: VARIANT_ID)
    second = sent_notification!(variant_id: OTHER_VARIANT_ID)

    count = attribute(order_payload(email: "ana@example.com", line_items: [
      { variant_id: VARIANT_ID, price: "10.00" }, { variant_id: OTHER_VARIANT_ID, price: "20.00" }
    ]))

    assert_equal 2, count
    assert_equal({ first.id => BigDecimal("10"), second.id => BigDecimal("20") },
                 Conversion.pluck(:notification_id, :revenue).to_h)
  end

  # --- when ---------------------------------------------------------------

  test "the 7-day window: just inside counts, just outside doesn't" do
    now = Time.current
    inside = sent_notification!(email: "in@example.com", sent_at: now - 7.days + 1.minute)
    sent_notification!(email: "out@example.com", sent_at: now - 7.days - 1.minute)

    attribute(order_payload(email: "in@example.com", processed_at: now, line_items: buys))
    attribute(order_payload(id: 2, email: "out@example.com", processed_at: now, line_items: buys))

    assert_equal [ inside.id ], Conversion.pluck(:notification_id)
  end

  test "an order placed before the email was sent isn't credited to it (paid later, e.g. bank transfer)" do
    sent_notification!(sent_at: 1.hour.ago)

    assert_equal 0, attribute(order_payload(email: "ana@example.com", processed_at: 2.days.ago, line_items: buys))
  end

  test "only emails that were actually sent can convert" do
    %w[pending failed canceled].each_with_index do |status, i|
      sent_notification!(email: "#{status}@example.com", status: status)
      assert_equal 0, attribute(order_payload(id: i, email: "#{status}@example.com", line_items: buys)), status
    end
  end

  test "emailed twice for the same variant: the most recent email gets the credit" do
    sent_notification!(sent_at: 5.days.ago)
    latest = sent_notification!(sent_at: 1.day.ago)

    attribute(order_payload(email: "ana@example.com", line_items: buys))

    assert_equal latest, Conversion.sole.notification
  end

  # --- once only -----------------------------------------------------------

  test "the same order delivered twice records one conversion" do
    sent_notification!
    order = order_payload(email: "ana@example.com", line_items: buys)

    attribute(order)
    assert_equal 0, attribute(order)

    assert_equal 1, Conversion.count
  end

  test "a second order later doesn't take the credit from the first" do
    sent_notification!
    attribute(order_payload(id: 1, email: "ana@example.com", line_items: buys))

    attribute(order_payload(id: 2, email: "ana@example.com", line_items: buys))

    assert_equal [ 1 ], Conversion.pluck(:order_id)
  end

  # --- flags ----------------------------------------------------------------

  test "test orders and already-cancelled orders are recorded but not counted" do
    sent_notification!(email: "test@example.com")
    sent_notification!(email: "cancelled@example.com", variant_id: OTHER_VARIANT_ID)

    attribute(order_payload(id: 1, email: "test@example.com", test: true, line_items: buys))
    attribute(order_payload(id: 2, email: "cancelled@example.com", cancelled_at: Time.current,
                            line_items: buys(OTHER_VARIANT_ID)))

    assert_equal 2, Conversion.count
    assert_empty Conversion.counted
  end

  test "stores no customer data, only order facts" do
    assert_not_includes Conversion.column_names.join(" "), "email"
    assert_not_includes Conversion.column_names.join(" "), "customer"
  end
end
