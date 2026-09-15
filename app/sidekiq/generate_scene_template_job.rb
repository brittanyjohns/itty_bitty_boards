# Generates an AI scene photo for a pending SceneTemplate and detects its
# magenta slots (Scenes::GenerateTemplate).
#
# retry: 0 because every attempt is a paid OpenAI call. The claim
# (`claim_generation!`, queued → running under a row lock) is what stops a
# duplicate enqueue from paying twice; a failure is recorded on the template for
# the admin and re-raised so it reaches the error tracker, never retried.
class GenerateSceneTemplateJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(scene_template_id)
    template = SceneTemplate.find_by(id: scene_template_id)
    return unless template&.claim_generation!

    Scenes::GenerateTemplate.new(template).call
  rescue StandardError => e
    Rails.logger.warn("[GenerateSceneTemplateJob] template=#{scene_template_id} #{e.class}: #{e.message.to_s.truncate(300)}")
    template&.fail_generation!("Generating the scene failed (#{e.class}). It isn't retried automatically, " \
                               "because each attempt is a paid call. Try again, or upload a magenta-marked PNG.")
    raise
  end
end
