module Admin
  # Scene mockups for one OWNER: pick a calibrated template in the owner's
  # category, pick the art for each slot, render. Nothing here reaches Etsy — the
  # curated gallery (#953) is what will reference a composition from a listing.
  #
  # This controller serves a board printable. PrintableProductSceneCompositionsController
  # subclasses it for a printable product, overriding only how the owner is found
  # and where its routes live; the views are shared (Rails falls back to
  # admin/scene_compositions for the subclass).
  class SceneCompositionsController < Admin::ApplicationController
    before_action :set_owner
    before_action :set_composition, only: %i[edit update destroy render_scene]

    helper_method :owner_heading, :owner_path, :compositions_path_for_owner, :composition_path_for,
                  :edit_composition_path_for, :new_composition_path_for, :render_composition_path_for

    def new
      @templates = available_templates
      @composition = @owner.scene_compositions.build(
        scene_template: @templates.find_by(id: params[:scene_template_id]),
      )
    end

    def create
      @templates = available_templates
      @composition = @owner.scene_compositions.build(
        scene_template: @templates.find_by(id: params.dig(:scene_composition, :scene_template_id)),
        board_printable_listing: listing_param,
      )

      unless @composition.scene_template
        @composition.errors.add(:scene_template, "must be picked")
        return render(:new, status: :unprocessable_entity)
      end

      if save_composition(@composition)
        @composition.enqueue_render! if render_requested?
        redirect_to edit_composition_path_for(@composition),
                    notice: render_requested? ? "Saved. Rendering… refresh in a moment." : "Saved."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      @composition.board_printable_listing = listing_param

      if save_composition(@composition)
        @composition.enqueue_render! if render_requested?
        redirect_to edit_composition_path_for(@composition),
                    notice: render_requested? ? "Saved. Rendering… refresh in a moment." : "Saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def render_scene
      @composition.update_columns(error: nil)
      @composition.enqueue_render!
      redirect_to edit_composition_path_for(@composition), notice: "Rendering… refresh in a moment."
    end

    def destroy
      @composition.destroy!
      redirect_to owner_path, notice: "Deleted the scene mockup."
    end

    private

    def set_owner
      @owner = @printable = BoardPrintable.find(params[:dashboard_board_printable_id])
    end

    def set_composition
      @composition = @owner.scene_compositions.find(params[:id])
    end

    # --- Owner-specific routing. The subclass overrides these. ---

    def owner_heading
      "#{@owner.board&.name || "Board ##{@owner.board_id}"} · printable ##{@owner.id}"
    end

    def owner_path = admin_dashboard_board_printable_path(@owner)
    def compositions_path_for_owner = admin_dashboard_board_printable_scene_compositions_path(@owner)
    def composition_path_for(composition) = admin_dashboard_board_printable_scene_composition_path(@owner, composition)
    def edit_composition_path_for(composition) = edit_admin_dashboard_board_printable_scene_composition_path(@owner, composition)
    def new_composition_path_for(**query) = new_admin_dashboard_board_printable_scene_composition_path(@owner, query)
    def render_composition_path_for(composition) = render_scene_admin_dashboard_board_printable_scene_composition_path(@owner, composition)

    def listing_param
      id = params.dig(:scene_composition, :board_printable_listing_id).presence
      id && @owner.etsy_listings.find_by(id: id)
    end

    # --- Shared. ---

    # Only calibrated templates in the owner's own category: a device tag in a
    # board scene, or a board in a device-tag scene, is the wrong product.
    def available_templates
      SceneTemplate.calibrated
                   .for_category(SceneComposition.template_category_for(@owner))
                   .ordered
                   .with_attached_base_image
    end

    def render_requested? = params[:render].present?

    # slot_art from the form, limited to the template's own slot keys.
    def submitted_art(template)
      raw = params.fetch(:slot_art, {})
      template.slot_objects.each_with_object({}) do |slot, out|
        entry = raw[slot.key]
        next unless entry.respond_to?(:permit)

        picked = entry.permit(:source, :board_id, :ink, :header, :blob_id, :artwork_blob_id).to_h
        # The artwork picker posts its own field so it never collides with the
        # uploaded-picture select; it names the blob only for that source.
        artwork = picked.delete("artwork_blob_id")
        picked["blob_id"] = artwork if picked["source"] == SceneComposition::SOURCE_PRODUCT_ARTWORK
        out[slot.key] = picked
      end
    end

    # The words for each text slot, limited to the template's own text slot
    # keys. nil when the form didn't send the field at all, so a request that
    # only changes art leaves the words alone.
    def submitted_text(template)
      return nil unless params.key?(:text_values)

      raw = params.fetch(:text_values, {})
      Array(template.text_slots).each_with_object({}) do |slot, out|
        value = raw[slot["key"]]
        out[slot["key"]] = value if value.is_a?(String)
      end
    end

    def submitted_files(template)
      raw = params.fetch(:slot_files, {})
      template.slot_objects.each_with_object({}) do |slot, out|
        file = raw[slot.key]
        out[slot.key] = file if file.respond_to?(:read) && file.respond_to?(:original_filename)
      end
    end

    # Saves the art choices, then attaches any newly uploaded pictures and
    # points their slots at them. Uploads are checked BEFORE anything is saved,
    # so a refused file can't leave a half-applied form behind.
    def save_composition(composition)
      template = composition.scene_template
      art = submitted_art(template)
      files = submitted_files(template)

      files.each do |key, file|
        slot = template.slot_for(key)
        name = slot.label.presence || key
        if !slot.accepts.include?(SceneComposition::SOURCE_UPLOAD) || !composition.allowed_sources.include?(SceneComposition::SOURCE_UPLOAD)
          composition.errors.add(:slot_uploads, "#{name}: this slot doesn't take uploads")
        elsif !SceneComposition::UPLOAD_CONTENT_TYPES.include?(file.content_type)
          composition.errors.add(:slot_uploads, "#{name}: upload a PNG, JPEG or WebP")
        elsif file.size > SceneComposition::MAX_UPLOAD_BYTES
          composition.errors.add(:slot_uploads, "#{name}: pictures must be under #{SceneComposition::MAX_UPLOAD_BYTES / 1.megabyte} MB")
        end
      end
      return false if composition.errors.any?

      text = submitted_text(template)
      composition.text_values = text unless text.nil?
      composition.slot_art = art.reject { |key, _| files.key?(key) }
      return false unless composition.save

      if files.any?
        files.each do |key, file|
          blob = composition.attach_slot_upload!(io: file, filename: file.original_filename, content_type: file.content_type)
          art[key] = { "source" => SceneComposition::SOURCE_UPLOAD, "blob_id" => blob.id }
        end
        composition.slot_art = art
        return false unless composition.save
      end

      composition.prune_unused_uploads!
      true
    end
  end
end
