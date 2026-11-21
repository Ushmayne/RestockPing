# frozen_string_literal: true

# Storefront signups, reached through Shopify's app proxy:
#   POST https://<shop>/apps/restockping/subscriptions
#     -> POST <app>/proxy/subscriptions?shop=...&logged_in_customer_id=...&timestamp=...&signature=...
#
# ActionController::API: app proxies strip cookies, so there's no session or CSRF
# token. Authenticity comes from the signed query string instead.
class ProxySubscriptionsController < ActionController::API
  before_action :verify_app_proxy_signature!
  before_action :load_shop

  # Two limits (the store moves to Redis in Phase 4 so all processes share counts):
  #  - per shopper: requests reach us via Shopify's proxy (and, in production, our
  #    load balancer). request.remote_ip takes the rightmost untrusted
  #    X-Forwarded-For entry, which is Shopify's IP, shared by every shopper. The
  #    first entry is the shopper as Shopify saw them. A client can prepend fake
  #    entries, though, so...
  #  - per shop: a ceiling that can't be dodged by rotating IPs. Signup sends no
  #    email, so the worst abuse is junk rows, and this caps it.
  RATE_LIMITED = -> { render json: { error: "rate_limited" }, status: :too_many_requests }
  rate_limit to: 5, within: 1.minute, only: :create, name: "per-shopper",
             by: -> { "#{signed_param("shop")}:#{shopper_ip}" },
             with: RATE_LIMITED, store: Rails.application.config.x.rate_limit_store
  rate_limit to: 120, within: 1.minute, only: :create, name: "per-shop",
             by: -> { signed_param("shop").to_s },
             with: RATE_LIMITED, store: Rails.application.config.x.rate_limit_store

  def create
    # Honeypot: a field hidden from people. Bots that fill every input get the
    # normal success response, so they learn nothing, and nothing is stored.
    return render(json: { status: "subscribed" }) if params[:website].present?

    result = SubscribeToRestock.new(shop: @shop).call(
      variant_id: params[:variant_id],
      email: params[:email],
      customer_id: signed_param("logged_in_customer_id"),
    )

    case result.status
    # Same response whether the email was new or already subscribed, so the form
    # can't be used to probe whether someone signed up.
    when :subscribed then render json: { status: "subscribed" }
    when :invalid_email then render json: { error: "invalid_email" }, status: :unprocessable_content
    when :in_stock then render json: { error: "in_stock" }, status: :unprocessable_content
    else render json: { error: "unavailable" }, status: :unprocessable_content
    end
  end

  private

  def verify_app_proxy_signature!
    return if ShopifyAppProxyVerifier.valid?(query_string: request.query_string)

    head :unauthorized
  end

  # Identity params come from the signed query string ONLY, never from `params`.
  # Rails merges query over body (query wins), but a key MISSING from the query
  # silently falls back to the unsigned POST body. If Shopify ever omits
  # logged_in_customer_id, params[:logged_in_customer_id] would be whatever the
  # shopper typed.
  def signed_param(name)
    request.query_parameters[name].presence
  end

  def load_shop
    @shop = Shop.find_by(shopify_domain: signed_param("shop"))
    head :not_found if @shop.nil?
  end

  def shopper_ip
    request.headers["X-Forwarded-For"].to_s.split(",").first&.strip.presence || request.remote_ip
  end
end
