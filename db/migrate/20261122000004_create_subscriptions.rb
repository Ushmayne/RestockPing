# A shopper asking to be emailed when a sold-out variant is back.
class CreateSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :subscriptions do |t|
      t.references :shop, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :variant_gid, null: false
      t.string :product_gid, null: false
      # Deterministically encrypted (see Subscription). Ciphertext is longer than
      # the address, so no length limit.
      t.string :email, null: false
      # Shopify customer id when the shopper was logged in (from the signed proxy params).
      t.bigint :customer_id
      t.string :status, null: false, default: "pending"
      t.datetime :notified_at
      t.timestamps
    end
    # One subscription per shopper per variant. Deterministic encryption keeps
    # equal emails equal in ciphertext, so this unique index still works.
    add_index :subscriptions, [ :shop_id, :variant_gid, :email ], unique: true
    # Phase 4: "who's waiting on this variant?"
    add_index :subscriptions, [ :shop_id, :variant_gid, :status ]
    # customers/redact lookups
    add_index :subscriptions, [ :shop_id, :customer_id ]
  end
end
