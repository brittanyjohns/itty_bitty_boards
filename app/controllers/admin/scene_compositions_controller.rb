module Admin
  # A board printable's scene mockups: pick a calibrated template, pick the art
  # for each slot, render. Nothing here reaches Etsy — the curated gallery
  # (#953) is what will reference a composition from a listing.
  class SceneCompositionsController < Admin::ApplicationController
    before_action :set_printable
    before_action :set_composition, only: %i[edit update destroy render_scene]

    def new
      @templates = available_templates
      @composition = @printable.scene_compositions.build(
        scene_template: @templates.find_by(id: params[:scene_template_id]),
      )
    end

    def create
      @templates = available_templates
      @composition = @printable.scene_compositions.build(
        scene_template: @templates.find_by(id: params.dig(:scene_composition, :scene_template_id)),
        board_printable_listing: listing_param,
      )

      unless @composition.scene_template
        @composition.errors.add(:scene_template, "must be picked")
        return render(:new, status: :unprocessable_entity)
      end

      if save_composition(@composition)
        @composition.enqueue_render! if render_requested?
        redirect_to edit_admin_dashboard_board_printable_scene_composition_path(@printable, @composition),
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
        redirect_to edit_admin_dashboard_board_printable_scene_composition_path(@printable, @composition),
                    notice: render_requested? ? "Saved. Rendering… refresh in a moment." : "Saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def render_scene
      @composition.update_columns(error: nil)
      @composition.enqueue_render!
      redirect_to edit_admin_dashboard_board_printable_scene_composition_path(@printable, @composition),
                  notice: "Rendering… refresh in a moment."
    end

    def destroy
      @composition.destroy!
      redirect_to admin_dashboard_board_printable_path(@printable), notice: "Deleted the scene mockup."
    end

    private

    def set_printable
      @printable = BoardPrintable.find(params[:dashboard_board_printable_id])
    end

    def set_composition
      @composition = @printable.scene_compositions.find(params[:id])
    end

    def available_templates
      SceneTemplate.calibrated.for_category("board").ordered.with_attached_base_image
    end

    def render_requested? = params[:render].present?

    def listing_param
      id = params.dig(:scene_composition, :board_printable_listing_id).presence
      id && @printable.etsy_listings.find_by(id: id)
    end

    # slot_art from the form, limited to the template's own slot keys.
    def submitted_art(template)
      raw = params.fetch(:slot_art, {})
      template.slot_objects.each_with_object({}) do |slot, out|
        entry = raw[slot.key]
        next unless entry.respond_to?(:permit)

        out[slot.key] = entry.permit(:source, :board_id, :ink, :header, :blob_id).to_h
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
        if !slot.accepts.include?(SceneComposition::SOURCE_UPLOAD)
          composition.errors.add(:slot_uploads, "#{name}: this slot doesn't take uploads")
        elsif !SceneComposition::UPLOAD_CONTENT_TYPES.include?(file.content_type)
          composition.errors.add(:slot_uploads, "#{name}: upload a PNG, JPEG or WebP")
        elsif file.size > SceneComposition::MAX_UPLOAD_BYTES
          composition.errors.add(:slot_uploads, "#{name}: pictures must be under #{SceneComposition::MAX_UPLOAD_BYTES / 1.megabyte} MB")
        end
      end
      return false if composition.errors.any?

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
