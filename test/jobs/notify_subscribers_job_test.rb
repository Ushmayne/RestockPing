require "test_helper"

class NotifySubscribersJobTest < ActiveJob::TestCase
  include RestockEmailHelper

  setup { @shop = shops(:regular_shop) }

  def send_jobs = enqueued_jobs.select { |job| job[:job] == SendRestockEmailJob }

  test "claims every pending subscriber for the variant and enqueues one email each" do
    ana = subscribe!(shop: @shop, email: "ana@example.com")
    ben = subscribe!(shop: @shop, email: "ben@example.com")
    stub_email_details(shop: @shop)
    event = restock!(shop: @shop)

    NotifySubscribersJob.perform_now(event)

    assert_equal [ ana.id, ben.id ].sort, event.notifications.pluck(:subscription_id).sort
    assert event.notifications.all?(&:pending?)
    assert_equal %w[notified notified], [ ana.reload.status, ben.reload.status ]
    assert ana.notified_at.present?
    assert event.reload.fanned_out_at.present?
    assert_equal 2, send_jobs.size
  end

  test "leaves other variants, other shops and already-notified subscribers alone" do
    other_variant = subscribe!(shop: @shop, email: "ana@example.com", variant_gid: "gid://shopify/ProductVariant/1")
    already_notified = subscribe!(shop: @shop, email: "ben@example.com", status: "notified")
    other_shop = subscribe!(shop: shops(:expired_token_shop), email: "cy@example.com")
    stub_email_details(shop: @shop)
    event = restock!(shop: @shop)

    NotifySubscribersJob.perform_now(event)

    assert_empty event.notifications
    assert_equal "pending", other_variant.reload.status
    assert_equal "notified", already_notified.reload.status
    assert_equal "pending", other_shop.reload.status
    assert event.reload.fanned_out_at.present?
  end

  test "snapshots what the email shows: names, product link with the variant preselected, image" do
    stub_email_details(shop: @shop, variant_image: "https://cdn.shopify.com/variant.jpg")
    event = restock!(shop: @shop)

    NotifySubscribersJob.perform_now(event)

    event.reload
    assert_equal "Snow Co", event.shop_name
    assert_equal "help@snow.example", event.shop_contact_email
    assert_equal "Liquid Snowboard", event.product_title
    assert_equal "158cm", event.variant_title
    assert_equal "https://snow.example/products/liquid?variant=4242", event.product_url
    assert_equal "https://cdn.shopify.com/variant.jpg", event.image_url
  end

  test "single-variant product: no 'Default Title', falls back to the product image" do
    stub_email_details(shop: @shop, variant_title: "Default Title", variant_image: nil)
    event = restock!(shop: @shop)

    NotifySubscribersJob.perform_now(event)

    assert_nil event.reload.variant_title
    assert_equal "https://cdn.shopify.com/featured.jpg", event.image_url
  end

  test "running twice (Sidekiq redelivery, or the sweeper) creates no extra notifications and one API call" do
    subscribe!(shop: @shop, email: "ana@example.com")
    stub = stub_email_details(shop: @shop)
    event = restock!(shop: @shop)

    NotifySubscribersJob.perform_now(event)
    NotifySubscribersJob.perform_now(event)

    assert_equal 1, event.notifications.count
    assert_requested stub, times: 1
    # The second run re-enqueues the still-pending email. That's how a run that
    # crashed between COMMIT and enqueue gets finished. The send job is idempotent.
    assert_equal 2, send_jobs.size
  end

  test "a re-run doesn't re-enqueue emails that were already sent" do
    subscribe!(shop: @shop, email: "ana@example.com")
    stub_email_details(shop: @shop)
    event = restock!(shop: @shop)
    NotifySubscribersJob.perform_now(event)
    event.notifications.update_all(status: "sent")
    clear_enqueued_jobs

    NotifySubscribersJob.perform_now(event)

    assert_empty send_jobs
  end

  test "a subscriber claimed by an earlier restock isn't claimed again by a later one" do
    subscribe!(shop: @shop, email: "ana@example.com")
    stub_email_details(shop: @shop)
    first = restock!(shop: @shop)
    NotifySubscribersJob.perform_now(first)
    second = RestockEvent.create!(shop: @shop, variant_gid: VARIANT, product_gid: PRODUCT,
                                  previous_quantity: 0, new_quantity: 3)

    NotifySubscribersJob.perform_now(second)

    assert_equal 1, first.notifications.count
    assert_equal 0, second.notifications.count
  end

  test "variant deleted since the restock: nobody is emailed, and the event isn't retried" do
    ana = subscribe!(shop: @shop, email: "ana@example.com")
    stub_email_details(shop: @shop, exists: false)
    event = restock!(shop: @shop)

    NotifySubscribersJob.perform_now(event)

    assert_empty event.notifications
    assert_equal "pending", ana.reload.status
    assert event.reload.fanned_out_at.present?
  end

  test "Admin API throttled: nothing claimed, job retried later" do
    ana = subscribe!(shop: @shop, email: "ana@example.com")
    stub_email_details(shop: @shop, body: { errors: [ { message: "Throttled", extensions: { code: "THROTTLED" } } ] })
    event = restock!(shop: @shop)
    clear_enqueued_jobs

    NotifySubscribersJob.perform_now(event)

    assert_enqueued_with(job: NotifySubscribersJob, args: [ event ])
    assert_empty event.notifications
    assert_equal "pending", ana.reload.status
    assert_nil event.reload.fanned_out_at
  end
end
