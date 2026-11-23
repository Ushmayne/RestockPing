# frozen_string_literal: true

# A shopper waiting for a sold-out variant to come back.
class Subscription < ApplicationRecord
  STATUSES = %w[pending notified].freeze

  belongs_to :shop
  has_many :notifications, dependent: :delete_all

  # Emails are customer personal data, so they're encrypted at rest. Deterministic
  # encryption means the same address always gives the same ciphertext, which keeps
  # the unique index and the customers/redact lookup (WHERE email = ?) working.
  # The trade-off: equal emails are recognisable as equal in the DB, without
  # revealing the address itself.
  encrypts :email, deterministic: true
  # Runs before encryption and before queries, so " Ana@Example.com " and
  # "ana@example.com" are the same subscriber.
  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, length: { maximum: 254 },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :variant_gid, :product_gid, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :pending, -> { where(status: "pending") }
end
