class API::CareSectionsController < API::ApplicationController
  # The care schema the MySpeak editor renders from. Unauthenticated, like
  # preset_colors: it is a static list of option keys with no user data in it,
  # and gating it behind a token would mean an expired session renders an
  # editor with no choices in it rather than a clear sign-in prompt.
  skip_before_action :authenticate_token!, only: %i[index]

  def index
    # `private`, not `public`, since labels made this payload locale-dependent:
    # a shared cache keyed on the path alone would hand a Spanish registry to
    # an English client. Costs little — the client memoizes it per session.
    expires_in 1.hour, public: false
    render json: Profile.care_registry_view(locale: requested_locale)
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
