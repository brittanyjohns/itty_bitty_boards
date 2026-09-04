class API::AgeBandsController < API::ApplicationController
  # The canonical age-band vocabulary both age selects render from — the board
  # form's "Age range" and the communicator form's "Age band". Unauthenticated,
  # like care_sections and preset_colors: it is a static list of option keys
  # with no user data in it, and gating it behind a token would mean an expired
  # session renders a form with no choices in it rather than a clear sign-in
  # prompt.
  skip_before_action :authenticate_token!, only: %i[index]

  def index
    # `private`, not `public`: the labels are locale-dependent, so a shared
    # cache keyed on the path alone would hand a Spanish client English bands.
    expires_in 1.hour, public: false
    render json: {
             age_bands: CommunicatorProfile.age_band_options(locale: requested_locale),
           }
  end

  private

  # Whitelisted against available_locales rather than symbolized straight from
  # the params — an unbounded `to_sym` on user input both grows the symbol
  # table and lets an arbitrary string reach I18n.
  def requested_locale
    requested = params[:locale].to_s
    return I18n.default_locale if requested.blank?

    I18n.available_locales.find { |l| l.to_s == requested } || I18n.default_locale
  end
end
