class AdminMailer < BaseMailer
  # <p>Hi <%= @admin.name %>,</p>
  #       <p>Just a quick note to let you know that a new user has signed up for SpeakAnyWay:</p>
  #       <p>Name: <%= @user.name %></p>
  #       <p>Email: <%= @user.email %></p>
  #       <p>Role: <%= @user.role %></p>
  #       <hr>
  #       <p>Plan type: <%= @user.plan_type %></p>
  #       <p>Plan status: <%= @user.plan_status %></p>
  #       <p>Tokens: <%= @user.tokens %></p>
  #       <hr>
  def new_user_email(user)
    to_email = ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
    subject = "New user signed up for SpeakAnyWay AAC!!"
    @user = user
    @admin = User.find_by(id: User::DEFAULT_ADMIN_ID)
    mail(to: to_email, subject: subject, from: "noreply@speakanyway.com")
  end
end
