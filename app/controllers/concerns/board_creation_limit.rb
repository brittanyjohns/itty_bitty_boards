# The one board-creation cap, shared by every path that creates boards.
#
# There used to be four near-copies of this check and they had drifted:
# API::MenusController's lacked the fresh re-read AND the Mailchimp notify,
# API::GeneratedBoardsController's lacked the notify, and the Board Builder
# gated on a second, separate cap entirely (issue #796). The point of a stable
# `error_code` is that all of them agree, so they all go through here.
#
# Two details are load-bearing:
#
#   * `User.find(current_user.id)`, never `current_user.reload`.
#     `countable_board_count` memoizes into a plain ivar and `#reload` does not
#     clear those — which matters on the Board Builder's `replace=true` path,
#     where boards are destroyed and re-counted inside one request.
#
#   * `error_code` is ADDITIVE. Existing `error` strings stay byte-identical:
#     some callers put a human sentence there and some put a code, and flipping
#     either would silently break a client we can't test from here. Clients
#     switch on `error_code`.
module BoardCreationLimit
  extend ActiveSupport::Concern

  BOARD_LIMIT_ERROR_CODE = "board_limit_reached".freeze

  private

  # Fresh instance so the count isn't stale from earlier in the request.
  #
  # Takes a subject because the cap belongs to whoever will OWN the boards
  # rather than to whoever is asking — the same rule
  # Boards::BoardGroupCreator applies to the group. Every caller today resolves
  # to the acting user, so this is about naming the right subject at the call
  # site, not about a live divergence.
  def board_limit_user(subject = current_user)
    @board_limit_users ||= {}
    @board_limit_users[subject.id] ||= User.find(subject.id)
  end

  # Whether creating `required` more boards would exceed the cap. Admins are
  # never limited (User#at_board_limit? says so too, but the headroom form
  # bypasses it, so state it here).
  def board_limit_exceeded?(user, required: 1)
    return false if user.admin?

    required > board_limit_remaining(user)
  end

  def board_limit_remaining(user)
    [user.board_limit - user.countable_board_count, 0].max
  end

  def board_limit_error_payload(user, required: 1, error: nil, message: nil)
    remaining = board_limit_remaining(user)
    {
      error: error || "Maximum number of boards reached (#{user.countable_board_count}/#{user.board_limit}). Please upgrade to add more.",
      error_code: BOARD_LIMIT_ERROR_CODE,
      message: message || "You've used #{user.countable_board_count} of your #{user.board_limit} boards. Upgrade, or delete a board, to add more.",
      limit: user.board_limit,
      count: user.countable_board_count,
      required: required,
      remaining: remaining,
    }
  end

  # The `before_action` form: one board, generic copy.
  def check_board_create_permissions
    unless current_user
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    user = board_limit_user
    return unless board_limit_exceeded?(user)

    render json: board_limit_error_payload(user), status: :unprocessable_content
    notify_mailchimp_hit_limit(user)
  end

  # Enqueue the Mailchimp "hit_limit" Customer Journey when a Free user bumps
  # into the board cap. Deduped per user (Rails.cache, 14d TTL) so a user
  # mashing the create button doesn't get the email re-sent. Guarded — any
  # Redis/Sidekiq blip logs a warning rather than 500ing the API request.
  def notify_mailchimp_hit_limit(user)
    return unless user.plan_type == "free"

    dedupe_key = "mailchimp:hit_limit:#{user.id}"
    return if Rails.cache.read(dedupe_key)

    MailchimpEventJob.perform_async(user.id, "journey", { "journey_key" => "hit_limit" })
    Rails.cache.write(dedupe_key, true, expires_in: 14.days)
  rescue StandardError => e
    Rails.logger.warn("[Mailchimp] hit_limit enqueue failed for user #{user.id}: #{e.message}")
  end
end
