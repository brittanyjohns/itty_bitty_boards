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
  validates :columns_count, :tile_count, numericality: { greater_than: 0 }

  scope :recent, -> { order(created_at: :desc) }

  # Boards created by this page. Everything that mutates a board goes through
  # it, so a hand-edited `board_id` can't turn publish into a lever on an
  # arbitrary board.
  def self.builder_boards
    Board.where("(settings ->> :key) = 'true'", key: BUILDER_SETTING)
  end

  # The root page plus any child pages, normalized into one iterable list.
  def pages
    Boards::AdminBuilder::Plan.from_stored(plan, name: name, columns: columns_count, tile_count: tile_count)
  end

  def tiles
    Array((plan || {})["tiles"])
  end

  def children
    Array((plan || {})["children"])
  end

  def multi_page? = children.any?

  # Labels the admin ticked "regenerate with AI" on the art review screen,
  # already normalized by Boards::ImageResolver.normalize when they were
  # stored. The library still supplies each of these tiles its symbol at build
  # time; the mark only says "generate over it afterwards".
  def regenerate_labels
    Array((plan || {})["regenerate"])
  end

  # Label => Doc id for tiles where the admin picked a different picture than
  # the one the library would attach. Normalized on the way in, like
  # regenerate_labels. The tile still resolves to its own Image — only the
  # picture is pinned, through board_images.display_image_url.
  def display_doc_ids
    ((plan || {})["display_docs"] || {}).transform_values(&:to_i)
  end

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

  def complete? = status == "complete"
  def failed? = status == "failed"
  def in_flight? = %w[pending building].include?(status)

  # A set that got written but whose recoverable tail didn't finish — the
  # boards exist and are correct, the art report and art queueing don't.
  # `error_message` on a COMPLETE build is a warning, not a failure: only
  # `mark_failed!` (which is reached solely when nothing was committed) means
  # the build produced nothing.
  def warning? = complete? && error_message.present?

  # Work `Boards::AdminBuilder::Build#finish!` still owes this build. True for
  # a warned build and for the historical rows that were marked `failed` after
  # their set had already committed — both are repaired by re-running the job,
  # which never rebuilds a set it already owns.
  def needs_finishing? = board_id.present? && !(complete? && error_message.blank?)

  def mark_building! = update!(status: "building", error_message: nil)

  # Nothing was committed — the build produced no boards at all.
  def mark_failed!(message)
    update!(status: "failed", error_message: message.to_s.truncate(1000))
  end

  # The set IS committed; only the tail failed. Deliberately not "failed": a
  # red badge on a built, published, correct set sends an admin to rebuild
  # something that already exists.
  def mark_finished_with_warning!(message)
    update!(status: "complete", error_message: message.to_s.truncate(1000))
  end
end
