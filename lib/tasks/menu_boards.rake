namespace :menu_boards do
  # Re-link menu boards whose Menu parent was severed.
  #
  # Until Board#sync_user_parent landed, every board save reassigned
  # parent_type/parent_id to the owning User. For a board created from a menu
  # that permanently dropped the only pointer back to its Menu, so the API
  # started returning original_menu_image_url: nil (the "View Menu" button
  # disappears), menu_description: nil, and menu_id: <the owner's user id>.
  #
  # The Menu row and its attached menu_image survive, so the link can be
  # rebuilt by matching owner + name — menus_controller#create names the board
  # after the menu. The fingerprint of a severed board is parent_id == user_id.
  #
  # Read-only by default. Apply with DRY_RUN=false.
  #
  #   rake menu_boards:relink                        # report
  #   DRY_RUN=false rake menu_boards:relink          # apply
  #   DRY_RUN=false USER_ID=160 rake menu_boards:relink
  #
  # A board with no name match, or with an ambiguous one, is reported and left
  # alone — re-parenting a board onto the wrong Menu would show a stranger's
  # menu photo, which is worse than the missing button.
  desc "Re-link menu boards to the Menu they came from (DRY_RUN=false to apply; USER_ID=N to scope)"
  task relink: :environment do
    dry_run = ENV["DRY_RUN"] != "false"
    match_window = 24.hours

    scope = Board.where(board_type: "menu", parent_type: "User")
    scope = scope.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    relinked = 0
    no_match = []
    ambiguous = []

    scope.find_each do |board|
      candidates = Menu.where(user_id: board.user_id, name: board.name).to_a

      menu =
        if candidates.one?
          candidates.first
        elsif candidates.many?
          # Same request creates the menu and then the board, so the closest
          # created_at is the right one — but only trust it inside a window.
          nearest = candidates.min_by { |m| (m.created_at - board.created_at).abs }
          nearest if (nearest.created_at - board.created_at).abs <= match_window
        end

      if menu.nil?
        (candidates.empty? ? no_match : ambiguous) << board
        next
      end

      puts "  board #{board.id} #{board.name.inspect} (user #{board.user_id}) -> menu #{menu.id}" \
           "#{menu.menu_image.attached? ? "" : " [menu has no image attached]"}"

      unless dry_run
        board.update_columns(parent_type: "Menu", parent_id: menu.id)
      end
      relinked += 1
    end

    puts ""
    puts "#{dry_run ? "would re-link" : "re-linked"} #{relinked} board(s)"

    if no_match.any?
      puts "#{no_match.size} board(s) with no Menu of the same name — left alone:"
      no_match.each { |b| puts "  board #{b.id} #{b.name.inspect} (user #{b.user_id})" }
    end

    if ambiguous.any?
      puts "#{ambiguous.size} board(s) with an ambiguous match — left alone, re-parent by hand:"
      ambiguous.each { |b| puts "  board #{b.id} #{b.name.inspect} (user #{b.user_id})" }
    end

    puts "(dry run — re-run with DRY_RUN=false to apply)" if dry_run
  end
end
