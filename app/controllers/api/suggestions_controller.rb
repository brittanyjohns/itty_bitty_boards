module API
  # Contextual writing suggestions for free-text fields.
  #
  # The client sends a `field_key` and (for persisted subjects) a `subject_id`.
  # It never sends prompt text or context values — Suggestions::Registry decides
  # what may become context, so this endpoint can't be turned into a general
  # OpenAI proxy on SpeakAnyWay's bill.
  #
  # Free by design: NO check_credits! call. The users who most need help
  # describing their child are on the 25-credit free plan. Cost is bounded by
  # the explicit user tap, the response cache, and the Rack::Attack AI throttle.
  class SuggestionsController < API::ApplicationController
    CACHE_TTL = 1.hour

    def create
      entry = Suggestions::Registry.fetch(params[:field_key])
      return render json: { error: "unknown_field" }, status: :unprocessable_entity if entry.nil?

      unless suggestions_enabled?
        return render json: { error: "suggestions_disabled" }, status: :forbidden
      end

      subject = nil
      if entry[:subject].present?
        subject = Profile.find_by(id: params[:subject_id])
        return render json: { error: "not_found" }, status: :not_found if subject.nil?
        unless editable?(subject)
          return render json: { error: "not_owner" }, status: :forbidden
        end
      end

      context = Suggestions::ContextBuilder.build(
        entry,
        subject: subject,
        inline: params[:inline_context]&.permit!&.to_h || {},
      )

      suggestions = fetch_suggestions(entry, context)
      render json: { suggestions: suggestions.map { |text| { text: text } } }
    end

    private

    # Absent means ON — the toggle is opt-out, and no backfill was run.
    def suggestions_enabled?
      (current_user.settings || {}).fetch("ai_writing_suggestions", true) != false
    end

    # Matches API::ProfilesController#update: ownership lives on the
    # communicator, not the profile. A profile with no communicator (a
    # user-level page or an unclaimed placeholder) is not editable here.
    def editable?(profile)
      profileable = profile.profileable
      profileable.respond_to?(:editable_by?) && profileable.editable_by?(current_user)
    end

    def fetch_suggestions(entry, context)
      key = cache_key(entry, context)

      Rails.cache.delete(key) if params[:refresh].to_s == "true"

      Rails.cache.fetch(key, expires_in: CACHE_TTL) do
        Suggestions::Generator.call(entry, context: context, locale: locale_param)
      end
    end

    def cache_key(entry, context)
      digest = Digest::SHA256.hexdigest(context.sort.to_h.to_json)[0, 16]
      "suggestions:#{params[:field_key]}:#{entry[:template]}:#{locale_param}:#{digest}"
    end

    def locale_param
      params[:locale].presence&.to_s&.first(5) || "en"
    end
  end
end
