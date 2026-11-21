require "test_helper"

class WebhookDeliveryTest < ActiveSupport::TestCase
  def webhook(id = "delivery-1")
    ShopifyWebhook.new(topic: "inventory_levels/update", shop_domain: "regular-shop.myshopify.com",
                       webhook_id: id, triggered_at: Time.current, api_version: "2026-10", payload: {})
  end

  test "runs the block and records the delivery" do
    result = WebhookDelivery.process_once(webhook) { :did_work }

    assert_equal :did_work, result
    assert WebhookDelivery.exists?(webhook_id: "delivery-1")
  end

  test "a repeat of the same delivery does not run the block again" do
    WebhookDelivery.process_once(webhook) { :first }
    ran = false

    result = WebhookDelivery.process_once(webhook) { ran = true }

    assert_equal :duplicate, result
    refute ran
    assert_equal 1, WebhookDelivery.where(webhook_id: "delivery-1").count
  end

  test "if the block raises, neither the dedup row nor the side effects are kept" do
    shop = shops(:regular_shop)

    assert_raises(RuntimeError) do
      WebhookDelivery.process_once(webhook) do
        RestockEvent.create!(shop: shop, variant_gid: "gid://shopify/ProductVariant/1",
                             product_gid: "gid://shopify/Product/1", previous_quantity: 0, new_quantity: 3)
        raise "boom"
      end
    end

    refute WebhookDelivery.exists?(webhook_id: "delivery-1"), "a retry must be able to reprocess this"
    assert_equal 0, RestockEvent.count
  end
end
