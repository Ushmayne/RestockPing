# Output of restock detection: "this variant just came back in stock".
# Phase 4 turns these into emails for the variant's subscribers.
class CreateRestockEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :restock_events do |t|
      t.references :shop, null: false, foreign_key: { on_delete: :cascade }
      t.string :variant_gid, null: false
      t.string :product_gid, null: false
      t.integer :previous_quantity, null: false
      t.integer :new_quantity, null: false
      t.timestamps
    end
    add_index :restock_events, [ :shop_id, :variant_gid, :created_at ]
  end
end
