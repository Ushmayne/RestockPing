require "test_helper"

class RequeueStalledNotificationsJobTest < ActiveJob::TestCase
  include RestockEmailHelper

  setup { @shop = shops(:regular_shop) }

  def enqueued(job_class) = enqueued_jobs.select { |job| job[:job] == job_class }

  test "re-enqueues fan-outs that never ran, within the window" do
    lost = restock!(shop: @shop, variant_gid: "gid://shopify/ProductVariant/1")
    lost.update_columns(created_at: 20.minutes.ago)
    restock!(shop: @shop, variant_gid: "gid://shopify/ProductVariant/2") # fresh: its job may still be queued
    ancient = restock!(shop: @shop, variant_gid: "gid://shopify/ProductVariant/3")
    ancient.update_columns(created_at: 4.days.ago)
    done = restock!(shop: @shop, variant_gid: "gid://shopify/ProductVariant/4", fanned_out_at: Time.current)
    done.update_columns(created_at: 20.minutes.ago)
    clear_enqueued_jobs

    RequeueStalledNotificationsJob.perform_now

    assert_equal [ lost ], enqueued(NotifySubscribersJob).map { |job| GlobalID::Locator.locate(job[:args].first["_aj_globalid"]) }
  end

  test "re-enqueues emails still pending after the whole retry window" do
    stuck = pending_notification!(shop: @shop, email: "stuck@example.com")
    stuck.update_columns(created_at: 3.hours.ago)
    retrying = pending_notification!(shop: @shop, email: "retrying@example.com")
    retrying.update_columns(created_at: 30.minutes.ago)
    failed = pending_notification!(shop: @shop, email: "failed@example.com")
    failed.update_columns(created_at: 3.hours.ago, status: "failed")
    clear_enqueued_jobs

    RequeueStalledNotificationsJob.perform_now

    located = enqueued(SendRestockEmailJob).map { |job| GlobalID::Locator.locate(job[:args].first["_aj_globalid"]) }
    assert_equal [ stuck ], located
  end
end
