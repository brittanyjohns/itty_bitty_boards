module Boards
  module AdminBuilder
    # Seeds art prompts and queues generation for images that have no picture.
    #
    # Extracted so the build path and the "try again" button on the build page
    # cannot drift: the batch size, the prompt-seeding rule and the
    # never-overwrite rule are stated once.
    module ArtQueue
      # Matches API::Internal::BoardImagesController's slicing: the job fans out
      # to an image API and a whole set in one call would stampede it.
      BATCH_SIZE = 3

      module_function

      # Returns how many images were queued.
      #
      # `replace_current` is for images that already HAVE art and are being
      # regenerated on purpose — it tells the job to demote the old docs once
      # the new one lands, so the generated art is the image's current doc.
      def call(board:, image_ids:, topic: nil, replace_current: false)
        ids = Array(image_ids).compact.uniq
        return 0 if ids.empty?

        options = replace_current ? { "replace_current" => true } : {}

        seed_prompts!(ids, topic)
        ids.each_slice(BATCH_SIZE) { |batch| GenerateImagesJob.perform_async(batch, board.id, options) }
        ids.size
      end

      # `image_prompt` carries the INTENT only — Images::PromptBuilder composes
      # the house style envelope at generation time and must never have it
      # baked in here, or it gets wrapped twice. An existing prompt is intent
      # someone already chose, so it is never rewritten.
      def seed_prompts!(image_ids, topic)
        Image.where(id: image_ids).each do |image|
          next if image.image_prompt.present?

          image.update_column(:image_prompt, art_intent_for(image.label, topic))
        end
      end

      # The board's topic is what keeps "swing" on a playground board from
      # coming back as a mood swing.
      def art_intent_for(label, topic)
        topic = topic.to_s.strip
        return label.to_s if topic.blank?

        "#{label} in the context of #{topic}"
      end
    end
  end
end
