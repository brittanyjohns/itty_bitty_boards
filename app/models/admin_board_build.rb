# One run of the admin Board Builder (`/admin/board_builds`): an authored plan
# plus the board it produced.
#
# The record exists before the board does. `plan` is written at request time so
# a failed build can be inspected and re-run without the admin re-typing the
# word list, and `art_report` is written after the build so `show` can say what
# actually got a picture — which is the failure this whole page exists to catch.
class AdminBoardBuild < ApplicationRecord
  STATUSES = %w[pending building complete failed].freeze

  # Marks every board this page creates. Publish/destroy are scoped to it so a
  # member action can never reach an unrelated board, the same rail
  # Admin::VideoBoardsController runs on.
  BUILDER_SETTING = "admin_builder".freeze

  belongs_to :board, optional: true
  belongs_to :created_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :name, presence: true
  validates :columns_count, :rows_count, numericality: { greater_than: 0 }

  scope :recent, -> { order(created_at: :desc) }

  # Boards created by this page. Everything that mutates a board goes through
  # it, so a hand-edited `board_id` can't turn publish into a lever on an
  # arbitrary board.
  def self.builder_boards
    Board.where("(settings ->> :key) = 'true'", key: BUILDER_SETTING)
  end

  # The root page plus any child pages, normalized into one iterable list.
  def pages
    Boards::AdminBuilder::Plan.from_stored(plan, name: name, columns: columns_count, rows: rows_count)
  end

  def tiles
    Array((plan || {})["tiles"])
  end

  def children
    Array((plan || {})["children"])
  end

  def multi_page? = children.any?

  def labels
    Boards::AdminBuilder::Plan.labels(pages)
  end

  # Every board of the built set, root first. Keyed off the ids recorded at
  # build time rather than re-walking predictive_board_id, and scoped through
  # `builder_boards` so a stale id can't reach a board this page didn't create.
  def set_boards
    ids = Array(art_report["boards"].presence&.values).presence || [board_id].compact
    return Board.none if ids.empty?

    ordered = self.class.builder_boards.where(id: ids).index_by(&:id)
    [board_id, *ids].uniq.filter_map { |id| ordered[id] }
  end

  def cell_count
    columns_count.to_i * rows_count.to_i
  end

  def complete? = status == "complete"
  def failed? = status == "failed"
  def in_flight? = %w[pending building].include?(status)

  def mark_building! = update!(status: "building", error_message: nil)

  def mark_failed!(message)
    update!(status: "failed", error_message: message.to_s.truncate(1000))
  end
end
