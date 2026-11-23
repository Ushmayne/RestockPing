# frozen_string_literal: true

# Safety net for jobs that were lost rather than failed.
#
# Sidekiq (open-source) takes a job off the Redis queue when a worker starts it.
# If the process is killed mid-job (OOM, a deploy that doesn't wait, a crashed
# host), that job is gone. An enqueue can also fail outright when Redis is down
# just after a webhook's transaction committed. In both cases the database still
# says what should have happened, so this job re-enqueues from the database.
#
# Run it every few minutes from a scheduler (cron, or `bin/rails
# restockping:requeue_stalled`). Re-enqueueing something that isn't really lost
# is harmless, since both jobs are idempotent.
class RequeueStalledNotificationsJob < ApplicationJob
  queue_as :default

  # A fan-out normally finishes in seconds. 15 minutes means it was lost (or is
  # retrying a Shopify outage, in which case an extra copy just retries too).
  FAN_OUT_STALLED_AFTER = 15.minutes
  # Longer than SendRestockEmailJob's whole retry schedule (~80 minutes), so this
  # never races a notification that's still waiting for its next retry.
  SEND_STALLED_AFTER = 2.hours
  # Past this, a "back in stock" email is more confusing than useful.
  GIVE_UP_AFTER = 3.days

  def perform
    now = Time.current

    events = RestockEvent.where(fanned_out_at: nil, created_at: (now - GIVE_UP_AFTER)..(now - FAN_OUT_STALLED_AFTER))
    ActiveJob.perform_all_later(events.map { |event| NotifySubscribersJob.new(event) })

    notifications = Notification.pending.where(created_at: (now - GIVE_UP_AFTER)..(now - SEND_STALLED_AFTER))
    ActiveJob.perform_all_later(notifications.map { |notification| SendRestockEmailJob.new(notification) })

    Rails.logger.info("[sweeper] requeued #{events.size} fan-out(s), #{notifications.size} email(s)")
  end
end
