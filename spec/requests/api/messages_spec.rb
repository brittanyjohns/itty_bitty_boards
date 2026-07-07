require "rails_helper"

RSpec.describe "API::Messages", type: :request do
  let(:sender)    { create(:user) }
  let(:recipient) { create(:user) }
  let(:attacker)  { create(:user) }

  describe "POST /api/messages" do
    it "creates a message from the authenticated user to the chosen recipient" do
      post "/api/messages",
           params: { message: { subject: "Hi", body: "Hello", recipient_id: recipient.id } },
           headers: auth_headers(sender)

      expect(response).to have_http_status(:created)
      message = Message.last
      expect(message.sender_id).to eq(sender.id)
      expect(message.recipient_id).to eq(recipient.id)
    end

    # Regression for #27: a client must not be able to forge the sender.
    it "ignores a client-supplied sender_id (mass-assignment)" do
      post "/api/messages",
           params: { message: { subject: "Spoofed", body: "Not from me",
                                sender_id: attacker.id, recipient_id: recipient.id } },
           headers: auth_headers(sender)

      expect(response).to have_http_status(:created)
      message = Message.last
      expect(message.sender_id).to eq(sender.id)
      expect(message.sender_id).not_to eq(attacker.id)
    end
  end

  describe "PATCH /api/messages/:id" do
    # Regression for #27: updating a message must not reassign the sender.
    it "does not let a client change sender_id on update" do
      message = Message.create!(subject: "S", body: "B",
                                sender_id: sender.id, recipient_id: recipient.id)

      patch "/api/messages/#{message.id}",
            params: { message: { subject: "Edited", sender_id: attacker.id } },
            headers: auth_headers(sender)

      expect(response).to have_http_status(:ok)
      message.reload
      expect(message.sender_id).to eq(sender.id)
      expect(message.subject).to eq("Edited")
    end
  end
end
