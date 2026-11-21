# frozen_string_literal: true

# The app's landing page inside the Shopify admin. For Phase 1 it proves the whole auth
# chain works: verified ID token -> stored (or exchanged) offline token -> GraphQL call.
class HomeController < AuthenticatedController
  SHOP_QUERY = <<~GRAPHQL
    query RestockPingShop {
      shop {
        name
        myshopifyDomain
      }
    }
  GRAPHQL

  def index
    client = ShopifyAPI::Clients::Graphql::Admin.new(session: current_shopify_session)
    response = client.query(query: SHOP_QUERY)
    @shop = response.body.dig("data", "shop")
  end
end
