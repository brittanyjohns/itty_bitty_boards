# READ-ONLY: no DB writes. Reconciles what a user is CHARGED for against what
# their /boards page LISTS.
#
# The two used to be different scopes — the limit counted every non-template,
# non-predefined board, while the listing ran `main_boards`, which drops menus,
# sub-pages and (because `NULL != 'menu'` is NULL in SQL) every board with a
# NULL board_type. A Free user at board_limit 1 could therefore be refused
# "1/1 boards" with an empty boards page. This task shows the gap, and keeps
# telling the truth after the fix — the `null board_type` bucket should read 0.
#
#   USER_ID=740 rake boards:limit_audit
#   EMAIL=someone@example.com rake boards:limit_audit
namespace :boards do
  desc "Reconcile a user's counted boards against what /boards lists (READ-ONLY)"
  task limit_audit: :environment do
    user_id = ENV["USER_ID"].presence
    email = ENV["EMAIL"].presence
    abort "Pass USER_ID= or EMAIL=" if user_id.nil? && email.nil?

    user = user_id ? User.find_by(id: user_id) : User.find_by(email: email.to_s.strip.downcase)
    abort "No user matched #{user_id ? "USER_ID=#{user_id}" : "EMAIL=#{email}"}" if user.nil?

    counted = user.countable_boards.order(:id).to_a
    listed_ids = user.countable_boards.main_boards.pluck(:id).to_set
    exempt = user.boards.published_menus.order(:id).to_a

    puts "user ##{user.id} #{user.email}"
    puts "  plan_type              #{user.plan_type}"
    puts "  board_limit            #{user.board_limit}#{user.settings&.key?("board_limit") ? " (admin override)" : " (plan)"}"
    puts "  countable_board_count  #{user.countable_board_count}"
    puts "  board_limit_remaining  #{user.board_limit_remaining}"
    puts "  at_board_limit?        #{user.at_board_limit?}"
    puts

    puts "COUNTED (#{counted.size})"
    counted.each do |b|
      reason =
        if listed_ids.include?(b.id)
          nil
        elsif b.board_type.nil?
          "null board_type"
        elsif b.menu_board?
          "menu"
        elsif b.sub_board?
          "sub-page"
        else
          "unknown"
        end
      flag = reason ? "  HIDDEN (#{reason})" : ""
      puts format(
        "  #%-7d %-38s type=%-11s parent=%-16s sub=%-5s tmpl=%-5s pre=%-5s%s",
        b.id, b.name.to_s.truncate(36), b.board_type.inspect, b.parent_type.to_s,
        b.sub_board.to_s, b.is_template.to_s, b.predefined.to_s, flag
      )
    end
    puts

    puts "EXEMPT — published (public) menus, free by design (#{exempt.size})"
    exempt.each do |b|
      puts format("  #%-7d %-38s type=%-11s", b.id, b.name.to_s.truncate(36), b.board_type.inspect)
    end
    puts

    hidden = counted.size - listed_ids.size
    puts "counted=#{counted.size} listed=#{listed_ids.size} hidden=#{hidden} exempt_menus=#{exempt.size}"
  end
end
