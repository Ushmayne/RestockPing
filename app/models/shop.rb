# frozen_string_literal: true

# One row per installed store. Doubles as session storage for shopify_app:
# ShopSessionStorage implements store/retrieve, turning a ShopifyAPI::Auth::Session
# into a row and back, plus refresh_token_if_expired! for background jobs.
class Shop < ActiveRecord::Base
  include ShopifyApp::ShopSessionStorage

  # Anyone holding these credentials can call the Admin API as this store, so they are
  # encrypted at rest with Active Record Encryption. A leaked DB dump or backup then
  # doesn't leak usable tokens. Non-deterministic encryption: we never query by token.
  encrypts :shopify_token, :refresh_token

  # The foreign keys cascade in the database too (on_delete: :cascade), so a shop
  # deleted on uninstall takes its data with it even when no callbacks run.
  has_many :variant_stocks, dependent: :delete_all
  has_many :restock_events, dependent: :delete_all
  has_many :subscriptions, dependent: :delete_all
  has_many :notifications, dependent: :delete_all
  has_many :conversions, dependent: :delete_all

  def api_version
    ShopifyApp.configuration.api_version
  end
end
