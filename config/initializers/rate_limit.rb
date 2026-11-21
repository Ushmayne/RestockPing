# frozen_string_literal: true

# Counter store for `rate_limit` in controllers. Kept separate from Rails.cache,
# which is a null store in development by default and would silently disable
# rate limiting.
#
# MemoryStore is per process. That's fine for one dev server, but with several
# Puma workers each would count separately. Phase 4 brings Redis, and this
# becomes a RedisCacheStore so the limit holds across every process.
Rails.application.config.x.rate_limit_store = ActiveSupport::Cache::MemoryStore.new
