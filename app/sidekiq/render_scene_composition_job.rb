# Renders one SceneComposition — a Grover screenshot plus one page render per
# distinct (board, ink, header) a slot draws — so it never runs on a request
# thread. Enqueued via SceneComposition#enqueue_render!, after commit.
class RenderSceneCompositionJob
  include Sidekiq::Job
  sidekiq_options retry: 2, queue: :default

  def perform(scene_composition_id)
    composition = SceneComposition.find_by(id: scene_composition_id)
    return unless composition

    Boards::Printables::RenderSceneComposition.new(composition: composition).call
  rescue Boards::Printables::RenderSceneComposition::Error => e
    # Deterministic (a board left the printable, an upload is gone): record it
    # for the admin and stop, rather than retrying into the same answer.
    Rails.logger.warn("[RenderSceneCompositionJob] composition=#{scene_composition_id} #{e.message}")
    composition&.update_columns(error: e.message.truncate(1000))
  rescue StandardError => e
    composition&.update_columns(error: "The render failed (#{e.class}). It retries automatically; if this stays, check the worker logs.")
    raise
  end
end
