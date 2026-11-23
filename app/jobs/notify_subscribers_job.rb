# frozen_string_literal: true

# Fan-out: turns one RestockEvent into one Notification (and one send job) per
# subscriber waiting on that variant.
#
# Safe to run any number of times for the same event. Sidekiq delivers a job at
# least once, and the sweeper may enqueue a second copy on purpose.
class NotifySubscribersJob < ApplicationJob
  queue_as :default

  class GraphqlError < StandardError; end

  # THROTTLED, 5xx and network trouble from the Admin API. Attempts 8 with
  # polynomial backoff is roughly 80 minutes of retrying before giving up (and
  # going to the Dead set, since there's no handler block).
  retry_on GraphqlError, ShopifyAPI::Errors::HttpResponseError, *NETWORK_ERRORS,
           wait: :polynomially_longer, attempts: 8

  QUERY = <<~GRAPHQL
    query RestockPingEmailDetails($id: ID!) {
      shop { name contactEmail primaryDomain { url } }
      productVariant(id: $id) {
        title
        image { url }
        product { title handle featuredMedia { preview { image { url } } } }
      }
    }
  GRAPHQL

  def perform(event)
    # 1. Network call before any transaction or lock. Skipped on a re-run that
    #    already has the snapshot.
    return if event.product_title.nil? && !snapshot_email_details!(event)

    # 2. Claim the subscribers and create their notifications, atomically.
    claim_subscribers(event)

    # 3. Enqueue a send for every notification of this event that's still
    #    pending. On a re-run this includes ones a previous run created but
    #    crashed before enqueueing. Duplicate send jobs are harmless: the send
    #    job checks the status under a row lock.
    jobs = event.notifications.pending.map { |notification| SendRestockEmailJob.new(notification) }
    ActiveJob.perform_all_later(jobs) # one Redis round trip for all of them
  end

  private

  def claim_subscribers(event)
    Subscription.transaction do
      # SELECT ... FOR UPDATE on the waiting subscribers. Two restocks of the same
      # variant in quick succession (restock, sell out, restock) give two fan-out
      # jobs. The second blocks here until the first commits. Postgres then
      # re-checks `status = 'pending'` against the committed rows (READ COMMITTED
      # re-evaluates the WHERE on rows it waited for), finds them notified, and
      # skips them. So each subscriber is claimed by exactly one restock.
      ids = event.shop.subscriptions.pending.where(variant_gid: event.variant_gid).lock.pluck(:id)

      if ids.any?
        now = Time.current
        Subscription.where(id: ids).update_all(status: "notified", notified_at: now, updated_at: now)
        # unique_by makes a second insert for the same (subscription, event) a no-op.
        Notification.insert_all(
          ids.map do |subscription_id|
            { shop_id: event.shop_id, subscription_id: subscription_id, restock_event_id: event.id, status: "pending" }
          end,
          unique_by: %i[subscription_id restock_event_id],
        )
      end
      event.update!(fanned_out_at: Time.current) if event.fanned_out_at.nil?
    end
  end

  # Returns false if the variant no longer exists.
  def snapshot_email_details!(event)
    data = fetch_email_details(event)
    variant = data["productVariant"]
    if variant.nil?
      # Variant deleted since the restock. Nobody can buy it, so nobody gets an
      # email, and the subscribers stay pending (harmless). fanned_out_at stops
      # the sweeper from retrying this event.
      Rails.logger.info("[restock] variant #{event.variant_gid} no longer exists, skipping fan-out")
      event.update!(fanned_out_at: Time.current)
      return false
    end

    product = variant["product"]
    event.update!(
      shop_name: data.dig("shop", "name"),
      shop_contact_email: data.dig("shop", "contactEmail"),
      product_title: product["title"],
      # "Default Title" is what Shopify calls the only variant of a product with
      # no options. Saying "Default Title is back in stock" would be silly.
      variant_title: (variant["title"] unless variant["title"] == "Default Title"),
      # Built from the primary domain and handle rather than onlineStoreUrl,
      # which is null on password-protected (e.g. development) stores.
      # ?variant= preselects the restocked variant on the product page.
      product_url: "#{data.dig("shop", "primaryDomain", "url")}/products/#{product["handle"]}" \
                   "?variant=#{event.variant_gid.split("/").last}",
      image_url: variant.dig("image", "url") || product.dig("featuredMedia", "preview", "image", "url"),
    )
    true
  end

  def fetch_email_details(event)
    # Refreshes an expired access token first, under a row lock (Phase 1).
    event.shop.with_shopify_session do |session|
      response = ShopifyAPI::Clients::Graphql::Admin.new(session: session)
                                                    .query(query: QUERY, variables: { id: event.variant_gid })
      errors = response.body["errors"]
      raise GraphqlError, errors.to_json if errors.present?

      response.body["data"]
    end
  end
end
