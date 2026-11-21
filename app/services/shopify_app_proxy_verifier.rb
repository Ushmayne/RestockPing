# frozen_string_literal: true

require "openssl"

# Checks that a storefront request really came through Shopify's app proxy.
#
# Shopify adds shop, logged_in_customer_id, path_prefix, timestamp and signature
# to the query string. The signature is HMAC-SHA256 (hex) over the other query
# params: each one written as "key=value" (repeated keys' values joined with ","),
# sorted, and concatenated with no separator.
#
# Differences from webhook verification:
#   - only the QUERY STRING is signed, not the body. Anything in the POST body is
#     unauthenticated shopper input.
#   - hex digest instead of base64
#   - the timestamp is signed, so we can reject replays of an old captured URL
class ShopifyAppProxyVerifier
  MAX_AGE = 5.minutes

  def self.valid?(query_string:, now: Time.current, secrets: default_secrets, max_age: MAX_AGE)
    # parse_query (not Rails params) keeps repeated keys as arrays, which the
    # signature depends on, and never mixes in body params.
    params = Rack::Utils.parse_query(query_string.to_s)
    signature = params.delete("signature")
    return false unless signature.is_a?(String) && signature.present?

    message = params.map { |key, value| "#{key}=#{Array(value).join(",")}" }.sort.join
    signed = secrets.compact_blank.any? do |secret|
      ActiveSupport::SecurityUtils.secure_compare(OpenSSL::HMAC.hexdigest("SHA256", secret, message), signature)
    end
    return false unless signed

    timestamp = Integer(params["timestamp"].to_s, exception: false)
    # abs: tolerate small clock skew in either direction.
    timestamp.present? && (now.to_i - timestamp).abs <= max_age.to_i
  end

  def self.default_secrets
    [ ShopifyApp.configuration.secret, ShopifyApp.configuration.old_secret ]
  end
end
