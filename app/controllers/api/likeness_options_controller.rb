class API::LikenessOptionsController < API::ApplicationController
  # The token lists the "pictures that look like them" picker renders from.
  # Unauthenticated, like age_bands: static option keys and labels with no user
  # data in them, and a picker with no choices is a worse failure than a clear
  # sign-in prompt.
  skip_before_action :authenticate_token!, only: %i[index]

  def index
    # `private`: the labels are locale-dependent (see API::AgeBandsController).
    expires_in 1.hour, public: false
    render json: CommunicatorLikeness.options(locale: requested_locale)
  end

  private

  # Whitelisted against available_locales, never symbolized straight off the
  # params — same rule as API::AgeBandsController#requested_locale.
  def requested_locale
    requested = params[:locale].to_s
    return I18n.default_locale if requested.blank?

    I18n.available_locales.find { |l| l.to_s == requested } || I18n.default_locale
  end
end
