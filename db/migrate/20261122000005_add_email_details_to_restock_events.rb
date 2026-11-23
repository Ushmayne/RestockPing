# Phase 4: what the restock email shows, captured once per restock instead of
# once per email, plus a marker for "subscribers have been claimed".
class AddEmailDetailsToRestockEvents < ActiveRecord::Migration[8.1]
  def change
    change_table :restock_events, bulk: true do |t|
      # Snapshot from the Admin API, taken by NotifySubscribersJob. Storing it means
      # 500 subscribers cost one GraphQL call, not 500, and every email for this
      # restock says the same thing even if the merchant edits the product meanwhile.
      t.string :shop_name
      t.string :shop_contact_email
      t.string :product_title
      t.string :variant_title
      t.string :product_url
      t.string :image_url
      # Set in the same transaction that claims the subscribers. NULL long after
      # created_at means the fan-out job was lost (see RequeueStalledNotificationsJob).
      t.datetime :fanned_out_at
    end
    # The sweeper's query. Partial, so it only indexes the few rows still waiting.
    add_index :restock_events, :created_at, where: "fanned_out_at IS NULL",
                                            name: "index_restock_events_awaiting_fan_out"
  end
end
