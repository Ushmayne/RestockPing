# frozen_string_literal: true

# One restock email to one subscriber. Created by NotifySubscribersJob, sent by
# SendRestockEmailJob.
#
#   pending  -> sent      delivered to the mail server
#            -> failed    permanent rejection, or retries ran out
#            -> canceled  sold out again before we got to it (subscription re-armed)
class Notification < ApplicationRecord
  STATUSES = %w[pending sent failed canceled].freeze

  belongs_to :shop
  belongs_to :subscription
  belongs_to :restock_event

  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }

  def pending?
    status == "pending"
  end

  # Called from the retry/discard handlers, outside the send lock. The status
  # condition makes it a no-op if a concurrent copy of the job already sent it.
  def mark_failed!(error)
    Notification.pending.where(id: id).update_all(
      status: "failed", error_message: "#{error.class}: #{error.message}".truncate(500), updated_at: Time.current,
    )
  end

  # Only cheap, local data here: VariantStock is kept current by the inventory
  # webhook, so this costs no API call per email.
  def variant_still_in_stock?
    VariantStock.where(shop_id: shop_id, variant_gid: restock_event.variant_gid).pick(:quantity).to_i.positive?
  end
end
