namespace :myspeak do
  desc "Publish the folder-tile pages behind every board already on a MySpeak page. " \
       "Dry-run by default. ENV: APPLY=1 to write. " \
       "Usage: bin/rails myspeak:backfill_published APPLY=1"
  task backfill_published: :environment do
    apply = ENV["APPLY"].to_s == "1"

    # The repair for boards starred before publishing descended the tile graph:
    # the card is published and works, and every folder tile on it 404s for a
    # visitor. Boards::PublishCascade is the single authority for what "the
    # pages behind this board" means, so the task asks it rather than
    # re-deriving the rule — one place to fix if the rule changes.
    #
    # Only STARRED rows whose board is already published are candidates. An
    # unpublished favorite is a different bug (a board owned by someone other
    # than the page owner, deliberately left private), and publishing it here
    # would be the consent decision MySpeakPublisher declines to make.
    scope = ChildBoard.where(favorite: true).includes(:board, :child_account)

    checked = 0
    repaired = 0
    boards_published = 0

    scope.find_each do |child_board|
      board = child_board.board
      next if board.nil? || !board.published?

      owner_id = child_board.child_account&.user_id
      next if owner_id.blank? || board.user_id != owner_id

      checked += 1
      cascade = Boards::PublishCascade.new(board)
      next unless cascade.needed?(published: true)

      summary = cascade.summary(published: true)
      count = summary.dig(:affected, :count).to_i
      names = Array(summary.dig(:affected, :names)).join(", ")

      repaired += 1
      boards_published += count
      puts "#{apply ? "publishing" : "would publish"} #{count} page(s) under " \
           "'#{board.name}' (board=#{board.id}, communicator=#{child_board.child_account_id}): #{names}"

      next unless apply

      begin
        cascade.apply!(published: true)
      rescue StandardError => e
        # One bad tree must not stop the sweep.
        warn "  failed board=#{board.id}: #{e.class} - #{e.message}"
      end
    end

    puts ""
    puts "checked #{checked} starred board(s); #{repaired} need repair; #{boards_published} page(s) total."
    puts(apply ? "APPLIED." : "Dry run — re-run with APPLY=1 to write.")
  end
end
