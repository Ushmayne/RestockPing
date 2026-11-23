require "test_helper"

# Test-only hook: lets a thread pause inside the send, after it has read the
# notification as "pending" and before the email goes out.
module PauseBeforeRestockEmail
  def back_in_stock(...)
    Thread.current[:before_restock_email]&.call
    super
  end
end
RestockMailer.prepend(PauseBeforeRestockEmail)

# Proves the row lock in SendRestockEmailJob stops two copies of the same job
# (a Sidekiq redelivery overlapping the original, or the sweeper) from both
# emailing the subscriber. Needs real concurrent transactions on separate
# connections, so transactional tests are off and teardown cleans up.
class SendRestockEmailConcurrencyTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include RestockEmailHelper

  self.use_transactional_tests = false

  setup do
    @shop = shops(:regular_shop)
    @notification = pending_notification!(shop: @shop, email: "race@example.com")
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    Notification.where(shop: @shop).delete_all
    Subscription.where(shop: @shop).delete_all
    RestockEvent.where(shop: @shop).delete_all
    VariantStock.where(shop: @shop).delete_all
  end

  test "two copies of the same send job running at once send one email" do
    a_is_sending = Queue.new

    # Copy A takes the lock, passes the "still pending?" check, and stalls just
    # before delivering (a slow SMTP handshake).
    a = Thread.new do
      Thread.current[:before_restock_email] = lambda do
        a_is_sending << true
        sleep 0.5
      end
      ActiveRecord::Base.connection_pool.with_connection do
        SendRestockEmailJob.perform_now(Notification.find(@notification.id))
      end
    end

    # Copy B starts inside A's gap.
    #  - With the lock: B blocks on SELECT ... FOR UPDATE until A commits
    #    "sent", then sees it and stops. One email.
    #  - Without it: B also reads "pending" and sends a second email.
    b = Thread.new do
      a_is_sending.pop
      ActiveRecord::Base.connection_pool.with_connection do
        SendRestockEmailJob.perform_now(Notification.find(@notification.id))
      end
    end

    [ a, b ].each(&:join)

    assert_equal 1, ActionMailer::Base.deliveries.count { |mail| mail.to == [ "race@example.com" ] }
    assert_equal "sent", @notification.reload.status
  end
end
