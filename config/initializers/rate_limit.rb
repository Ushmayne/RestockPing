# frozen_string_literal: true

# Counter store for `rate_limit` in controllers. Kept separate from Rails.cache,
# which is a null store in development by default and would silently disable
# rate limiting.
#
# Redis, so every Puma worker on every host shares the same counts. A per-process
# MemoryStore would let a shopper make 5 requests *per process*.
#
# Same Redis as Sidekiq, under its own namespace. Sidekiq needs a `noeviction`
# Redis (evicting a queued job loses it). That's fine here because every
# rate-limit key is written with an expiry.
#
# If Redis is unreachable, RedisCacheStore logs the error and `increment` returns
# nil, which Rails' rate_limit treats as "under the limit". So rate limiting
# fails OPEN: signups keep working without it, rather than every signup failing
# because of a cache outage. The short timeouts keep a dead Redis from stalling
# each request.
#
# Tests use a MemoryStore, so the suite doesn't need a Redis server.
Rails.application.config.x.rate_limit_store =
  if Rails.env.test?
    ActiveSupport::Cache::MemoryStore.new
  else
    ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
      namespace: "restockping:rate_limit",
      connect_timeout: 1,
      read_timeout: 0.2,
      write_timeout: 0.2,
      reconnect_attempts: 0,
      error_handler: lambda { |method:, returning:, exception:|
        Rails.logger.warn("[rate_limit] Redis #{method} failed (#{exception.class}), allowing request")
      },
    )
  end
