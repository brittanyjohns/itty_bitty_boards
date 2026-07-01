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

  def new_feedback_email(feedback_item)
    to_email = ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
    subject = "New feedback received for SpeakAnyWay AAC!!"
    @feedback_item = feedback_item
    @admin = User.find_by(id: User::DEFAULT_ADMIN_ID)
    mail(to: to_email, subject: subject, from: "noreply@speakanyway.com")
  end

  # Partner-pilot review digest, sent by PartnerPilotEndingJob when there are
  # partners ending soon and/or newly past their 3-month window. Gives Brittany
  # a single actionable list — nobody is auto-downgraded, so this is the signal
  # to convert / extend / downgrade each partner by hand.
  def partner_pilot_review(expiring:, expired:)
    to_email = ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
    @expiring = expiring || []
    @expired = expired || []
    subject = "Partner pilots: #{@expired.size} ended, #{@expiring.size} ending soon"
    mail(to: to_email, subject: subject, from: "noreply@speakanyway.com")
  end

  # Server disk-space alert, sent by DiskSpaceAlertJob.
  def disk_space_alert(usage:, severity:)
    to_email = ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
    @usage = usage
    @severity = severity
    @host = Socket.gethostname
    prefix = severity == :critical ? "CRITICAL" : "WARNING"
    subject = "[#{prefix}] SpeakAnyWay server disk at #{usage}%"
    mail(to: to_email, subject: subject, from: "noreply@speakanyway.com")
  end
end
