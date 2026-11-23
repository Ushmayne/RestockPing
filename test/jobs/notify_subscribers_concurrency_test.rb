require "test_helper"

# Test-only hook: lets a thread pause inside the claim transaction, after it has
# selected and flipped the pending subscribers but before it commits.
module PauseBeforeNotificationInsert
  def insert_all(...)
    Thread.current[:before_notification_insert]&.call
    super
  end
end
Notification.singleton_class.prepend(PauseBeforeNotificationInsert)

# Two restocks of the same variant close together (restock, sell out, restock)
# give two fan-out jobs for two different events. The unique index on
# (subscription, event) can't stop both from claiming the same subscriber,
# because the event ids differ. Only the FOR UPDATE on the subscribers does.
class NotifySubscribersConcurrencyTest < ActiveSupport::TestCase
  include RestockEmailHelper

  self.use_transactional_tests = false

  setup do
    @shop = shops(:regular_shop)
    @subscription = subscribe!(shop: @shop, email: "race@example.com")
    @first = restock!(shop: @shop, product_title: "Liquid Snowboard")
    @second = RestockEvent.create!(shop: @shop, variant_gid: VARIANT, product_gid: PRODUCT,
                                   previous_quantity: 0, new_quantity: 2, product_title: "Liquid Snowboard")
  end

  teardown do
    Notification.where(shop: @shop).delete_all
    Subscription.where(shop: @shop).delete_all
    RestockEvent.where(shop: @shop).delete_all
    VariantStock.where(shop: @shop).delete_all
  end

  test "two fan-outs for the same variant at once claim each subscriber exactly once" do
    a_has_claimed = Queue.new

    # Fan-out A has selected the subscriber and marked it notified (uncommitted),
    # then stalls before inserting its notification.
    a = Thread.new do
      Thread.current[:before_notification_insert] = lambda do
        a_has_claimed << true
        sleep 0.5
      end
      ActiveRecord::Base.connection_pool.with_connection { NotifySubscribersJob.perform_now(@first) }
    end

    # Fan-out B starts in A's gap.
    #  - With FOR UPDATE: B waits for A's row lock, then Postgres re-checks
    #    status = 'pending' against A's committed "notified" and skips the row.
    #  - Without it: B reads the last committed status ("pending") and claims the
    #    subscriber a second time, which means a second email.
    b = Thread.new do
      a_has_claimed.pop
      ActiveRecord::Base.connection_pool.with_connection { NotifySubscribersJob.perform_now(@second) }
    end

    [ a, b ].each(&:join)

    assert_equal 1, Notification.where(subscription: @subscription).count
  end
end
