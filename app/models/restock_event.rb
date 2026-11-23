# frozen_string_literal: true

# "This variant just came back in stock." Created by VariantStock.observe!
# inside the webhook's transaction.
class RestockEvent < ApplicationRecord
  belongs_to :shop
  has_many :notifications, dependent: :delete_all

  # after_create_commit, not after_create: the event is created inside the
  # webhook transaction, and a job enqueued before COMMIT could run before the
  # row is visible to the worker's connection (or after a rollback, for an
  # event that never existed). Redis isn't part of the Postgres transaction, so
  # "enqueue after commit" is the only safe order.
  #
  # The gap that leaves: COMMIT succeeds, then the enqueue fails (Redis down, or
  # the process dies right here). fanned_out_at stays NULL and
  # RequeueStalledNotificationsJob picks the event up.
  after_create_commit -> { NotifySubscribersJob.perform_later(self) }
end
