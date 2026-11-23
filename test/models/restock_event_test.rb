require "test_helper"

class RestockEventTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup { @shop = shops(:regular_shop) }

  def build_event
    RestockEvent.new(shop: @shop, variant_gid: "gid://shopify/ProductVariant/1",
                     product_gid: "gid://shopify/Product/1", previous_quantity: 0, new_quantity: 3)
  end

  test "a committed restock enqueues the fan-out" do
    event = build_event

    assert_enqueued_with(job: NotifySubscribersJob, args: [ event ]) { event.save! }
  end

  test "a rolled-back restock enqueues nothing (no job for a row that never existed)" do
    assert_no_enqueued_jobs do
      RestockEvent.transaction do
        build_event.save!
        raise ActiveRecord::Rollback
      end
    end
  end
end
