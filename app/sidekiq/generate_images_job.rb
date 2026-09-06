class GenerateImagesJob
  include Sidekiq::Job
  sidekiq_options queue: :ai_images, retry: 1, backtrace: true

  # The per-image rescues below refund a failure as it happens; this covers the
  # job dying outright (the outer rescue re-raises, retry: 1 then gives up), so
  # images that never got their turn are still refunded. Only the explicit
  # reservation is honoured here — a menu build's settings["menu_credit"] is
  # left to its own paths, whose behaviour this change doesn't touch. Tiles that
  # already reached "complete" are skipped; ones already refunded in-loop hit the
  # idempotency marker and cost nothing.
  sidekiq_retries_exhausted do |msg, _ex|
    image_ids, board_id, options = msg["args"]
    options = (options || {}).with_indifferent_access
    txn = Credits::TxnRefunds.spend_txn(options[:credit_txn_id])
    per_image = options[:credit_per_image].to_i
    next unless txn && per_image.positive?

    unfinished = BoardImage.where(board_id: board_id, image_id: image_ids)
      .where.not(status: "complete").pluck(:image_id).uniq
    unfinished = Array(image_ids) if board_id.blank?

    unfinished.each do |image_id|
      Credits::TxnRefunds.refund!(txn, per_image, reason: REFUND_REASON,
                                                  image_id: image_id, metadata: { board_id: board_id })
    end
  end

  # Marker for a refunded failed generation. Deliberately distinct from the
  # menu path's "menu_image_failed" — the two reserve different transactions.
  REFUND_REASON = "image_generation_failed"

  # `options` is a trailing optional arg so jobs already enqueued with two
  # arguments keep running after a deploy.
  #
  # options["replace_current"] — the image ALREADY has art and this run is
  # replacing it (the admin builder's "regenerate with AI" mark). Image#create_image_doc
  # sets `current: true` on the new doc but does NOT clear its siblings, so
  # without this the old library doc stays current alongside the new one.
  #
  # options["credit_txn_id"] / options["credit_per_image"] — the caller pre-paid
  # per image against that spend txn (bulk regenerate), so a failed generation
  # refunds one image's cost against it. Absent for every enqueue that spends
  # nothing (admin builds) or that reserves through the board instead (menus).
  def perform(image_ids, board_id = nil, options = {})
    options = (options || {}).with_indifferent_access
    replace_current = options[:replace_current].present?
    images = Image.where(id: image_ids)
    return if images.empty?

    board = Board.includes(:board_images).find_by(id: board_id) if board_id
    board_images = board&.board_images&.where(image_id: image_ids)

    board.update_column(:status, "generating") if board
    board_images.update_all(status: "generating") if board_images.present?

    failed_image_ids = []

    begin
      images.each do |image|
        board_image = board&.board_images&.find_by(image_id: image.id)

        begin
          board_image&.update_column(:status, "generating")

          user_id = image.user_id
          if board&.board_type == "menu"
            # Fresh menu-item images carry a description-driven prompt set at
            # creation (Menu#create_images_from_description) — keep it. Reused
            # or legacy images fall back to the label-based default.
            unless image.menu? && image.image_prompt.present?
              image.image_prompt = image.default_menu_image_prompt(board.name)
            end
          end
          image.save! if image.changed?

          # `image_prompt` holds the user's intent; the house envelope is
          # composed here so it never gets persisted and re-wrapped. This used
          # to overwrite image_prompt unconditionally on non-menu boards,
          # silently discarding every custom prompt.
          composed_prompt = if board&.board_type == "menu"
              image.image_prompt
            else
              Images::PromptBuilder.for_image(
                image,
                user_input: image.image_prompt,
                board: board,
                user: image.user,
              )
            end

          Rails.logger.debug "BOARD TYPE: #{board&.board_type} - Generating image for Image ID #{image.id} with prompt: #{composed_prompt}"

          new_doc = image.create_image_doc(user_id, composed_prompt)

          unless new_doc
            Rails.logger.error("Failed to create image doc for image #{image.id}")
            failed_image_ids << image.id
            image.update_column(:status, "failed") if image.has_attribute?(:status)
            board_image&.update_column(:status, "failed")
            refund_failed_image_credit(board, image.id, options)
            next
          end

          new_doc.update(source_type: "OpenAI")

          # Only AFTER a successful generation. Clearing up front would leave
          # the image with no current doc at all when the call fails, which is
          # worse than the stale art we're replacing.
          image.docs.where.not(id: new_doc.id).update_all(current: false) if replace_current

          # if image.menu? && image.image_prompt.include?(Menu::PROMPT_ADDITION)
          #   image.update!(
          #     image_prompt: image.image_prompt.gsub(Menu::PROMPT_ADDITION, ""),
          #   )
          # end

          image.update_column(:status, "complete") if image.has_attribute?(:status)
          board_image&.update_column(:status, "complete")
          board_image&.update_column(:display_image_url, new_doc.tile_url)
        rescue => e
          failed_image_ids << image.id

          Rails.logger.error(
            [
              "**** IMAGE ERROR ****",
              "Image ID: #{image.id}",
              "Board ID: #{board_id}",
              e.message,
              *e.backtrace,
            ].join("\n")
          )

          image.update_column(:status, "failed") if image.has_attribute?(:status)
          board_image&.update_column(:status, "failed")
          refund_failed_image_credit(board, image.id, options)

          next
        end
      end

      Rails.logger.debug(
        "Completed GenerateImagesJob for board: #{board_id}, image_ids: #{image_ids.join(", ")}, failed_image_ids: #{failed_image_ids.join(", ")}"
      )

      if board
        if failed_image_ids.empty?
          board.update_column(:status, "complete")
        else
          # Pick whichever status makes sense in your app:
          # "failed", "partial", or leave it alone.
          board.update_column(:status, "complete_with_errors")
        end

        # The board's preview was rendered before this job ran (GenerateBoardJob
        # snapshots right after find_or_create_images_from_word_list), so it
        # shows label placeholders for every tile whose art was still being
        # generated. Re-render now that the art exists, otherwise that
        # placeholder snapshot is the board's cover permanently. Skipped when
        # every image failed — there is nothing new to draw.
        board.run_generate_preview_job if failed_image_ids.size < images.size
      end
    rescue => e
      Rails.logger.error(
        [
          "**** JOB ERROR ****",
          "Board ID: #{board_id}",
          e.message,
          *e.backtrace,
        ].join("\n")
      )

      board.update_column(:status, "failed") if board
      raise e
    end
  end

  private

  # Give one image's cost back when its generation failed. Idempotent inside the
  # refund service, so the Sidekiq retry can't double-refund. No-op when nothing
  # was pre-paid (admin builds).
  #
  # An explicit reservation in `options` WINS over the menu board's
  # settings["menu_credit"]. A bulk regenerate run on a menu board pre-paid its
  # OWN spend; refunding that failure against the original menu_create txn
  # credits back an unrelated purchase — and would eat into the budget the menu
  # build's own refunds are capped against.
  #
  # One spend fans out to several jobs (the caller slices the batch), so every
  # slice refunds the same txn: `image_id` in the marker is what keeps them from
  # standing in for each other, and the cap inside the refund service is what
  # makes concurrent slices safe.
  def refund_failed_image_credit(board, image_id, options)
    txn_id = options[:credit_txn_id]
    per_image = options[:credit_per_image].to_i

    if txn_id.present? && per_image.positive?
      Credits::TxnRefunds.refund!(
        Credits::TxnRefunds.spend_txn(txn_id), per_image,
        reason: REFUND_REASON, image_id: image_id, metadata: { board_id: board&.id },
      )
      return
    end

    return unless board&.board_type == "menu"
    Menus::CreditRefunds.refund_failed_image!(board, image_id)
  end
end
