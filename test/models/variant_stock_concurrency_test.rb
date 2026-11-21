require "test_helper"

# Test-only hook: lets a thread pause inside observe!, right after it has read the
# previous quantity and before it writes the new one. That gap is exactly where a
# second webhook could read the same stale "0". Only threads that set the hook are
# affected.
module PauseBeforeVariantStockUpdate
  def update!(*args, **kwargs)
    Thread.current[:before_variant_stock_update]&.call
    super
  end
end
VariantStock.prepend(PauseBeforeVariantStockUpdate)

# Proves the SELECT ... FOR UPDATE in VariantStock.observe! prevents duplicate
# restock events. This needs real concurrent transactions on separate DB
# connections, so the usual transaction-per-test wrapping is off and the test
# cleans up after itself.
class VariantStockConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  VARIANT = "gid://shopify/ProductVariant/race-1"

  setup do
    @shop = shops(:regular_shop)
    VariantStock.create!(shop: @shop, variant_gid: VARIANT, product_gid: "gid://shopify/Product/race",
                         inventory_item_gid: "gid://shopify/InventoryItem/race", quantity: 0,
                         observed_at: 10.minutes.ago)
  end

  teardown do
    RestockEvent.where(variant_gid: VARIANT).delete_all
    VariantStock.where(variant_gid: VARIANT).delete_all
  end

  def observe(quantity, observed_at)
    VariantStock.observe!(shop: @shop, variant_gid: VARIANT, product_gid: "gid://shopify/Product/race",
                          inventory_item_gid: "gid://shopify/InventoryItem/race",
                          quantity: quantity, observed_at: observed_at)
  end

  test "two webhooks restocking the same variant at once create exactly one RestockEvent" do
    a_has_read_previous = Queue.new

    # Webhook A reads previous = 0, then stalls before writing (a slow request or
    # GC pause in production).
    a = Thread.new do
      Thread.current[:before_variant_stock_update] = lambda do
        a_has_read_previous << true
        sleep 0.5
      end
      ActiveRecord::Base.connection_pool.with_connection do
        VariantStock.transaction { observe(5, 2.seconds.ago) }
      end
    end

    # Webhook B arrives inside A's gap with a newer reading.
    #  - With FOR UPDATE: B blocks on A's row lock, then reads A's 5. 5 -> 7 is
    #    not a restock, so one event total.
    #  - Without it: B also reads 0 and creates a second event, which would be a
    #    duplicate email in Phase 4.
    b = Thread.new do
      a_has_read_previous.pop
      ActiveRecord::Base.connection_pool.with_connection do
        VariantStock.transaction { observe(7, 1.second.ago) }
      end
    end

    [ a, b ].each(&:join)

    assert_equal 1, RestockEvent.where(variant_gid: VARIANT).count
    assert_equal 7, VariantStock.find_by!(variant_gid: VARIANT).quantity
  end
end
