module Admin
  # Non-board printables (device tags first): the product's design artwork, its
  # buyer downloads, its Canva template links, and the scene mockups made from
  # the artwork. Nothing here reaches a marketplace.
  # See .claude-notes/printable-products.md.
  class PrintableProductsController < Admin::ApplicationController
    before_action :set_product, except: %i[index new create]

    def index
      @status = params[:status].presence_in(PrintableProduct::STATUSES)
      @products = PrintableProduct.ordered.with_attached_artworks
      @products = @status ? @products.where(status: @status) : @products.active
      @usage = SceneComposition.where(owner_type: "PrintableProduct").group(:owner_id).count
    end

    def new
      @product = PrintableProduct.new(category: PrintableProduct::CATEGORY_DEVICE_TAG)
    end

    def create
      @product = PrintableProduct.new(product_params.merge(canva_templates: submitted_canva_templates))

      if @product.save
        redirect_to admin_dashboard_printable_product_path(@product),
                    notice: "Created. Upload the design artwork next, then make a scene mockup."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def show
      @compositions = @product.scene_compositions.recent.includes(:scene_template).with_attached_render
    end

    def edit; end

    def update
      if @product.update(product_params.merge(canva_templates: submitted_canva_templates))
        redirect_to admin_dashboard_printable_product_path(@product), notice: "Saved."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # Archive, never destroy: a product's scene mockups and (later) listings are
    # pictures of it.
    def archive
      @product.archive!
      redirect_to admin_dashboard_printable_products_path, notice: "Archived “#{@product.name}”."
    end

    # Side forms on the show page, reported as a flash rather than a 422 — the
    # same shape as a kit page's document upload.
    def upload_artwork
      attach_upload(params[:artwork], kind: "artwork") do |upload, label|
        @product.attach_artwork!(io: upload, filename: upload.original_filename, content_type: upload.content_type, label: label)
      end
    end

    def upload_download
      attach_upload(params[:download], kind: "download") do |upload, label|
        @product.attach_download!(io: upload, filename: upload.original_filename, content_type: upload.content_type, label: label)
      end
    end

    # Refused while a scene mockup draws it: purging would leave that mockup
    # unrenderable. Point the slot at another artwork first.
    def remove_artwork
      file = @product.artworks.find { |attachment| attachment.signed_id == params[:signed_id] }
      return redirect_to(admin_dashboard_printable_product_path(@product), alert: "That artwork isn't on this product.") unless file

      in_use = @product.compositions_using_artwork(file.blob_id)
      if in_use.any?
        return redirect_to admin_dashboard_printable_product_path(@product),
                           alert: "“#{@product.artwork_label(file)}” is used by scene mockup " \
                                  "#{in_use.map { |c| "##{c.id}" }.to_sentence}. Change those slots first."
      end

      label = @product.artwork_label(file)
      file.purge
      redirect_to admin_dashboard_printable_product_path(@product), notice: "Removed “#{label}”."
    end

    def remove_download
      file = @product.downloads.find { |attachment| attachment.signed_id == params[:signed_id] }
      return redirect_to(admin_dashboard_printable_product_path(@product), alert: "That file isn't on this product.") unless file

      label = @product.download_label(file)
      file.purge
      redirect_to admin_dashboard_printable_product_path(@product), notice: "Removed “#{label}”."
    end

    private

    def set_product
      @product = PrintableProduct.find(params[:id])
    end

    def product_params
      params.require(:printable_product).permit(:name, :slug, :category, :description, :size_label, :status)
    end

    # The repeater posts `canva_templates[][label]` and friends. A wholly blank
    # row is the empty slot the form always renders and is dropped; a HALF-filled
    # row is kept so the validator reports it rather than swallowing a typo.
    def submitted_canva_templates
      rows = params.permit(canva_templates: %i[label url description])[:canva_templates]

      Array(rows)
        .map { |row| row.to_h.stringify_keys.transform_values { |value| value.to_s.strip } }
        .reject { |row| row["label"].blank? && row["url"].blank? }
    end

    # The model re-checks type, size and count before anything is uploaded and
    # raises ArgumentError with a message worth showing.
    def attach_upload(upload, kind:)
      back = admin_dashboard_printable_product_path(@product)
      unless upload.respond_to?(:read) && upload.respond_to?(:original_filename)
        return redirect_to(back, alert: "Choose a file to upload.")
      end

      label = params[:label].to_s.strip.presence
      yield upload, label
      redirect_to back, notice: "Uploaded #{kind} “#{label || upload.original_filename}”."
    rescue ArgumentError, ActiveRecord::RecordInvalid => e
      redirect_to back, alert: "Couldn't upload “#{upload.original_filename}”: #{e.message}"
    end
  end
end
