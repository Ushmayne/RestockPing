# Last known total stock per variant. Shopify's inventory webhook only carries the
# new value, so "was it 0 before?" can only be answered from our own record.
class CreateVariantStocks < ActiveRecord::Migration[8.1]
  def change
    create_table :variant_stocks do |t|
      t.references :shop, null: false, foreign_key: { on_delete: :cascade }
      t.string :variant_gid, null: false
      t.string :product_gid, null: false
      t.string :inventory_item_gid, null: false
      t.integer :quantity, null: false
      # When we asked Shopify for this quantity. Used to discard stale reads.
      t.datetime :observed_at, null: false, precision: 6
      t.timestamps
    end
    add_index :variant_stocks, [ :shop_id, :variant_gid ], unique: true
    add_index :variant_stocks, [ :shop_id, :inventory_item_gid ]
  end
end
