# Curation of the SEEDED LIBRARY — the shared Images every user's boards fall
# back to and every new tile is built from.
#
# Gated by inheritance (repo invariant): API::Admin::ApplicationController
# resolves an admin-role token or renders 401. Never add an inline
# `unless current_user.admin?` here.
#
# Two jobs, both of which the app could previously only do as a side effect of
# a user-shaped action:
#
#   * pin the library default picture for a word, and
#   * permanently remove a doc from the library.
#
# Both write to SHARED rows, so both route through the model methods that
# already encode the rules — Image#set_library_default_doc! (which is itself
# gated on can_edit?) and Images::TileArtFanout via `fanout_actor_id`. Nothing
# here reimplements the fan-out scoping.
class API::Admin::ImagesController < API::Admin::ApplicationController
  before_action :set_image

  # NOTE: the actor here is `current_admin`, never `current_user`.
  # API::Admin::ApplicationController descends from the TOP-LEVEL
  # ApplicationController (not API::ApplicationController), so `current_user`
  # resolves to Devise's session helper and is nil for a token-authenticated
  # request — silently turning every `actor:` into "no actor".

  # GET /api/admin/images/:id
  # The docs of one library image, with the current default marked. Uses
  # Doc.unscoped so an admin can see (and purge) soft-deleted rows too.
  def show
    render json: image_json
  end

  # POST /api/admin/images/:id/set_default_doc  { doc_id: }
  #
  # Moves BOTH halves of the library default: `docs.current` (what
  # Image#display_doc resolves through for a viewer with no pick of their own)
  # and `images.src_url` (what BoardImage#set_defaults snapshots onto every
  # FUTURE tile). They must stay in step — see the docs.current invariant.
  def set_default_doc
    doc = @image.docs.find_by(id: params[:doc_id])
    return render json: { error: "Doc not found for this image." }, status: :not_found unless doc

    unless @image.set_library_default_doc!(doc, actor: current_admin)
      return render json: { error: "Could not set the library default." }, status: :unprocessable_content
    end

    @image.fanout_actor_id = current_admin.id
    @image.update(src_url: doc.tile_url)

    render json: image_json
  end

  # DELETE /api/admin/images/:id/default_doc
  #
  # Unpins, and lets src_url fall back to whatever the remaining docs resolve
  # to. Deliberately NOT nil: a blank src_url is silently refilled by
  # `before_save :update_src_url` on the next unrelated save, which re-fires the
  # tile cascade from a surprising place.
  def clear_default_doc
    @image.docs.where(current: true).update_all(current: false)
    @image.reload

    @image.fanout_actor_id = current_admin.id
    @image.update(src_url: @image.docs.last&.tile_url)

    render json: image_json
  end

  # DELETE /api/admin/images/:id/docs/:doc_id
  #
  # A real delete, blob and all — this is the "remove it from the library"
  # action, not the user-facing hide. Unscoped so an already-hidden doc can be
  # purged for good.
  def destroy_doc
    doc = Doc.unscoped.find_by(id: params[:doc_id], documentable_type: "Image", documentable_id: @image.id)
    return render json: { error: "Doc not found for this image." }, status: :not_found unless doc

    was_default = @image.src_url.present? && @image.src_url == doc.tile_url
    doc.destroy

    # The default just died with the doc, so resolve to the next one rather
    # than leaving every tile pointing at a dead URL.
    if was_default
      @image.docs.reload
      @image.fanout_actor_id = current_admin.id
      @image.update(src_url: @image.docs.last&.tile_url)
    end

    render json: image_json
  end

  private

  def set_image
    @image = Image.find_by(id: params[:id] || params[:image_id])
    render json: { error: "Image not found." }, status: :not_found unless @image
  end

  def image_json
    @image.reload
    docs = Doc.unscoped.where(documentable_type: "Image", documentable_id: @image.id).order(:created_at)
    default_doc = @image.docs.current.last

    {
      image: {
        id: @image.id,
        label: @image.label,
        display_label: @image.display_label,
        language: @image.language,
        part_of_speech: @image.part_of_speech,
        user_id: @image.user_id,
        is_library_image: [nil, User::DEFAULT_ADMIN_ID].include?(@image.user_id),
        src_url: @image.src_url,
        default_doc_id: default_doc&.id,
      },
      docs: docs.map do |doc|
        {
          id: doc.id,
          src: doc.tile_url,
          user_id: doc.user_id,
          source_type: doc.source_type,
          is_current: doc.id == default_doc&.id,
          deleted_at: doc.deleted_at,
          created_at: doc.created_at,
        }
      end,
    }
  end
end
