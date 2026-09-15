module Admin
  # The shared scene library: blank base photos (designed in Canva), their
  # optional front layers, and the calibrated slots real art is warped into.
  # See .claude-notes/scene-engine.md.
  class SceneTemplatesController < Admin::ApplicationController
    before_action :set_template, only: %i[edit update destroy archive calibrate save_calibration generation]

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

    # "Generate scene with AI". A PAID call, so the form confirms first and the
    # job never retries. Only the admin's description (and slot hints) goes to
    # the model — never board or product art.
    def generate
      @template = SceneTemplate.new(category: "board", source: "canva")
      form = params.fetch(:scene_generation, {}).permit(:name, :description, :slot_hints, :orientation, :category)
      description = form[:description].to_s.strip

      if description.blank?
        @generate_error = "Describe the scene to generate."
        return render(:new, status: :unprocessable_entity)
      end

      generated = SceneTemplate.new(
        name: form[:name].to_s.strip.presence || description.truncate(60),
        slug: derived_slug(form[:name].presence || description),
        category: form[:category].presence_in(SceneTemplate::CATEGORIES) || "board",
        source: "ai",
        status: SceneTemplate::STATUS_DRAFT,
        generation: {
          "state" => SceneTemplate::GENERATION_QUEUED,
          "kind" => SceneTemplate::GENERATION_KIND_AI,
          "queued_at" => Time.current.iso8601,
          "request" => {
            "description" => description.truncate(Scenes::GenerateTemplate::MAX_DESCRIPTION_LENGTH),
            "slot_hints" => form[:slot_hints].to_s.strip.truncate(Scenes::GenerateTemplate::MAX_SLOT_HINTS_LENGTH),
            "orientation" => form[:orientation].presence_in(Scenes::GenerateTemplate::ORIENTATIONS) || "landscape",
          },
        },
      )

      if generated.save
        generated.enqueue_generation!
        redirect_to generation_admin_dashboard_scene_template_path(generated), status: :see_other
      else
        @generate_error = generated.errors.full_messages.to_sentence
        render :new, status: :unprocessable_entity
      end
    end

    # "Upload magenta-marked PNG": the same detector and front-layer extractor
    # as an AI scene, with no OpenAI call at all — the magenta stays in the
    # base. Works on staging and locally.
    def upload_marked
      @template = SceneTemplate.new(category: "board", source: "canva")
      form = params.fetch(:marked_scene, {}).permit(:name, :slug, :category)
      file = params[:marked_image]

      @upload_error = marked_upload_error(file)
      return render(:new, status: :unprocessable_entity) if @upload_error

      name = form[:name].to_s.strip.presence || File.basename(file.original_filename.to_s, ".*").humanize.presence || "Marked scene"
      marked = SceneTemplate.new(
        name: name,
        slug: form[:slug].to_s.strip.presence || derived_slug(name),
        category: form[:category].presence_in(SceneTemplate::CATEGORIES) || "board",
        source: "canva",
        status: SceneTemplate::STATUS_DRAFT,
        generation: {
          "state" => SceneTemplate::GENERATION_QUEUED,
          "kind" => SceneTemplate::GENERATION_KIND_UPLOAD,
          "queued_at" => Time.current.iso8601,
        },
      )
      filename = file.original_filename.presence || "marked.png"
      marked.source_image.attach(io: file, filename: filename, content_type: "image/png",
                                 key: SceneTemplate.versioned_storage_key_for(filename))

      if marked.save
        marked.enqueue_generation!
        redirect_to generation_admin_dashboard_scene_template_path(marked)
      else
        @upload_error = marked.errors.full_messages.to_sentence
        render :new, status: :unprocessable_entity
      end
    end

    # The status page for a build. Refreshes itself while the job runs; once the
    # slots are detected it hands straight over to the calibrator, which opens
    # with them in place.
    def generation
      return if @template.generation_pending? || !@template.generation_tracked?
      return unless @template.generation_state == SceneTemplate::GENERATION_COMPLETE && @template.base_image.attached?

      count = Array(@template.calibrator_slots).size
      redirect_to calibrate_admin_dashboard_scene_template_path(@template),
                  notice: "Detected #{helpers.pluralize(count, "slot")}. Nudge the corners onto each surface, then save."
    end

    def calibrate
      return if @template.base_image.attached?

      redirect_to generation_admin_dashboard_scene_template_path(@template),
                  alert: "This template has no base image yet."
    end

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

    PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b.freeze

    # PNG only, and checked by its bytes rather than the browser's label: JPEG
    # compression smears the magenta into its surroundings, which is exactly the
    # edge detection and the front layer are measured on.
    def marked_upload_error(file)
      return "Choose the magenta-marked PNG to upload." unless upload?(file)

      head = file.read(8).to_s.b
      file.rewind
      return "Save the marked scene as a PNG. JPEG smears the magenta edges." unless head == PNG_SIGNATURE
      return "The PNG is larger than #{SceneTemplate::MAX_IMAGE_BYTES / 1.megabyte} MB." if file.size > SceneTemplate::MAX_IMAGE_BYTES

      nil
    end

    def derived_slug(text)
      stem = text.to_s.parameterize.first(60).delete_suffix("-").presence || "scene"
      stem = "scene-#{stem}" unless stem.match?(/\A[a-z0-9]/)
      "#{stem}-#{SecureRandom.hex(3)}"
    end
  end
end
