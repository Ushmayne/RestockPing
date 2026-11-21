require "test_helper"

# The test environment allows every host, so this builds Rails' real
# HostAuthorization middleware with the app's exclusion rule and checks it the way
# development and production run it.
class HostAuthorizationTest < ActiveSupport::TestCase
  OK_APP = ->(_env) { [ 200, {}, [ "reached the app" ] ] }

  def middleware
    ActionDispatch::HostAuthorization.new(
      OK_APP,
      [ "restockping.example.com" ], # the app's own host
      **Rails.application.config.host_authorization,
    )
  end

  def status_for(path, forwarded_host:)
    env = Rack::MockRequest.env_for("https://restockping.example.com#{path}",
                                    "HTTP_X_FORWARDED_HOST" => forwarded_host)
    middleware.call(env).first
  end

  test "app proxy requests carrying the shop's domain as host get through to the signature check" do
    assert_equal 200, status_for("/proxy/subscriptions?shop=x", forwarded_host: "some-store.myshopify.com")
  end

  test "other routes with a foreign host are still blocked" do
    assert_equal 403, status_for("/", forwarded_host: "some-store.myshopify.com")
    assert_equal 403, status_for("/api/webhooks", forwarded_host: "evil.example")
  end

  test "the exclusion is a path prefix match, not a substring match" do
    assert_equal 403, status_for("/home/proxy/x", forwarded_host: "evil.example")
  end
end
