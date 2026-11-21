require "test_helper"

class VariantStockTest < ActiveSupport::TestCase
  VARIANT = "gid://shopify/ProductVariant/111"
  PRODUCT = "gid://shopify/Product/11"
  ITEM = "gid://shopify/InventoryItem/1111"

  setup { @shop = shops(:regular_shop) }

  # Each test already runs inside a transaction, so observe!'s row lock is valid here.
  def observe(quantity, observed_at: Time.current)
    VariantStock.observe!(shop: @shop, variant_gid: VARIANT, product_gid: PRODUCT,
                          inventory_item_gid: ITEM, quantity: quantity, observed_at: observed_at)
  end

  def stored_quantity
    VariantStock.find_by!(shop: @shop, variant_gid: VARIANT).quantity
  end

  test "first sighting stores a baseline and is never a restock" do
    assert_nil observe(5)

    assert_equal 5, stored_quantity
    assert_equal 0, RestockEvent.count
  end

  test "0 -> positive is a restock" do
    observe(0, observed_at: 2.minutes.ago)

    event = observe(5)

    assert_kind_of RestockEvent, event
    assert_equal [ 0, 5 ], [ event.previous_quantity, event.new_quantity ]
    assert_equal VARIANT, event.variant_gid
    assert_equal PRODUCT, event.product_gid
  end

  test "negative (oversold) -> positive is a restock" do
    observe(-3, observed_at: 2.minutes.ago)

    assert_kind_of RestockEvent, observe(2)
  end

  test "positive -> positive is not a restock" do
    observe(5, observed_at: 2.minutes.ago)

    assert_nil observe(3)
    assert_equal 3, stored_quantity
  end

  test "selling out (positive -> 0) and staying out (0 -> 0) are not restocks" do
    observe(3, observed_at: 3.minutes.ago)
    assert_nil observe(0, observed_at: 2.minutes.ago)
    assert_nil observe(0, observed_at: 1.minute.ago)

    assert_equal 0, RestockEvent.count
  end

  test "each separate sell-out and restock cycle produces its own event" do
    observe(0, observed_at: 4.minutes.ago)
    observe(5, observed_at: 3.minutes.ago)
    observe(0, observed_at: 2.minutes.ago)
    observe(4, observed_at: 1.minute.ago)

    assert_equal [ 5, 4 ], RestockEvent.order(:id).pluck(:new_quantity)
  end

  test "a stale reading (observed before the stored one) is ignored" do
    observe(0, observed_at: 5.minutes.ago)
    observe(7, observed_at: 1.minute.ago) # newer reading saved first

    # A slower request that started earlier lands now. It must not move us backwards.
    assert_nil observe(0, observed_at: 3.minutes.ago)
    assert_equal 7, stored_quantity
  end
end
