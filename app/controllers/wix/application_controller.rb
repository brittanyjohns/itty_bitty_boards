class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception

  before_action :set_locale

  private

  def set_locale
    I18n.locale = params[:locale] || I18n.default_locale
  end

  def submit
    Rails.logger.info("Submitting form with params: #{params.inspect}")
    # Handle form submission logic here
  end
end
