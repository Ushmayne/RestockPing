require "test_helper"

class SubscriptionTest < ActiveSupport::TestCase
  setup { @shop = shops(:regular_shop) }

  def subscribe(email, variant: "gid://shopify/ProductVariant/1")
    @shop.subscriptions.create!(email: email, variant_gid: variant, product_gid: "gid://shopify/Product/1")
  end

  test "email is stored encrypted, not as plain text" do
    subscription = subscribe("ana@example.com")
    raw = Subscription.connection.select_value("SELECT email FROM subscriptions WHERE id = #{subscription.id}")

    refute_includes raw, "ana@example.com"
    assert_equal "ana@example.com", subscription.reload.email
  end

  test "normalised before encrypting, so case and spaces don't create duplicates" do
    subscribe("ana@example.com")

    assert_raises(ActiveRecord::RecordNotUnique) { subscribe("  ANA@Example.COM ") }
  end

  test "deterministic encryption still allows lookup by email (used by customers/redact)" do
    subscription = subscribe("ana@example.com")

    assert_equal subscription, @shop.subscriptions.find_by(email: "Ana@Example.com")
  end

  test "the same email can wait on different variants" do
    subscribe("ana@example.com", variant: "gid://shopify/ProductVariant/1")
    subscribe("ana@example.com", variant: "gid://shopify/ProductVariant/2")

    assert_equal 2, @shop.subscriptions.count
  end

  test "rejects malformed emails" do
    [ "", "not-an-email", "a@", "@b.com", "a b@c.com" ].each do |bad|
      refute @shop.subscriptions.new(email: bad, variant_gid: "v", product_gid: "p").valid?, bad.inspect
    end
  end
end
