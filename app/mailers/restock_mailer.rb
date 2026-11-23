# frozen_string_literal: true

class RestockMailer < ApplicationMailer
  def back_in_stock(notification)
    @event = notification.restock_event
    @product_name = [ @event.product_title, @event.variant_title ].compact_blank.join(" - ")

    # A fixed Message-ID per notification. If the crash window in
    # SendRestockEmailJob ever produces a second copy, both copies carry the same
    # ID, and mail clients that de-duplicate on Message-ID (Gmail does) show one.
    headers["Message-ID"] = "<restock-notification-#{notification.id}@#{message_id_domain}>"

    mail(
      to: notification.subscription.email,
      from: email_address_with_name(self.class.default[:from], @event.shop_name.presence || "RestockPing"),
      reply_to: @event.shop_contact_email.presence,
      subject: "#{@product_name} is back in stock",
    )
  end

  private

  def message_id_domain
    Mail::Address.new(self.class.default[:from]).domain || "restockping.example"
  end
end
