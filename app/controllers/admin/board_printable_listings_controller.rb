module Admin
  # The Etsy listings made from one BoardPrintable. A printable can carry
  # several — a standalone and a bundle, say — so everything that used to be a
  # member action on the printable (publish, detach, send video) lives here, on
  # the row it actually applies to.
  #
  # Gated by inheritance, like every other admin controller: authenticate_user!
  # + require_admin! come from Admin::ApplicationController and are swept by
  # spec/requests/admin/access_control_spec.rb.
  class BoardPrintableListingsController < Admin::ApplicationController
    before_action :set_printable
    before_action :set_listing, except: :create

    # Allocates a row. Deliberately touches nothing external: a listing exists
    # locally first, gets its copy edited, and only then reaches Etsy. That
    # ordering is what makes publishing idempotent — the row is the token.
    def create
      @printable.etsy_listings.create!(
        purpose: listing_params[:purpose].presence_in(BoardPrintableListing::PURPOSES) || "standalone",
        label: listing_params[:label].presence,
        created_by: current_user,
      )

      redirect_to admin_dashboard_board_printable_path(@printable),
                  notice: "Added a listing. Edit its copy, then create the Etsy draft."
    end

    def update
      @listing.update!(
        purpose: listing_params[:purpose].presence_in(BoardPrintableListing::PURPOSES) || @listing.purpose,
        label: listing_params[:label],
        topic_override: listing_params[:topic_override],
        listing_copy: copy_overrides,
      )

      redirect_to admin_dashboard_board_printable_path(@printable), notice: "Listing saved."
    end

    # Only a row that never reached Etsy. A row carrying a listing id is the
    # ONLY record that a draft exists in a real shop — this app implements no
    # delete call, so throwing the row away loses the draft. Detach instead.
    def destroy
      if @listing.reached_etsy?
        redirect_to admin_dashboard_board_printable_path(@printable),
                    alert: "That listing reached Etsy, so its row can't be deleted — it's the only record " \
                           "of draft #{@listing.etsy_listing_id}. Detach it instead."
      else
        @listing.destroy!
        redirect_to admin_dashboard_board_printable_path(@printable), notice: "Listing removed."
      end
    end

    # Enqueues the DRAFT-only Etsy publish for this row, and also serves Retry:
    # on a row with no Etsy id the two are the same operation.
    #
    # The claim runs HERE and not in the job. Sidekiq guarantees no ordering, so
    # two enqueued jobs could both read `pending` before either wrote; a
    # compare-and-set in the request thread has exactly one winner, and only the
    # winner enqueues.
    def publish
      return if refuse_unless_publishable

      # Persist whatever the form was showing as defaults, so the draft and the
      # page agree — publishing copy an admin never saw would be worse than
      # making them press Save first.
      @printable.update!(listing_copy: @printable.listing_copy_or_default) if @printable.listing_copy.blank?

      claimed = BoardPrintableListing
        .where(id: @listing.id, state: %w[pending failed], etsy_listing_id: nil)
        .update_all(state: "publishing", claimed_at: Time.current, error: nil, updated_at: Time.current)

      if claimed.zero?
        redirect_to admin_dashboard_board_printable_path(@printable),
                    alert: "That listing is already being published, or already has a draft."
      else
        PublishBoardPrintableListingJob.perform_async(@listing.id)
        redirect_to admin_dashboard_board_printable_path(@printable),
                    notice: "Creating the Etsy draft… refresh in a moment to see the result."
      end
    end

    # Detaches this row from its draft so a replacement can be made. Keeps the
    # listing id: the draft is still on Etsy and someone has to be told which
    # one to remove. Deliberately does not touch Etsy — deleting it from here
    # would mean adding the delete call the drafts-only invariant keeps out.
    def supersede
      if !@listing.attached?
        redirect_to admin_dashboard_board_printable_path(@printable),
                    alert: "That listing isn't attached to an Etsy draft, so there's nothing to detach."
      else
        previous = @listing.etsy_listing_id
        @listing.supersede!
        sync_printable_scalars
        redirect_to admin_dashboard_board_printable_path(@printable),
                    notice: "Detached from Etsy draft #{previous}. Delete that draft on Etsy — it's still there. " \
                            "The boards it protects stay protected."
      end
    end

    # Detach plus a fresh row carrying the same purpose, label and overrides.
    # One click, because that is what "Detach & relist" used to be — the
    # difference is that the old row survives instead of being erased.
    def replace
      replacement = nil

      ActiveRecord::Base.transaction do
        @listing.supersede! if @listing.attached?
        replacement = @printable.etsy_listings.create!(
          purpose: @listing.purpose,
          label: @listing.label,
          listing_copy: @listing.listing_copy,
          topic_override: @listing.topic_override,
          image_variants: @listing.image_variants,
          pdf_keys: @listing.pdf_keys,
          created_by: current_user,
        )
      end

      sync_printable_scalars
      redirect_to admin_dashboard_board_printable_path(@printable),
                  notice: "Detached from draft #{@listing.etsy_listing_id || "(none)"} and added a replacement " \
                          "listing ##{replacement.id}. Delete the old draft on Etsy, then publish the new one."
    end

    # Sends an already-rendered video to this row's listing. The one listing
    # mutation this app performs after creation, and it is additive: Etsy allows
    # one video per listing, and a POST adds it where there is none. No state,
    # no delete, no update call.
    def push_video
      if !@listing.attached?
        redirect_to admin_dashboard_board_printable_path(@printable),
                    alert: "That listing isn't attached to an Etsy draft, so there's nothing to send a video to."
      elsif !@printable.listing_video?
        redirect_to admin_dashboard_board_printable_path(@printable),
                    alert: "There's no listing video yet. Render or upload one first."
      elsif @listing.video_pushed_at.present?
        redirect_to admin_dashboard_board_printable_path(@printable),
                    alert: "A video has already been sent to listing #{@listing.etsy_listing_id}. Etsy allows " \
                           "one per listing and this app can't replace it — swap it in the Etsy seller UI."
      elsif !Etsy::Client.configured?
        redirect_to admin_dashboard_board_printable_path(@printable), alert: etsy_unconfigured_message
      else
        PushBoardPrintableListingVideoJob.perform_async(@listing.id)
        redirect_to admin_dashboard_board_printable_path(@printable),
                    notice: "Sending the video to listing #{@listing.etsy_listing_id}… refresh in a moment."
      end
    end

    private

    # The parent resource is declared `as: :dashboard_board_printables`, which
    # names the nested param after the AS, not the model.
    def set_printable = @printable = BoardPrintable.find(params[:dashboard_board_printable_id])

    def set_listing = @listing = @printable.etsy_listings.find(params[:id])

    def listing_params
      params.fetch(:board_printable_listing, {}).permit(
        :purpose, :label, :topic_override, :title, :summary, :description, :tags, :price_cents,
      )
    end

    # Overrides only. A blank field means "use the printable's copy", never
    # "publish an empty one", so blanks are dropped rather than stored.
    def copy_overrides
      {
        "title" => listing_params[:title],
        "summary" => listing_params[:summary],
        "description" => listing_params[:description],
        "tags" => listing_params[:tags]&.split(",")&.map(&:strip)&.reject(&:blank?),
        "price_cents" => listing_params[:price_cents].presence&.to_i,
      }.compact_blank
    end

    def refuse_unless_publishable
      message =
        if !@printable.complete?
          "This printable isn't finished generating yet."
        elsif @listing.reached_etsy?
          "That listing already has Etsy draft #{@listing.etsy_listing_id}."
        elsif !Etsy::Client.configured?
          etsy_unconfigured_message
        end
      return false if message.nil?

      redirect_to admin_dashboard_board_printable_path(@printable), alert: message
      true
    end

    def etsy_unconfigured_message
      "Etsy isn't configured. Set the ETSY_* env vars and run `rake etsy:seed_refresh_token`."
    end

    # Keeps the printable's legacy scalar columns pointing at whichever listing
    # is still attached, so a rollback to the release before listing rows became
    # authoritative still sees the right draft. `etsy_published_at` is never
    # cleared — it is the protection watermark. Goes with the columns.
    def sync_printable_scalars
      primary = @printable.etsy_listings.reload.find(&:attached?)

      @printable.update_columns(
        etsy_listing_id: primary&.etsy_listing_id,
        etsy_listing_url: primary&.etsy_listing_url,
        etsy_video_pushed_at: primary&.video_pushed_at,
        updated_at: Time.current,
      )
    end
  end
end
