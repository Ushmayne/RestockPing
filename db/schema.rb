# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_22_000006) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "notifications", force: :cascade do |t|
    t.bigint "shop_id", null: false
    t.bigint "subscription_id", null: false
    t.bigint "restock_event_id", null: false
    t.string "status", default: "pending", null: false
    t.datetime "sent_at"
    t.string "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["restock_event_id", "status"], name: "index_notifications_on_restock_event_id_and_status"
    t.index ["shop_id"], name: "index_notifications_on_shop_id"
    t.index ["status", "created_at"], name: "index_notifications_on_status_and_created_at"
    t.index ["subscription_id", "restock_event_id"], name: "index_notifications_on_subscription_id_and_restock_event_id", unique: true
  end

  create_table "restock_events", force: :cascade do |t|
    t.bigint "shop_id", null: false
    t.string "variant_gid", null: false
    t.string "product_gid", null: false
    t.integer "previous_quantity", null: false
    t.integer "new_quantity", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "shop_name"
    t.string "shop_contact_email"
    t.string "product_title"
    t.string "variant_title"
    t.string "product_url"
    t.string "image_url"
    t.datetime "fanned_out_at"
    t.index ["created_at"], name: "index_restock_events_awaiting_fan_out", where: "(fanned_out_at IS NULL)"
    t.index ["shop_id", "variant_gid", "created_at"], name: "index_restock_events_on_shop_id_and_variant_gid_and_created_at"
    t.index ["shop_id"], name: "index_restock_events_on_shop_id"
  end

  create_table "shops", force: :cascade do |t|
    t.string "shopify_domain", null: false
    t.string "shopify_token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "access_scopes", default: "", null: false
    t.datetime "expires_at"
    t.string "refresh_token"
    t.datetime "refresh_token_expires_at"
    t.index ["shopify_domain"], name: "index_shops_on_shopify_domain", unique: true
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "shop_id", null: false
    t.string "variant_gid", null: false
    t.string "product_gid", null: false
    t.string "email", null: false
    t.bigint "customer_id"
    t.string "status", default: "pending", null: false
    t.datetime "notified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["shop_id", "customer_id"], name: "index_subscriptions_on_shop_id_and_customer_id"
    t.index ["shop_id", "variant_gid", "email"], name: "index_subscriptions_on_shop_id_and_variant_gid_and_email", unique: true
    t.index ["shop_id", "variant_gid", "status"], name: "index_subscriptions_on_shop_id_and_variant_gid_and_status"
  end

  create_table "variant_stocks", force: :cascade do |t|
    t.bigint "shop_id", null: false
    t.string "variant_gid", null: false
    t.string "product_gid", null: false
    t.string "inventory_item_gid", null: false
    t.integer "quantity", null: false
    t.datetime "observed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["shop_id", "inventory_item_gid"], name: "index_variant_stocks_on_shop_id_and_inventory_item_gid"
    t.index ["shop_id", "variant_gid"], name: "index_variant_stocks_on_shop_id_and_variant_gid", unique: true
    t.index ["shop_id"], name: "index_variant_stocks_on_shop_id"
  end

  create_table "webhook_deliveries", force: :cascade do |t|
    t.string "webhook_id", null: false
    t.string "topic", null: false
    t.string "shop_domain", null: false
    t.datetime "triggered_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_webhook_deliveries_on_created_at"
    t.index ["webhook_id"], name: "index_webhook_deliveries_on_webhook_id", unique: true
  end

  add_foreign_key "notifications", "restock_events", on_delete: :cascade
  add_foreign_key "notifications", "shops", on_delete: :cascade
  add_foreign_key "notifications", "subscriptions", on_delete: :cascade
  add_foreign_key "restock_events", "shops", on_delete: :cascade
  add_foreign_key "subscriptions", "shops", on_delete: :cascade
  add_foreign_key "variant_stocks", "shops", on_delete: :cascade
end
