module MissionControl
  # Demo accounts (User.demo_accounts — internal/test users) must not inflate
  # growth or usage metrics. Mix this in and wrap any user-owned scope in
  # without_demo(...) to strip demo-owned rows. NULL user_ids are kept (they
  # are system rows, not demo activity).
  module ExcludesDemo
    private

    def demo_user_ids
      @demo_user_ids ||= User.demo_accounts.pluck(:id)
    end

    def without_demo(scope)
      return scope if demo_user_ids.empty?

      table = scope.model.arel_table
      scope.where(table[:user_id].eq(nil).or(table[:user_id].not_in(demo_user_ids)))
    end
  end
end
