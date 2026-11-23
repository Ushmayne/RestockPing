# frozen_string_literal: true

# A paid order that followed a restock email (see AttributeOrder).
class Conversion < ApplicationRecord
  belongs_to :shop
  belongs_to :notification

  # What Phase 6 reports: not cancelled, and not a Shopify test order.
  scope :counted, -> { where(cancelled_at: nil, test_order: false) }
end
