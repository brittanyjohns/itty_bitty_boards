# == Schema Information
#
# Table name: child_boards
#
#  id                :bigint           not null, primary key
#  board_id          :bigint           not null
#  child_account_id  :bigint           not null
#  status            :string
#  settings          :jsonb
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  published         :boolean          default(FALSE)
#  favorite          :boolean          default(FALSE)
#  created_by_id     :bigint
#  original_board_id :bigint
#  layout            :jsonb
#  position          :integer
#
class ChildBoard < ApplicationRecord
  belongs_to :board
  belongs_to :child_account
  belongs_to :original_board, class_name: "Board", optional: true
  has_many :images, through: :board
  has_one :image_parent, through: :board
  belongs_to :created_by, class_name: "User", foreign_key: "created_by_id", optional: true

  # A board sits on a communicator dashboard at most once. Backstop for the
  # ad-hoc .exists? guards at the call sites; enforced structurally by the
  # unique (board_id, child_account_id) index.
  validates :board_id, uniqueness: { scope: :child_account_id }

  # Board#in_use is derived from these rows, but Board's own before_save can't
  # see an attach/detach that happens outside a board save — the builder
  # creates this row AFTER the root's last save, and detach never saves the
  # board at all. Refresh the flag on both referenced boards here.
  after_create :recalculate_boards_in_use
  after_destroy :recalculate_boards_in_use

  # Favoriting is what puts a board on the communicator's public MySpeak page,
  # and a board there has to be published or its card 404s on tap. The guard
  # lives here rather than at the call sites because three separate paths set
  # `favorite` — #toggle_favorite, the Board Builder, and MySpeak onboarding —
  # and the next caller shouldn't have to remember. `after_save` covers create
  # too: a row created with `favorite: true` reports the change as [false, true].
  #
  # Deliberately one-way. Unfavoriting never unpublishes: /pb/<slug> may already
  # be printed into an IEP or a QR code, and un-publishing is the quietest way
  # to break paper.
  after_save :publish_for_myspeak, if: -> { saved_change_to_favorite? && favorite? }

  # scope :with_artifacts, -> { includes(board: :images) }
  scope :with_artifacts, -> { includes({ board: [{ images: [:docs, :audio_files_attachments, :audio_files_blobs] }] }, :image_parent) }

  delegate :name, to: :board
  delegate :slug, to: :board
  delegate :bg_color, to: :board
  delegate :text_color, to: :board
  delegate :board_type, to: :board
  delegate :ionic_icon, to: :board

  # NOTE: a dashboard cell is decided ENTIRELY by the frontend
  # (CommunicatorMainLayoutGrid#mergeMissingBoardsIntoLayout) and persisted to
  # `child_accounts.layout` by PATCH /api/child_accounts/:id. This model had
  # grid_x/grid_y/initial_layout mirroring BoardImage's, but nothing ever called
  # them and they could not have worked: they route through
  # BoardsHelper#next_available_cell, whose first move is get_number_of_columns,
  # and child_accounts has no *_screen_columns. `child_boards.layout` and
  # `child_boards.position` are the columns they read; both are unused.

  def word_events
    WordEvent.where(board_id: board.id, child_account_id: child_account.id).order(created_at: :desc)
  end

  def display_image_url
    board.display_image_url
  end

  def preview_image_url
    board.preview_image_url
  end

  def other_boards
    child_account.child_boards.where.not(id: id)
  end

  def added_to_team_by
    settings["added_to_team_by"]
  end

  def team_board_id
    settings["team_board_id"]
  end

  def total_favorite_boards
    other_boards.where(favorite: true).count
  end

  def toggle_favorite
    if !favorite && total_favorite_boards >= 80
      return false
    end
    update(favorite: !favorite)
  end

  def board_type
    board.board_type
  end

  # Can `user` curate this child_board (toggle favorite, reorder, etc.)?
  # Uses the curation tier — owner, system admin, or anyone on the
  # communicator's team with admin/member/supporter role. Same shape as
  # `assign_boards`. Detach (#destroy) is stricter — owner-only — because
  # it bypasses the supervisor-removal snapshot safety net. Spec:
  # marketing/.claude-notes/handoff-workflow.md (Permissions matrix).
  def curatable_by?(user)
    return false unless user
    user.can_add_boards_to_account?([child_account_id])
  end

  # Board card for UNAUTHENTICATED public pages (the MySpeak page's board
  # grid). Deliberately NOT api_view: that emits `added_by` — the email of
  # whoever assigned the board — plus the assigning user's id and the board
  # owner's name, none of which belongs on a page with no authentication and
  # none of which a card renders.
  #
  # Delegates to Board#public_card_view rather than rebuilding the hash: both
  # cards feed the SAME frontend component and the same `PublicBoardCard` type
  # (itty-bitty-frontend/src/data/profiles.ts), and maintaining them in
  # parallel had already dropped `preset_display_image_url` and `slug` here —
  # so a communicator's card could not reach the cover fallback its library
  # twin resolved fine. Board owns cover resolution; this adds only the
  # join-row's own identity.
  def public_card_view
    # Merge AFTER: Board's card sets `id: id, board_id: id` — both the board's
    # id — and a communicator card must report the child_board id.
    board.public_card_view.merge(
      id: id,
      board_id: board_id,
      bg_color: board.bg_color,
      text_color: board.text_color,
    )
  end

  def api_view
    {
      id: id,
      board_id: board_id,
      communicator_board_id: id,
      created_by: created_by&.display_name,
      name: board.name,
      child_account_id: child_account_id,
      status: status,
      settings: settings,
      display_image_url: display_image_url || preview_image_url,
      preview_image_url: preview_image_url,
      board_type: board.board_type,
      # The BOARD's flag, not the join row's. `child_boards.published` is a
      # dead column — nothing in the app has ever written it, so it reported a
      # constant false while the board it points at may well be published.
      # `Board#viewable_by?` is what actually gates the public page.
      published: board.published?,
      favorite: favorite,
      added_by: created_by&.email,
      added_by_id: created_by&.id,
      board_owner_id: board.user_id,
      board_owner_name: board.user&.display_name,
      bg_color: board.bg_color,
      text_color: board.text_color,
    }
  end

  def recalculate_boards_in_use
    [board, original_board].compact.uniq.each(&:recalculate_in_use!)
  end

  def publish_for_myspeak
    Boards::MySpeakPublisher.new(self).call
  end
  private :publish_for_myspeak

  def api_view_with_images
    {
      id: id,
      board_id: board_id,
      name: board.name,
      child_account_id: child_account_id,
      status: status,
      settings: settings,
      display_image_url: display_image_url,
      # images: board.images.map(&:api_view),
      images: board.board_images.map(&:api_view),
      favorite: favorite,
      board_type: board.board_type,
      published: board.published?,
      added_by: created_by&.email,
      layout: board.layout,
    }
  end
end
