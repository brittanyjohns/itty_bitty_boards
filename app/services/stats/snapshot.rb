module Stats
  class Snapshot
    def self.call
      new.call
    end

    def call
      {
        generated_at: Time.current.iso8601,
        app: app_info,
        users: user_counts,
        communicators: communicator_counts,
        boards: { total: Board.count },
        revenue: Stats::StripeRevenue.call,
      }
    end

    private

    def app_info
      version = ENV["GIT_REV"].presence ||
                ENV["HEROKU_SLUG_COMMIT"].presence ||
                revision_file ||
                "unknown"
      { status: "ok", version: version }
    end

    def revision_file
      path = Rails.root.join("REVISION")
      File.read(path).strip if File.exist?(path)
    end

    def user_counts
      non_admin = User.non_admin
      {
        total: non_admin.count,
        paid: non_admin.where.not(plan_type: ["free", nil]).count,
        free: non_admin.where(plan_type: "free").count,
      }
    end

    def communicator_counts
      {
        total: ChildAccount.with_archived.count,
        sandbox: ChildAccount.sandbox.count,
        loaner: ChildAccount.loaner.count,
        active: ChildAccount.active.count,
        archived: ChildAccount.archived.count,
      }
    end
  end
end
