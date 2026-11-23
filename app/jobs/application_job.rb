# frozen_string_literal: true

# Retry policy for every job.
#
# Active Job and Sidekiq both have a retry system. Stacked, a failing job would be
# retried by Active Job, then *each* final failure retried again by Sidekiq (25
# times over ~3 weeks by default). So exactly one of them owns retries:
#
#   - Active Job's retry_on decides what is worth retrying: errors listed in each
#     job, with backoff and a handler for when attempts run out.
#   - Sidekiq gets retry: 0. Anything Active Job didn't handle (a bug, a config
#     error) goes straight to Sidekiq's Dead set, where it's visible in the
#     Sidekiq UI and can be retried by hand once fixed.
class ApplicationJob < ActiveJob::Base
  sidekiq_options retry: 0

  # A job enqueued inside a DB transaction waits for COMMIT, and is dropped on
  # rollback. Otherwise a worker could pick it up before its records exist.
  self.enqueue_after_transaction_commit = true

  # Network failures worth another attempt, shared by jobs that call Shopify or SMTP.
  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
    Errno::ETIMEDOUT, Errno::EHOSTUNREACH, EOFError, SocketError, OpenSSL::SSL::SSLError
  ].freeze

  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, ActiveRecord::ConnectionNotEstablished,
           wait: :polynomially_longer, attempts: 5

  # Jobs take records as GlobalIDs. If the record is gone by the time the job
  # runs (app uninstalled, customers/redact), there's nothing left to do.
  discard_on ActiveJob::DeserializationError
end
