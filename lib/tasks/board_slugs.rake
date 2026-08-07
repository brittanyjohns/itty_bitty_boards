namespace :boards do
  # The deliberate rename path for a published board, whose slug is otherwise
  # frozen (#611): `/pb/<slug>` is what the QR codes on printed board
  # printables encode, and there is no redirect or slug history behind it.
  #
  # Renaming here breaks every sheet already printed with the old slug. Only
  # do it for a board whose printables have not shipped, or reprint after.
  #
  #   bin/rails 'boards:rename_slug[123,new-slug]'
  desc "Rename a board's slug, including a published board (breaks printed QR codes)"
  task :rename_slug, [:board_id, :new_slug] => :environment do |_t, args|
    board_id = args[:board_id].presence
    new_slug = args[:new_slug].presence

    abort "Usage: bin/rails 'boards:rename_slug[BOARD_ID,new-slug]'" if board_id.blank? || new_slug.blank?

    board = Board.find_by(id: board_id)
    abort "Board #{board_id} not found" if board.nil?

    old_slug = board.slug
    puts "Board #{board.id} (#{board.name.inspect}) published=#{board.published?}"
    puts "  #{old_slug.inspect} -> requested #{new_slug.inspect}"

    if board.published?
      puts "  WARNING: this board is published. Any QR code already printed for"
      puts "  /pb/#{old_slug} will 404 after this rename."
    end

    unless board.rename_slug!(new_slug)
      abort "Failed to save: #{board.errors.full_messages.join(", ")}"
    end

    puts "  done: slug is now #{board.reload.slug.inspect} (#{board.public_url})"
  end
end
