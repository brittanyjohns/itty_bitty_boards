class AccountDeletionCleanupJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, backtrace: true

  # Runs after soft-delete to clean up third-party services.
  # Called with the user's ORIGINAL email (before anonymization) and the user id.
  def perform(user_id, original_email, reason = "user_requested")
    cleanup_mailchimp(user_id, original_email, reason)
    cleanup_posthog(user_id, reason)
    cleanup_revenuecat(user_id)
    nullify_analytics_events(user_id)
  end

  private

  def cleanup_mailchimp(user_id, original_email, reason)
    return if ENV["MAILCHIMP_API_KEY"].blank?

    mailchimp = MailchimpService.new
    stub_user = OpenStruct.new(id: user_id, email: original_email)
    mailchimp.archive_subscriber(stub_user, reason: reason)
  rescue => e
    Rails.logger.error("[AccountDeletionCleanup] Mailchimp cleanup failed user=#{user_id}: #{e.class} - #{e.message}")
  end

  def cleanup_posthog(user_id, reason)
    return unless PosthogClient.enabled?
    client = PosthogClient.client
    return if client.nil?

    client.capture(
      distinct_id: user_id.to_s,
      event: "account_deleted",
      properties: {
        "reason" => reason,
        "$set" => { "plan" => "deleted", "account_deleted" => true },
      },
    )
    Rails.logger.info("[AccountDeletionCleanup] PostHog account_deleted captured user=#{user_id}")
  rescue => e
    Rails.logger.error("[AccountDeletionCleanup] PostHog cleanup failed user=#{user_id}: #{e.class} - #{e.message}")
  end

  def cleanup_revenuecat(user_id)
    api_key = ENV["REVENUECAT_REST_API_KEY"]
    return if api_key.blank?

    conn = Faraday.new(url: "https://api.revenuecat.com") do |f|
      f.options.timeout = 10
      f.options.open_timeout = 5
    end

    response = conn.delete("/v1/subscribers/#{user_id}") do |req|
      req.headers["Authorization"] = "Bearer #{api_key}"
      req.headers["Accept"] = "application/json"
    end

    if response.status == 200 || response.status == 404
      Rails.logger.info("[AccountDeletionCleanup] RevenueCat subscriber deleted user=#{user_id} status=#{response.status}")
    else
      Rails.logger.warn("[AccountDeletionCleanup] RevenueCat delete returned status=#{response.status} user=#{user_id}")
    end
  rescue => e
    Rails.logger.error("[AccountDeletionCleanup] RevenueCat cleanup failed user=#{user_id}: #{e.class} - #{e.message}")
  end

  def nullify_analytics_events(user_id)
    count = AnalyticsEvent.where(user_id: user_id).update_all(user_id: nil)
    Rails.logger.info("[AccountDeletionCleanup] Nullified #{count} analytics_events for user=#{user_id}")
  rescue => e
    Rails.logger.error("[AccountDeletionCleanup] AnalyticsEvent nullify failed user=#{user_id}: #{e.class} - #{e.message}")
  end
end
