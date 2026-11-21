# frozen_string_literal: true

# "This variant just came back in stock." Phase 4 emails its subscribers.
class RestockEvent < ApplicationRecord
  belongs_to :shop
end
