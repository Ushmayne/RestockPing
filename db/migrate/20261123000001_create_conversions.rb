# A paid order attributed to a restock email.
#
# Deliberately holds no customer data: no buyer email, name or address. The
# link to the shopper goes through notification -> subscription, so erasing
# the subscription (customers/redact) erases this row too.
class CreateConversions < ActiveRecord::Migration[8.1]
  def change
    create_table :conversions do |t|
      t.references :shop, null: false, foreign_key: { on_delete: :cascade }, index: false
      # One conversion per email: the first paid order after it counts, and a
      # replayed or repeated orders/paid can't count it twice.
      t.references :notification, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.bigint :order_id, null: false
      t.string :order_name                                 # "#1001", what the merchant sees
      # Revenue from the restocked variant's line items only, after discounts,
      # in the shop's currency. Scale 4 covers 3-decimal currencies (KWD, BHD).
      t.decimal :revenue, precision: 15, scale: 4, null: false
      t.string :currency, null: false
      # Shopify test orders (bogus gateway). Not called `test`, which is a Kernel method.
      t.boolean :test_order, null: false, default: false
      t.datetime :ordered_at, null: false
      t.datetime :cancelled_at
      t.timestamps
    end
    # orders/cancelled lookups, and "which orders converted" in Phase 6.
    add_index :conversions, [ :shop_id, :order_id ]
  end
end
