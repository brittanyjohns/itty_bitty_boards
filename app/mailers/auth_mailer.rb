class AuthMailer < Devise::Mailer
  helper :application # gives access to all helpers defined within `application_helper`.
  include Devise::Controllers::UrlHelpers # Optional. eg. `confirmation_url`
  default template_path: "devise/mailer" # to make sure that your mailer uses the devise views
  # If there is an object in your application that returns a contact email, you can use it as follows
  # Note that Devise passes a Devise::Mailer object to your proc, hence the parameter throwaway (*).
  default from: "noreply@speakanyway.com"

  def reset_password_instructions(record, token, opts = {})
    @token = token
    @resource = record
    @front_end_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    @edit_password_url = @front_end_url + "/reset_password?reset_password_token=#{@token}"
    mail to: record.email
  end
end
