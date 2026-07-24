# Preview all emails at http://localhost:4000/rails/mailers/admin_mailer
class AdminMailerPreview < ActionMailer::Preview
  def new_user_email
    AdminMailer.new_user_email(preview_user)
  end

  def plan_change_email
    AdminMailer.plan_change_email(preview_user, from_plan: "free", to_plan: "pro", source: "stripe")
  end

  private

  def preview_user
    User.non_admin.order(created_at: :desc).first || User.first
  end
end
