# Runs an uploaded magenta-marked scene (the template's `source_image`) through
# slot detection and front-layer extraction. No OpenAI: an upload's magenta
# stays in the base image, so this works on staging and locally.
#
# Off the request thread because detection is pure Ruby over every pixel, and a
# 2x Canva export is millions of them. retry: 0 — the work is deterministic, so
# a retry would only repeat the same answer.
class DetectSceneSlotsJob
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform(scene_template_id)
    template = SceneTemplate.find_by(id: scene_template_id)
    return unless template&.claim_generation!

    source = template.source_image
    raise ArgumentError, "the marked scene is missing" unless source.attached?

    Scenes::BuildFromMarkedImage.new(
      template: template,
      bytes: source.download,
      content_type: source.content_type,
      inpaint: false,
    ).call
  rescue StandardError => e
    Rails.logger.warn("[DetectSceneSlotsJob] template=#{scene_template_id} #{e.class}: #{e.message.to_s.truncate(300)}")
    template&.fail_generation!("Detecting the slots failed (#{e.class}). Check the file is a PNG, then upload it again.")
    raise
  end
end
