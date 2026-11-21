# One row per processed webhook delivery. The unique index on webhook_id is the
# real dedup guarantee: it holds even when two retries of the same delivery arrive
# at the same instant, which an "exists?" check alone can't.
class CreateWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_deliveries do |t|
      t.string :webhook_id, null: false
      t.string :topic, null: false
      t.string :shop_domain, null: false
      t.datetime :triggered_at
      t.timestamps
    end
    add_index :webhook_deliveries, :webhook_id, unique: true
    add_index :webhook_deliveries, :created_at # retention cleanup (Phase 4)
  end
end
