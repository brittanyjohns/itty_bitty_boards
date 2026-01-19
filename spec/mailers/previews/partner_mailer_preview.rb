class PartnerMailerPreview < ActionMailer::Preview
  def welcome_email
    user = User.first || User.new(name: "Test User", email: "test@example.com")
    PartnerMailer.welcome_email(user)
  end
end
