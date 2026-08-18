require "rails_helper"

# Regression cover for the ViewCommunicatorAccount hang: GET
# /api/child_accounts/45 took 12.9s in production (1,788,964 allocations,
# db_runtime 9376ms) because `api_view` serialized all 1,126 boards the owner
# had, reading `display_image_url` (an ActiveStorage lookup) and `word_sample`
# on each without preloads — roughly 3,700 queries in one request.
RSpec.describe ChildAccount, "#api_view performance", type: :model do
  # Counts real SQL, ignoring transaction bookkeeping — same shape as
  # spec/services/boards/image_resolver_spec.rb.
  def count_queries
    queries = 0
    callback = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:sql].to_s.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

      queries += 1
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def build_account_with_owner_boards(board_count)
    owner = FactoryBot.create(:user)
    account = FactoryBot.create(:child_account, user: owner, owner_id: owner.id)

    board_count.times do
      board = FactoryBot.create(:board, user: owner)
      # A tile makes `word_sample` fall through to board_images unless the word
      # list is cached — which is exactly the path that used to re-query.
      FactoryBot.create(:board_image, board: board)
    end

    [account, owner]
  end

  describe "query count" do
    it "does not grow with the number of boards the owner has" do
      small_account, small_owner = build_account_with_owner_boards(3)
      large_account, large_owner = build_account_with_owner_boards(18)

      # Warm anything memoized at the class level so the first call isn't
      # charged for schema loads the second one gets for free.
      small_account.api_view(small_owner)
      ChildAccount.find(large_account.id).api_view(large_owner)

      small = count_queries { ChildAccount.find(small_account.id).api_view(small_owner) }
      large = count_queries { ChildAccount.find(large_account.id).api_view(large_owner) }

      # 6x the boards must not mean materially more queries. Before the
      # preloads this gap was ~15 queries per extra board.
      expect(large - small).to be <= 2
    end

    it "stays under a flat ceiling for an owner with many boards" do
      account, owner = build_account_with_owner_boards(25)
      ChildAccount.find(account.id).api_view(owner)

      # Measured at 18 on this branch and flat from 1 to 100 boards. The
      # headroom is for incidental additions, not for per-board growth — the
      # test above is what guards the flatness.
      expect(count_queries { ChildAccount.find(account.id).api_view(owner) }).to be <= 25
    end
  end

  describe "payload" do
    let(:owner) { FactoryBot.create(:user) }
    let(:account) { FactoryBot.create(:child_account, user: owner, owner_id: owner.id) }

    it "omits the aggregations nothing reads" do
      # The communicator page renders stats.heat_map / stats.most_clicked_words
      # from the range-bounded /api/word_events/stats. `heat_map` here ran with
      # no range at all — an all-time group_by_day on every page load.
      view = account.api_view(owner)

      expect(view).not_to have_key(:heat_map)
      expect(view).not_to have_key(:week_chart)
      expect(view).not_to have_key(:most_clicked_words)
    end

    it "serializes a populated recently_used_boards through api_view" do
      # `recently_used_boards` returns ChildBoard rows whose name/bg_color/
      # text_color/board_type are delegates. If its return type ever shifts back
      # to Boards (or to WordEvents) this block raises rather than silently
      # emptying, so exercise it with real data.
      board = FactoryBot.create(:board, user: owner)
      FactoryBot.create(:child_board, board: board, child_account: account)
      FactoryBot.create(:word_event, user: owner, child_account: account,
                                     board_id: board.id, created_at: 1.day.ago)

      recent = ChildAccount.find(account.id).api_view(owner)[:recently_used_boards]

      expect(recent.map { |b| b[:board_id] }).to eq([board.id])
      expect(recent.first[:name]).to eq(board.name)
      expect(recent.first).to have_key(:bg_color)
      expect(recent.first).to have_key(:text_color)
      expect(recent.first).to have_key(:board_type)
    end

    it "still serializes the board collections the page renders" do
      board = FactoryBot.create(:board, user: owner)
      FactoryBot.create(:child_board, board: board, child_account: account)

      view = ChildAccount.find(account.id).api_view(owner)

      expect(view[:boards].map { |b| b[:board_id] }).to include(board.id)
      expect(view).to have_key(:available_boards)
      expect(view).to have_key(:teams_boards)
      expect(view).to have_key(:recently_used_boards)
    end
  end

  describe "#boards_by_most_used" do
    it "is computed once even though api_view reaches it twice" do
      owner = FactoryBot.create(:user)
      account = FactoryBot.create(:child_account, user: owner, owner_id: owner.id)

      # No favourites, so `go_to_boards` falls through to boards_by_most_used —
      # the second caller after `most_used_board`.
      expect(account.child_boards.where(favorite: true)).to be_empty

      grouped = 0
      callback = lambda do |_name, _start, _finish, _id, payload|
        grouped += 1 if payload[:sql].to_s.match?(/FROM "word_events".*GROUP BY.*board_id/im)
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        account.most_used_board
        account.go_to_boards
      end

      expect(grouped).to eq(1)
    end
  end

  describe "#recently_used_boards" do
    let(:owner) { FactoryBot.create(:user) }
    let(:account) { FactoryBot.create(:child_account, user: owner, owner_id: owner.id) }
    let(:shared_board) { FactoryBot.create(:board, user: owner) }

    before { FactoryBot.create(:child_board, board: shared_board, child_account: account) }

    it "includes a board this account used in the last week" do
      FactoryBot.create(:word_event, user: owner, child_account: account,
                                     board_id: shared_board.id, created_at: 2.days.ago)

      expect(account.recently_used_boards.map(&:board_id)).to include(shared_board.id)
    end

    it "excludes a board only OTHER accounts used" do
      # The old implementation joined child_boards -> board -> word_events, so
      # any user's activity on a shared board leaked into this account's strip.
      other_owner = FactoryBot.create(:user)
      other_account = FactoryBot.create(:child_account, user: other_owner, owner_id: other_owner.id)
      FactoryBot.create(:word_event, user: other_owner, child_account: other_account,
                                     board_id: shared_board.id, created_at: 2.days.ago)

      expect(account.recently_used_boards.map(&:board_id)).not_to include(shared_board.id)
    end

    it "excludes events older than a week" do
      FactoryBot.create(:word_event, user: owner, child_account: account,
                                     board_id: shared_board.id, created_at: 3.weeks.ago)

      expect(account.recently_used_boards.map(&:board_id)).not_to include(shared_board.id)
    end
  end
end
