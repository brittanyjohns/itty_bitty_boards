module Admin
  # The shared scene library: blank base photos (designed in Canva), their
  # optional front layers, and the calibrated slots real art is warped into.
  # See .claude-notes/scene-engine.md.
  class SceneTemplatesController < Admin::ApplicationController
    before_action :set_template, only: %i[edit update destroy archive calibrate save_calibration]

    def index
      @status = params[:status].presence_in(SceneTemplate::STATUSES)
      @templates = SceneTemplate.ordered.with_attached_base_image
      @templates = @status ? @templates.where(status: @status) : @templates.where.not(status: SceneTemplate::STATUS_ARCHIVED)
      @usage = SceneComposition.group(:scene_template_id).count
    end

    def new
      @template = SceneTemplate.new(category: "board", source: "canva")
    end

    def create
      @template = SceneTemplate.new(template_params.merge(status: SceneTemplate::STATUS_DRAFT))

      if assign_uploads(@template) && @template.save
        redirect_to calibrate_admin_dashboard_scene_template_path(@template),
                    notice: "Uploaded. Now add a slot for each blank surface and drag its corners into place."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      @template.assign_attributes(template_params)

      if ActiveModel::Type::Boolean.new.cast(params[:remove_front_layer]) && @template.front_layer.attached?
        @template.front_layer.purge
        @template.calibration_version = @template.calibration_version.to_i + 1
      end

      if assign_uploads(@template) && @template.save
        redirect_to edit_admin_dashboard_scene_template_path(@template), notice: "Saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # Retires a template: destroyed when nothing uses it, archived when a
    # composition still renders from it — its renders are pictures of this
    # template, and destroying it would strand them.
    def destroy
      outcome = @template.retire!
      notice = outcome == :destroyed ? "Deleted “#{@template.name}”." : "“#{@template.name}” is in use, so it was archived instead of deleted."
      redirect_to admin_dashboard_scene_templates_path, notice: notice
    end

    def archive
      @template.archive!
      redirect_to admin_dashboard_scene_templates_path, notice: "Archived “#{@template.name}”. Existing mockups still render."
    end

    def calibrate; end

    # The slots, text slots and overlays arrive as JSON documents from the
    # calibrator. Validation is the model's — the page's own warnings are a
    # convenience, not the gate. A text/overlay document the request doesn't
    # carry leaves that column alone.
    def save_calibration
      parsed = JSON.parse(params[:slots_json].to_s)
      text_slots = params.key?(:text_slots_json) ? JSON.parse(params[:text_slots_json].to_s) : nil
      overlay_regions = params.key?(:overlay_regions_json) ? JSON.parse(params[:overlay_regions_json].to_s) : nil

      unless parsed.is_a?(Array) && [text_slots, overlay_regions].all? { |doc| doc.nil? || doc.is_a?(Array) }
        @template.errors.add(:slots, "must be a list")
        return render(:calibrate, status: :unprocessable_entity)
      end

      @template.slots = parsed
      @template.text_slots = text_slots unless text_slots.nil?
      @template.overlay_regions = overlay_regions unless overlay_regions.nil?
      if ActiveModel::Type::Boolean.new.cast(params[:mark_calibrated])
        @template.status = SceneTemplate::STATUS_CALIBRATED
      elsif @template.calibrated? && parsed.empty?
        @template.status = SceneTemplate::STATUS_DRAFT
      end

      if @template.save
        redirect_to calibrate_admin_dashboard_scene_template_path(@template),
                    notice: "Saved #{helpers.pluralize(@template.slots.size, "slot")} (calibration v#{@template.calibration_version})."
      else
        render :calibrate, status: :unprocessable_entity
      end
    rescue JSON::ParserError
      @template.errors.add(:slots, "couldn't be read. Reload the page and try again.")
      render :calibrate, status: :unprocessable_entity
    end

    private

    def set_template
      @template = SceneTemplate.find(params[:id])
    end

    def template_params
      params.fetch(:scene_template, {}).permit(:name, :slug, :category, :source, :status, :notes, :prompt)
    end

    # => false, with errors on the record, when an upload is refused.
    def assign_uploads(template)
      base = params[:base_image]
      front = params[:front_layer]

      template.assign_base_image(io: base, filename: base.original_filename, content_type: base.content_type) if upload?(base)
      template.assign_front_layer(io: front, filename: front.original_filename, content_type: front.content_type) if upload?(front)
      true
    rescue ArgumentError => e
      template.errors.add(:base_image, e.message)
      false
    rescue Vips::Error
      template.errors.add(:base_image, "couldn't be read as an image")
      false
    end

    def upload?(file) = file.respond_to?(:read) && file.respond_to?(:original_filename)
  end
end
