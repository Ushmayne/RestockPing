# frozen_string_literal: true

# Sends one restock email. Delivery is at-least-once: a subscriber is never
# silently skipped, and a duplicate is possible only in one narrow crash window
# (see #perform).
class SendRestockEmailJob < ApplicationJob
  queue_as :default

  # Temporary trouble: connection problems, or a 4xx SMTP reply ("421 try again
  # later", greylisting). Attempts 8 with polynomial backoff spreads the retries
  # over roughly 80 minutes. If they all fail, the block runs instead of
  # re-raising, so the notification is marked failed and nothing reaches Sidekiq.
  retry_on Net::SMTPServerBusy, *NETWORK_ERRORS, wait: :polynomially_longer, attempts: 8 do |job, error|
    job.arguments.first.mark_failed!(error)
  end

  # Permanent: a 5xx reply such as "550 no such mailbox". Retrying gets the same
  # answer, so record it and stop.
  discard_on Net::SMTPFatalError, Net::SMTPSyntaxError do |job, error|
    job.arguments.first.mark_failed!(error)
  end

  # Anything else (bad SMTP credentials, a bug) raises to Sidekiq, which puts the
  # job in the Dead set. The notification stays pending, so once the cause is
  # fixed the sweeper sends it.

  def perform(notification)
    # SELECT ... FOR UPDATE on this notification, held until the block ends.
    # A second copy of this job (Sidekiq redelivery, or the sweeper) waits here,
    # then sees status "sent" and does nothing. That's what stops two workers
    # from emailing the same subscriber at the same moment.
    notification.with_lock do
      next unless notification.pending?

      # Restocked, then sold out again before this email went (a flash sale, or
      # a long retry). Don't send people to a sold-out page. Re-arm the
      # subscription so the next restock emails them.
      unless notification.variant_still_in_stock?
        notification.update!(status: "canceled")
        notification.subscription.update!(status: "pending", notified_at: nil)
        next
      end

      # deliver_now, not deliver_later: delivery happens inside this job, so
      # SMTP errors raise here and the retry rules above apply to them.
      RestockMailer.back_in_stock(notification).deliver_now

      # The crash window: the mail server accepted the message, then this process
      # dies before COMMIT. The transaction rolls back, the status is still
      # "pending", and the retry sends a second copy. Marking "sent" *before*
      # delivering would close that window, but a crash would then drop the
      # email entirely. A rare duplicate is the better failure for a restock
      # alert than a missed sale.
      notification.update!(status: "sent", sent_at: Time.current)
    end
  end
end
