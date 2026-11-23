# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  # The address must be on a domain we control and have authenticated (SPF/DKIM),
  # or receiving servers treat the mail as spoofed. So we never send *from* the
  # merchant's address. Their store name goes in the display name and their
  # contact address in Reply-To (see RestockMailer).
  default from: ENV.fetch("MAIL_FROM", "alerts@restockping.example")
  layout "mailer"
end
