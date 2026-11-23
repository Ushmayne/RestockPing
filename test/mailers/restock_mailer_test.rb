require "test_helper"

class RestockMailerTest < ActionMailer::TestCase
  include RestockEmailHelper

  setup do
    @notification = pending_notification!(shop: shops(:regular_shop))
    @event = @notification.restock_event
  end

  test "comes from our address under the store's name, replies go to the store" do
    mail = RestockMailer.back_in_stock(@notification)

    assert_equal [ "ana@example.com" ], mail.to
    assert_equal [ "alerts@restockping.example" ], mail.from
    assert_equal "Snow Co", mail[:from].display_names.first
    assert_equal [ "help@snow.example" ], mail.reply_to
    assert_equal "Liquid Snowboard - 158cm is back in stock", mail.subject
  end

  test "links to the product with the variant preselected, in both parts" do
    mail = RestockMailer.back_in_stock(@notification)

    assert_includes mail.html_part.body.to_s, 'href="https://snow.example/products/liquid?variant=4242"'
    assert_includes mail.text_part.body.to_s, "https://snow.example/products/liquid?variant=4242"
    assert_includes mail.html_part.body.to_s, "https://cdn.shopify.com/liquid.jpg"
  end

  test "a stable Message-ID per notification, so a duplicate send can be collapsed by the mail client" do
    first = RestockMailer.back_in_stock(@notification)
    second = RestockMailer.back_in_stock(@notification)

    assert_equal "restock-notification-#{@notification.id}@restockping.example", first.message_id
    assert_equal first.message_id, second.message_id
  end

  test "merchant-controlled text is escaped in HTML" do
    @event.update!(product_title: "<script>alert(1)</script> Board")

    html = RestockMailer.back_in_stock(@notification).html_part.body.to_s

    assert_not_includes html, "<script>"
    assert_includes html, "&lt;script&gt;"
  end

  test "no image and no variant title: still a sensible email" do
    @event.update!(image_url: nil, variant_title: nil, shop_contact_email: nil)

    mail = RestockMailer.back_in_stock(@notification)

    assert_equal "Liquid Snowboard is back in stock", mail.subject
    assert_not_includes mail.html_part.body.to_s, "<img"
    assert_empty Array(mail.reply_to)
  end
end
