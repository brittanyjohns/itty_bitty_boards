# frozen_string_literal: true

# Idempotency + audit log for inbound provider webhooks. A (provider, event_id)
# pair is recorded the first time we see it; the unique index makes a concurrent
# or replayed delivery fail fast so the handler can no-op. Also doubles as an
# audit trail for debugging (e.g. RevenueCat TRANSFER edge cases).
class ProcessedWebhookEvent < ApplicationRecord
  validates :provider, presence: true
  validates :event_id, presence: true, uniqueness: { scope: :provider }
end
