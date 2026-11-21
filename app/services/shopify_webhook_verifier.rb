# frozen_string_literal: true

require "openssl"
require "base64"

# Checks that a webhook really came from Shopify.
#
# Shopify computes HMAC-SHA256 over the *raw* request body, keyed with our app's
# client secret, and sends it base64-encoded in X-Shopify-Hmac-Sha256. Only
# Shopify and our app know the secret, so a matching digest proves the sender
# and that the body wasn't altered.
class ShopifyWebhookVerifier
  # secrets: current secret first. The old one is accepted during a secret
  # rotation, since Shopify can take up to an hour to switch signing secrets.
  def self.valid?(raw_body:, hmac_header:, secrets: default_secrets)
    return false if hmac_header.blank? || raw_body.nil?

    secrets.compact_blank.any? do |secret|
      expected = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, raw_body))
      # Constant-time comparison. A plain == stops at the first differing byte,
      # and that timing difference lets an attacker guess a valid HMAC byte by byte.
      ActiveSupport::SecurityUtils.secure_compare(expected, hmac_header)
    end
  end

  def self.default_secrets
    [ ShopifyApp.configuration.secret, ShopifyApp.configuration.old_secret ]
  end
end
