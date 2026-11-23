require "test_helper"

class SendRestockEmailJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper
  include RestockEmailHelper

  setup { @shop = shops(:regular_shop) }

  teardown { RestockMailer.delivery_method = :test }

  def smtp_fails_with(error)
    FailingDelivery.error = error
    RestockMailer.delivery_method = :failing
  end

  test "sends the email and marks the notification sent" do
    notification = pending_notification!(shop: @shop)

    assert_emails(1) { SendRestockEmailJob.perform_now(notification) }

    assert_equal "sent", notification.reload.status
    assert notification.sent_at.present?
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "ana@example.com" ], mail.to
    assert_equal "Liquid Snowboard - 158cm is back in stock", mail.subject
  end

  test "an email that was already sent is not sent again" do
    notification = pending_notification!(shop: @shop)
    notification.update!(status: "sent", sent_at: 1.minute.ago)

    assert_no_emails { SendRestockEmailJob.perform_now(notification) }
  end

  test "sold out again before the email went: canceled, and the subscription waits for the next restock" do
    notification = pending_notification!(shop: @shop, in_stock: 0)

    assert_no_emails { SendRestockEmailJob.perform_now(notification) }

    assert_equal "canceled", notification.reload.status
    assert_equal "pending", notification.subscription.status
    assert_nil notification.subscription.notified_at
  end

  test "temporary SMTP failure: stays pending and is retried with backoff" do
    notification = pending_notification!(shop: @shop)
    smtp_fails_with(Net::SMTPServerBusy.new("421 4.7.0 Try again later"))

    SendRestockEmailJob.perform_now(notification)

    assert_equal "pending", notification.reload.status
    assert_enqueued_with(job: SendRestockEmailJob, args: [ notification ])
    retry_at = enqueued_jobs.last[:at]
    assert retry_at > Time.current.to_f, "the retry should be scheduled in the future, not immediately"
  end

  test "connection refused (mail server down) counts as temporary too" do
    notification = pending_notification!(shop: @shop)
    smtp_fails_with(Errno::ECONNREFUSED.new)

    SendRestockEmailJob.perform_now(notification)

    assert_enqueued_with(job: SendRestockEmailJob)
    assert_equal "pending", notification.reload.status
  end

  test "temporary failures that never clear: 8 attempts, then marked failed and nothing reaches Sidekiq" do
    notification = pending_notification!(shop: @shop)
    smtp_fails_with(Net::SMTPServerBusy.new("421 4.7.0 Try again later"))

    # Block form performs each retry as soon as it's enqueued. No exception
    # escapes: the retry_on block handles the final failure.
    perform_enqueued_jobs { SendRestockEmailJob.perform_later(notification) }

    assert_performed_jobs 8
    notification.reload
    assert_equal "failed", notification.status
    assert_match "Net::SMTPServerBusy: 421", notification.error_message
  end

  test "permanent SMTP rejection (550): marked failed at once, no retry" do
    notification = pending_notification!(shop: @shop)
    smtp_fails_with(Net::SMTPFatalError.new("550 5.1.1 No such user"))

    SendRestockEmailJob.perform_now(notification)

    assert_no_enqueued_jobs only: SendRestockEmailJob
    assert_equal "failed", notification.reload.status
    assert_match "550 5.1.1", notification.error_message
  end

  test "an unexpected error (bad SMTP credentials) raises to Sidekiq and leaves the email pending" do
    notification = pending_notification!(shop: @shop)
    smtp_fails_with(Net::SMTPAuthenticationError.new("535 5.7.8 Authentication failed"))

    assert_raises(Net::SMTPAuthenticationError) { SendRestockEmailJob.perform_now(notification) }

    # Sidekiq's retry: 0 puts it in the Dead set. Still pending, so the sweeper
    # sends it once the credentials are fixed.
    assert_equal "pending", notification.reload.status
  end

  test "subscriber erased (customers/redact) before the job ran: discarded quietly" do
    notification = pending_notification!(shop: @shop)
    SendRestockEmailJob.perform_later(notification)
    notification.subscription.delete # the FK cascade deletes the notification too

    # The GlobalID no longer resolves: DeserializationError, which
    # ApplicationJob discards instead of raising.
    assert_no_emails { perform_enqueued_jobs }
    assert_not Notification.exists?(notification.id)
  end
end
