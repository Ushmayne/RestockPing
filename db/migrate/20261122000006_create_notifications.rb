# One restock email: this subscriber, for this restock. The delivery ledger that
# the send job checks before sending, and what Phase 5 attributes orders to.
class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :shop, null: false, foreign_key: { on_delete: :cascade }
      # Cascades: a customers/redact that deletes the subscription deletes its
      # notifications too, and a queued email for it finds nothing to send.
      t.references :subscription, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :restock_event, null: false, foreign_key: { on_delete: :cascade }, index: false
      # pending -> sent | failed | canceled
      t.string :status, null: false, default: "pending"
      t.datetime :sent_at
      t.string :error_message
      t.timestamps
    end
    # At most one email per subscriber per restock, however many times fan-out runs.
    add_index :notifications, [ :subscription_id, :restock_event_id ], unique: true
    # "Enqueue every pending email for this restock."
    add_index :notifications, [ :restock_event_id, :status ]
    # The sweeper: pending emails older than the retry window.
    add_index :notifications, [ :status, :created_at ]
  end
end
