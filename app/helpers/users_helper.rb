module UsersHelper
  def revoke_all_sessions_and_tokens!
    # Devise JWT: changing jti invalidates existing JWTs
    self.jti = SecureRandom.uuid

    # Any custom token fields you have
    self.authentication_token = nil
    self.temp_login_token = nil
    self.temp_login_expires_at = nil

    # If you store OAuth tokens in `tokens` or elsewhere, clear them here.
    # Your schema shows `tokens` is an integer, so leaving it alone.
  end

  def anonymize_personal_data_and_delete_all_data!(deleted_at:, reason:, actor_id:)
    if admin?
      raise AccountDeletionError, "Admin accounts cannot be soft-deleted"
    end
    # Use a stable, unique anonymized email so uniqueness validations don't break
    og_email = email
    anon = "deleted-#{id}-#{SecureRandom.hex(8)}@#{SOFT_DELETE_EMAIL_DOMAIN}"

    self.email = anon
    self.name = "Deleted User"
    self.password = nil
    self.password_confirmation = nil
    self.reset_password_token = nil
    self.reset_password_sent_at = nil

    # If role/teams/org membership should be severed:
    self.current_team_id = nil
    self.organization_id = nil
    self.vendor_id = nil

    # Optional: remove potentially identifying keys
    self.child_lookup_key = nil

    # Keep Stripe IDs for recordkeeping unless you have a separate tombstone table.
    # self.stripe_customer_id = nil
    # self.stripe_subscription_id = nil

    # Settings tombstone
    self.settings = (settings.is_a?(Hash) ? settings.deep_dup : {})
    self.settings["account"] ||= {}
    self.settings["account"]["deleted"] = true
    self.settings["account"]["deleted_at"] = deleted_at.iso8601
    self.settings["account"]["deleted_reason"] = reason.to_s
    self.settings["account"]["deleted_actor_id"] = actor_id
    self.plan_status = "deleted"
    self.plan_expires_at = deleted_at
    self.settings["original_email"] = og_email
    communicator_accounts.destroy_all
    total_boards.destroy_all
    menus.destroy_all
    images.destroy_all
    user_docs.destroy_all
    docs.destroy_all
    scenarios.destroy_all
    board_screenshot_imports.destroy_all
    board_groups.destroy_all
    openai_prompts.destroy_all
    profile&.destroy
    created_teams.destroy_all
    self.deleted_at = deleted_at
    save!
  end
end
