require "test_helper"

class ShopifyAppProxyVerifierTest < ActiveSupport::TestCase
  include ShopifyAppProxyHelper

  # Shopify's own worked examples (shopify.dev "Authenticate app proxies"):
  # secret "hush", and the signature values printed in the docs. These pin the
  # algorithm to Shopify's, independently of our helper.
  DOCS_SECRET = "hush"
  DOCS_TIME = Time.at(1_317_327_555)
  DOCS_LOGGED_IN = "extra=1&extra=2&shop=shop-name.myshopify.com&logged_in_customer_id=1" \
                   "&path_prefix=%2Fapps%2Fawesome_reviews&timestamp=1317327555" \
                   "&signature=4c68c8624d737112c91818c11017d24d334b524cb5c2b8ba08daa056f7395ddb"
  DOCS_ANONYMOUS = "extra=1&extra=2&shop=shop-name.myshopify.com&logged_in_customer_id=" \
                   "&path_prefix=%2Fapps%2Fawesome_reviews&timestamp=1317327555" \
                   "&signature=e072b6d7e6622d85912a5214b860d3100dc1e73d9bc29f43796ac8c9ff8093cb"

  def valid?(query, now: DOCS_TIME, secrets: [ DOCS_SECRET ])
    ShopifyAppProxyVerifier.valid?(query_string: query, now: now, secrets: secrets)
  end

  test "accepts Shopify's documented example (logged-in customer, repeated param)" do
    assert valid?(DOCS_LOGGED_IN)
  end

  test "accepts Shopify's documented example (anonymous: empty param still signed)" do
    assert valid?(DOCS_ANONYMOUS)
  end

  test "rejects a changed param: a different logged-in customer" do
    refute valid?(DOCS_LOGGED_IN.sub("logged_in_customer_id=1", "logged_in_customer_id=2"))
  end

  test "rejects a changed shop" do
    refute valid?(DOCS_LOGGED_IN.sub("shop-name.myshopify.com", "victim.myshopify.com"))
  end

  test "rejects a missing signature or the wrong secret" do
    refute valid?(DOCS_LOGGED_IN.sub(/&signature=\h+/, ""))
    refute valid?(DOCS_LOGGED_IN, secrets: [ "not-hush" ])
  end

  test "rejects a replayed URL once the timestamp is older than 5 minutes" do
    assert valid?(DOCS_LOGGED_IN, now: DOCS_TIME + 4.minutes)
    refute valid?(DOCS_LOGGED_IN, now: DOCS_TIME + 6.minutes)
  end

  test "accepts the previous secret during a secret rotation" do
    assert valid?(DOCS_LOGGED_IN, secrets: [ "new-secret", DOCS_SECRET ])
  end

  test "our test helper produces signatures the verifier accepts" do
    query = app_proxy_query(shop: "regular-shop.myshopify.com", customer_id: 7)

    assert ShopifyAppProxyVerifier.valid?(query_string: query)
  end
end
