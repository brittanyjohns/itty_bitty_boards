class API::CareSectionsController < API::ApplicationController
  # The care schema the MySpeak editor renders from. Unauthenticated, like
  # preset_colors: it is a static list of option keys with no user data in it,
  # and gating it behind a token would mean an expired session renders an
  # editor with no choices in it rather than a clear sign-in prompt.
  skip_before_action :authenticate_token!, only: %i[index]

  def index
    # Static for the life of a deploy — safe to let clients and any proxy hold
    # on to it. Changing CARE_SECTIONS ships a new deploy, which busts this.
    expires_in 1.hour, public: true
    render json: Profile.care_registry_view
  end
end
