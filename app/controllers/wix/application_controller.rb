class Wix::ApplicationController < ActionController::Base
  def submit
    Rails.logger.info("Submitting form with params: #{params.inspect}")
    # Handle form submission logic here
  end
end
