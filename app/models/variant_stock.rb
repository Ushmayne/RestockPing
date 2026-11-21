# frozen_string_literal: true

# The last total stock we saw for one variant, used to detect "back in stock".
class VariantStock < ApplicationRecord
  belongs_to :shop

  # Records a fresh stock reading for a variant. Returns a RestockEvent if the
  # reading shows the variant coming back in stock (<= 0 before, > 0 now),
  # otherwise nil.
  #
  # Must run inside a transaction: the row lock below is held until it commits.
  def self.observe!(shop:, variant_gid:, product_gid:, inventory_item_gid:, quantity:, observed_at:)
    # 1. Make sure the row exists, so there is something to lock. A plain
    #    find_or_create_by would race (two inserts, one UniqueViolation).
    #    INSERT ... ON CONFLICT DO NOTHING is atomic. It returns the new id
    #    only if *this* call inserted the row.
    inserted = insert(
      { shop_id: shop.id, variant_gid: variant_gid, product_gid: product_gid,
        inventory_item_gid: inventory_item_gid, quantity: quantity, observed_at: observed_at },
      unique_by: %i[shop_id variant_gid],
    )
    # First sighting: this reading is the baseline. With no previous value there's
    # no "it was 0 before" to claim, so no restock.
    return nil if inserted.rows.any?

    # 2. SELECT ... FOR UPDATE. A concurrent webhook for the same variant blocks
    #    here until we commit, then reads the quantity we wrote. Without the lock,
    #    two webhooks could both read 0 and both create a RestockEvent.
    stock = lock.find_by!(shop_id: shop.id, variant_gid: variant_gid)

    # 3. Stale-read guard. Our GraphQL call happened before we took the lock, so a
    #    slower request may get here after a newer reading was already saved.
    #    Writing it would move the stored quantity back in time.
    return nil if stock.observed_at > observed_at

    previous = stock.quantity
    stock.update!(quantity: quantity, observed_at: observed_at, product_gid: product_gid,
                  inventory_item_gid: inventory_item_gid)

    # 4. The restock rule. "<= 0" rather than "== 0" because oversold variants
    #    go negative, and those were out of stock too.
    return nil unless previous <= 0 && quantity.positive?

    RestockEvent.create!(shop: shop, variant_gid: variant_gid, product_gid: product_gid,
                         previous_quantity: previous, new_quantity: quantity)
  end
end
