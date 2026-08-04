# Mark accounts as internal/test so they stop consuming Mailchimp journey
# sends and stop inflating growth metrics.
#
# The email-pattern rules (User::DEMO_EMAIL_PATTERNS) only catch accounts that
# follow a naming convention. Real test accounts routinely don't —
# speakanyway@gmail.com, testaria@gmail.com, speak@test.com — and broadening
# the patterns enough to catch them risks catching a paying customer. So these
# get marked explicitly instead.
#
# Marking is reversible (`unmark`) and only ever writes the
# settings["internal_account"] key.
namespace :users do
  namespace :internal do
    def resolve_users(list)
      ids, emails = list.to_s.split(",").map(&:strip).reject(&:blank?).partition { |t| t.match?(/\A\d+\z/) }
      User.where(id: ids).or(User.where(email: emails))
    end

    desc "List every account currently treated as internal/demo"
    task :list => :environment do
      scope = User.demo_accounts.order(:id)
      puts "#{scope.count} internal/demo account(s):"
      scope.each do |user|
        via = user.settings.is_a?(Hash) && user.settings[User::INTERNAL_ACCOUNT_FLAG] ? "flag" : "email pattern"
        puts format("  %-6s %-42s (%s)", user.id, user.email, via)
      end
      puts "\nPatterns in effect: #{User.demo_email_patterns.join(", ")}"
    end

    desc "Mark accounts internal by id and/or email (DRY_RUN=false to apply)"
    task :mark, [:list] => :environment do |_t, args|
      abort "Pass ids and/or emails: rake 'users:internal:mark[803,804,speak@test.com]'" if args[:list].blank?

      dry_run = ENV["DRY_RUN"] != "false"
      scope = resolve_users(args[:list])
      puts "Matched #{scope.count} account(s)."

      scope.find_each do |user|
        if dry_run
          puts "[dry-run] would mark #{user.id} (#{user.email}) internal"
        else
          user.mark_internal!
          puts "Marked #{user.id} (#{user.email}) internal"
        end
      end

      puts(dry_run ? "Dry run — nothing changed. Re-run with DRY_RUN=false to apply." : "Done.")
    end

    desc "Undo :mark for accounts by id and/or email (DRY_RUN=false to apply)"
    task :unmark, [:list] => :environment do |_t, args|
      abort "Pass ids and/or emails: rake 'users:internal:unmark[803]'" if args[:list].blank?

      dry_run = ENV["DRY_RUN"] != "false"
      scope = resolve_users(args[:list])
      puts "Matched #{scope.count} account(s)."

      scope.find_each do |user|
        if dry_run
          puts "[dry-run] would unmark #{user.id} (#{user.email})"
        else
          user.unmark_internal!
          puts "Unmarked #{user.id} (#{user.email})"
        end
      end

      puts(dry_run ? "Dry run — nothing changed. Re-run with DRY_RUN=false to apply." : "Done.")
    end
  end
end
