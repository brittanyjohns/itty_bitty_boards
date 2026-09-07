require "rails_helper"

# Every board write in API::BoardsController ran behind check_board_editable!,
# and User#board_editable? opens with `return true if board.user_id != id` — it
# measures the PLAN lock, not permission. set_board scopes by nothing (any id or
# slug resolves), so a signed-in caller could regenerate the AI art on, recolor,
# re-lay-out, or strip the cover off any board in the corpus by incrementing an
# integer. Only update / destroy / add_word_pack carried an ownership check.
#
# The gate is owner-or-admin, the same answer Board#can_edit_for gives — so the
# `can_edit` flag the payload already publishes and the gate the server enforces
# are one decision. Team membership grants VIEWING, never editing.
RSpec.describe "API::Boards write-permission gate", type: :request do
  def json = JSON.parse(response.body)

  let!(:owner)    { create(:user) }
  let!(:stranger) { create(:user) }
  let!(:admin)    { create(:admin_user) }
  let!(:image)    { create(:image) }
  let!(:board)    { create(:board, user: owner) }

  # Every action in check_board_editable!'s list EXCEPT add_image, which is the
  # communicator Quick-add path and is scoped by check_communicator_board_access!
  # (covered by spec/requests/api/boards_quick_add_spec.rb), plus the three that
  # were already gated — their refusal shape changed here too.
  #
  # KEEP THIS LIST IN STEP WITH THE before_action LISTS. #edit_images was added
  # to all three of them by #867 and to none of this, so the only thing pinning
  # its refusal was an example in its own spec written against the pre-#866 gate
  # — which asserted 401, a status the gate no longer renders. An action absent
  # here is an action whose gate nothing checks.
  def writes(target)
    [
      [:post, "regenerate_images",           { board_image_ids: [1] }],
      [:post, "edit_images",                 { board_image_ids: [1], prompt: "make it blue" }],
      [:put,  "recategorize_images",         {}],
      [:put,  "set_colors",                  {}],
      [:post, "format_with_ai",              {}],
      [:post, "save_layout",                 {}],
      [:post, "rearrange_images",            {}],
      [:put,  "update_to_default_docs",      {}],
      [:put,  "associate_image",             { image_id: image.id }],
      [:put,  "associate_images",            { image_ids: [image.id] }],
      [:post, "remove_image",                {}],
      [:put,  "set_display_image",           { source: "preview" }],
      [:put,  "update_preset_display_image", { board: { name: target.name } }],
      [:post, "generate_preview_image",      {}],
      [:post, "add_word_pack",               { pack_key: "pronouns", words: ["he"] }],
    ].map { |verb, action, params| [verb, "/api/boards/#{target.id}/#{action}", params, action] }
  end

  def call(verb, path, params, as:)
    public_send(verb, path, params: params, headers: auth_headers(as))
  end

  # The gate's two refusal shapes. An action may legitimately answer 404 or 403
  # for its OWN reasons (a missing word pack, a plan-locked board), so "the gate
  # let this through" is asserted against the exact bodies the gate renders.
  def expect_gate_to_allow(action)
    aggregate_failures(action) do
      expect(response.status).to be < 500
      refusal = { 404 => "Board not found", 403 => "Unauthorized" }[response.status]
      next if refusal.nil?

      expect(json["error"]).not_to(eq(refusal), "#{action} was refused by the ownership gate")
    end
  end

  describe "a board the caller cannot see" do
    it "404s every write, with the same generic body #show uses" do
      writes(board).each do |verb, path, params, action|
        call(verb, path, params, as: stranger)

        aggregate_failures(action) do
          expect(response).to have_http_status(:not_found)
          expect(json["error"]).to eq("Board not found")
        end
      end
    end

    it "leaves the board untouched" do
      before_state = board.attributes

      writes(board).each { |verb, path, params, _| call(verb, path, params, as: stranger) }

      expect(board.reload.attributes).to eq(before_state)
    end

    it "enqueues no image-regeneration job" do
      create(:board_image, board: board, image: image)
      GenerateImagesJob.jobs.clear

      post "/api/boards/#{board.id}/regenerate_images",
           params: { board_image_ids: board.board_image_ids },
           headers: auth_headers(stranger)

      expect(response).to have_http_status(:not_found)
      expect(GenerateImagesJob.jobs).to be_empty
    end
  end

  describe "a board the caller CAN see but does not own" do
    # Nothing left to leak once the board is visible, so the answer is the
    # permission one. 403, never 402 (credits) and never 429 (rate limiting).
    it "403s every write on a published board" do
      board.update!(published: true)

      writes(board).each do |verb, path, params, action|
        call(verb, path, params, as: stranger)

        aggregate_failures(action) do
          expect(response).to have_http_status(:forbidden)
          expect(json["error"]).to eq("Unauthorized")
        end
      end
    end

    it "403s every write for a team member the board is shared with" do
      team = create(:team, created_by: owner)
      TeamBoard.create!(team: team, board: board)
      TeamUser.create!(team: team, user: stranger, role: "member")

      writes(board).each do |verb, path, params, action|
        call(verb, path, params, as: stranger)

        aggregate_failures(action) do
          expect(response).to have_http_status(:forbidden)
          expect(json["error"]).to eq("Unauthorized")
        end
      end
    end

    it "leaves a team member's READ of the shared board untouched" do
      team = create(:team, created_by: owner)
      TeamBoard.create!(team: team, board: board)
      TeamUser.create!(team: team, user: stranger, role: "member")

      get "/api/boards/#{board.id}", headers: auth_headers(stranger)

      expect(response).to have_http_status(:ok)
      expect(json["id"]).to eq(board.id)
    end
  end

  describe "callers who may write" do
    it "lets the owner through on every write" do
      writes(board).each do |verb, path, params, action|
        call(verb, path, params, as: owner)
        expect_gate_to_allow(action)
      end
    end

    it "lets an admin through on someone else's board" do
      writes(board).each do |verb, path, params, action|
        call(verb, path, params, as: admin)
        expect_gate_to_allow(action)
      end
    end

    it "still enqueues the regeneration job for the owner" do
      create(:board_image, board: board, image: image)
      GenerateImagesJob.jobs.clear

      post "/api/boards/#{board.id}/regenerate_images",
           params: { board_image_ids: board.board_image_ids },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(GenerateImagesJob.jobs).not_to be_empty
    end

    it "still lets the owner switch the board cover" do
      put "/api/boards/#{board.id}/set_display_image",
          params: { source: "preview" },
          headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(board.reload.settings["display_image_source"]).to eq("preview")
    end
  end

  describe "add_image" do
    # add_image is the one board write a COMMUNICATOR may make, so it can't join
    # the ownership before_action wholesale — a communicator token has no
    # current_user and owns no board. The USER branch of its own gate delegates
    # to the same ownership answer; the communicator branch is untouched.
    it "refuses a signed-in stranger, and writes nothing" do
      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "apple" } },
             headers: auth_headers(stranger)
      }.not_to change(BoardImage, :count)

      expect(response).to have_http_status(:not_found)
      expect(json["error"]).to eq("Board not found")
    end

    it "still lets the owner add to their own board" do
      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "apple" } },
             headers: auth_headers(owner)
      }.to change { board.reload.board_images.count }.by(1)

      expect(response).to have_http_status(:ok)
    end

    it "still lets a communicator add to a board on their dashboard" do
      communicator = create(:child_account, user: owner)
      create(:child_board, board: board, child_account: communicator)

      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "banana" } },
             headers: auth_headers(communicator)
      }.to change { board.reload.board_images.count }.by(1)

      expect(response).to have_http_status(:ok)
    end
  end
end
