# Finishes AAC categorization for images created with categorization deferred
# (e.g. screenshot imports set `skip_categorize = true`). Runs the synchronous
# OpenAiClient categorization OFF the request/commit path so a user-facing
# commit never blocks on one OpenAI call per novel label.
#
# Uses update_columns to set the resolved part_of_speech + colors without
# re-triggering Image#ensure_defaults (which would loop), and is a no-op when
# the image already has a non-default part_of_speech (already categorized).
class CategorizeImageJob
  include Sidekiq::Job

  def perform(image_id)
    image = Image.find_by(id: image_id)
    return unless image

    pos = AacWordCategorizer.categorize(image.label)
    bg = image.background_color_for(pos)

    image.update_columns(
      part_of_speech: pos,
      bg_color: bg,
      text_color: image.text_color_for(bg),
    )
  end
end
