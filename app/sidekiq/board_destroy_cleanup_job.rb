# Scrubs the references a Board destroy's dependent: options can't reach:
# users.editable_board_id (plain integer, no FK), the dynamic_board_id /
# phrase_board_id pointers stored in users/child_accounts settings JSONB
# (written by BuildBoardSetJob and the predictive-board flows), and scenarios
# generated from the board. word_events are intentionally left alone —
# they're analytics history.
#
# Enqueued from Board#enqueue_destroy_cleanup (after_destroy). Idempotent:
# every statement is a no-op on re-run, and the board row being long gone is
# expected.
class BoardDestroyCleanupJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3, backtrace: true

  SETTINGS_POINTER_KEYS = %w[dynamic_board_id phrase_board_id].freeze

  def perform(board_id)
    User.where(editable_board_id: board_id).update_all(editable_board_id: nil)
    scrub_settings_pointers(User, board_id)
    scrub_settings_pointers(ChildAccount, board_id)
    Scenario.where(board_id: board_id).destroy_all
  end

  private

  # The ->> comparisons aren't indexed, hence a background job rather than
  # inline destroy work. Values may be stored as integers or strings; ->>
  # normalizes both to text.
  def scrub_settings_pointers(klass, board_id)
    id = board_id.to_s
    klass
      .where("settings->>'dynamic_board_id' = :id OR settings->>'phrase_board_id' = :id", id: id)
      .find_each do |record|
        settings = record.settings || {}
        matched = SETTINGS_POINTER_KEYS.select { |key| settings[key].to_s == id }
        next if matched.empty?

        matched.each { |key| settings.delete(key) }
        # update_columns: skip the models' heavy save callbacks; this is a
        # pure pointer scrub.
        record.update_columns(settings: settings)
      end
  end
end
