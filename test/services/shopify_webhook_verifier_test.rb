require "test_helper"

class ShopifyWebhookVerifierTest < ActiveSupport::TestCase
  include ShopifyWebhookHelper

  BODY = '{"inventory_item_id":271878346596884015,"location_id":24826418,"available":10}'

  test "accepts a body signed with our client secret" do
    assert ShopifyWebhookVerifier.valid?(raw_body: BODY, hmac_header: shopify_hmac(BODY))
  end

  test "rejects a body signed with a different secret" do
    forged = shopify_hmac(BODY, secret: "attacker-guess")

    refute ShopifyWebhookVerifier.valid?(raw_body: BODY, hmac_header: forged)
  end

  test "rejects a body changed after signing, even by one character" do
    signature = shopify_hmac(BODY)
    tampered = BODY.sub('"available":10', '"available":99')

    refute ShopifyWebhookVerifier.valid?(raw_body: tampered, hmac_header: signature)
  end

  test "rejects a re-serialised body: the digest is over exact bytes, not JSON meaning" do
    signature = shopify_hmac(BODY)
    same_json_different_bytes = JSON.pretty_generate(JSON.parse(BODY))

    refute ShopifyWebhookVerifier.valid?(raw_body: same_json_different_bytes, hmac_header: signature)
  end

  test "rejects a missing or blank header" do
    refute ShopifyWebhookVerifier.valid?(raw_body: BODY, hmac_header: nil)
    refute ShopifyWebhookVerifier.valid?(raw_body: BODY, hmac_header: "")
  end

  test "rejects garbage of a different length without raising" do
    refute ShopifyWebhookVerifier.valid?(raw_body: BODY, hmac_header: "abc")
  end

  test "accepts the previous secret during a secret rotation" do
    signed_with_old = shopify_hmac(BODY, secret: "old-secret")

    assert ShopifyWebhookVerifier.valid?(raw_body: BODY, hmac_header: signed_with_old,
                                         secrets: [ "new-secret", "old-secret" ])
    refute ShopifyWebhookVerifier.valid?(raw_body: BODY, hmac_header: signed_with_old,
                                         secrets: [ "new-secret", "" ])
  end
end
