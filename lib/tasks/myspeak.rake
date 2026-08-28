# MySpeak starter-board maintenance tasks.
#
# The "Core Words" starter board lives as a production row (it is not in
# db/seeds/myspeak_starter_boards.rb), so its recommendation has to be made
# durable by tagging the existing row rather than re-seeding it.
namespace :myspeak do
  RECOMMENDED_TAG = "myspeak-recommended".freeze

  desc "Tag the MySpeak 'Core Words' starter board as recommended (idempotent)"
  task tag_recommended: :environment do
    board = Board.myspeak_public_boards.find_by("LOWER(name) = ?", "core words")

    if board.nil?
      puts "[myspeak:tag_recommended] No public MySpeak board named 'Core Words' found — nothing to do."
      next
    end

    new_tags = board.tags | [RECOMMENDED_TAG]

    if new_tags == board.tags
      puts "[myspeak:tag_recommended] Board ##{board.id} (#{board.name}) already tagged '#{RECOMMENDED_TAG}'. tags=#{board.tags.inspect}"
    else
      board.update!(tags: new_tags)
      puts "[myspeak:tag_recommended] Tagged board ##{board.id} (#{board.name}). tags=#{board.tags.inspect}"
    end
  end

  # Read-only. Reports the invisible starter clones the wizard minted before
  # #795 — `is_template` boards favorited onto a MySpeak page, which is what
  # made them absent from their owner's board list while being the board the
  # public page links to. Prints and nothing else: repointing a live public
  # page is a decision, not a sweep.
  desc "Report stale MySpeak wizard starter clones (read-only — writes nothing)"
  task stale_starter_clones: :environment do
    owner_id = "COALESCE(child_accounts.user_id, child_accounts.owner_id)"

    rows = ChildBoard
             .joins(:board)
             # Explicit alias: a second association join on `boards` gets an
             # auto-generated alias that these raw predicates can't name.
             .joins("INNER JOIN boards AS original_boards ON original_boards.id = child_boards.original_board_id")
             .joins(child_account: :profile)
             .where(child_boards: { favorite: true })
             .where(boards: { is_template: true })
             .where(profiles: { profile_kind: "safety" })
             # Owner AND attacher are both the page owner. An SLP assignment
             # fails both: the board belongs to the SLP and `created_by_id` is
             # the SLP, so this is what keeps a shared clinician board out.
             .where("boards.user_id = #{owner_id}")
             .where("child_boards.created_by_id = #{owner_id}")
             # Cloned from an admin public starter. Deliberately not the
             # Board.public_boards scope: that scope has changed since these
             # rows were written, and this pair of columns has not.
             .where("original_boards.user_id = ? AND original_boards.predefined = ?", User::DEFAULT_ADMIN_ID, true)
             # Sub-board clones are never favorited, but assert it anyway.
             .where("NOT COALESCE((boards.settings->>'assignment_child')::boolean, false)")
             .includes(:board, :original_board, child_account: :profile)

    puts "[myspeak:stale_starter_clones] #{rows.size} candidate(s)"

    rows.each do |cb|
      child = cb.child_account
      profile = child.profile
      # Reported, not filtered: the wizard writes the page and this row in one
      # transaction, so a genuine clone lands seconds after its profile. A
      # board favorited by hand months later is a different animal.
      gap = (cb.created_at - profile.created_at).abs.round
      puts format(
        "  child_board=%<cb>d board=%<board>d (%<name>s) original=%<orig>d owner_user=%<owner>s communicator=%<child>d page=/my/%<slug>s gap=%<gap>ds%<flag>s",
        cb: cb.id, board: cb.board_id, name: cb.board.name, orig: cb.original_board_id,
        owner: (child.user_id || child.owner_id), child: child.id, slug: profile.slug,
        gap: gap, flag: gap > 300 ? "  <-- LOW CONFIDENCE, verify by hand" : "",
      )
    end
  end
end
