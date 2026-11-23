require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module RestockPing
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # App proxy requests arrive with X-Forwarded-Host set to the *shop's* domain
    # (e.g. some-store.myshopify.com), which Rails treats as the request host.
    # Host authorization (DNS-rebinding protection) would block every one of them
    # with a 403. Those requests are authenticated by the proxy signature instead
    # (ProxySubscriptionsController), so skip the host check for /proxy/* only.
    # Every other route keeps it.
    config.host_authorization = { exclude: ->(request) { request.path.start_with?("/proxy/") } }

    # Background jobs run in Sidekiq, backed by Redis (REDIS_URL, default
    # redis://localhost:6379/0). The test environment overrides this with :test.
    config.active_job.queue_adapter = :sidekiq

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
