require "rails_helper"

# `User#ensure_stripe_customer!` is the single funnel every billing touch goes
# through (checkout, top-ups, licenses, billing portal, plan changes). A stored
# `stripe_customer_id` that no longer resolves on the current Stripe key used to
# be handed straight to Stripe, which 400s with "No such customer" — permanently
# locking that account out of upgrading, with no self-service way back.
RSpec.describe User, "#ensure_stripe_customer!" do
  let(:user) { FactoryBot.create(:user, stripe_customer_id: "cus_existing") }

  def resource_missing_error
    Stripe::InvalidRequestError.new(
      "No such customer: 'cus_existing'",
      "customer",
      code: "resource_missing",
    )
  end

  it "keeps a customer id that still resolves on Stripe" do
    allow(Stripe::Customer).to receive(:retrieve)
      .with("cus_existing")
      .and_return(OpenStruct.new(id: "cus_existing"))
    expect(Stripe::Customer).not_to receive(:create)

    expect(user.ensure_stripe_customer!).to eq("cus_existing")
    expect(user.reload.stripe_customer_id).to eq("cus_existing")
  end

  it "creates a customer when the user has none yet" do
    user.update!(stripe_customer_id: nil)
    expect(Stripe::Customer).not_to receive(:retrieve)
    expect(Stripe::Customer).to receive(:create)
      .with({ email: user.email })
      .and_return(OpenStruct.new(id: "cus_brand_new"))

    expect(user.ensure_stripe_customer!).to eq("cus_brand_new")
    expect(user.reload.stripe_customer_id).to eq("cus_brand_new")
  end

  it "recreates the customer when Stripe reports it missing" do
    allow(Stripe::Customer).to receive(:retrieve).and_raise(resource_missing_error)
    expect(Stripe::Customer).to receive(:create)
      .with({ email: user.email })
      .and_return(OpenStruct.new(id: "cus_healed"))

    expect(user.ensure_stripe_customer!).to eq("cus_healed")
    expect(user.reload.stripe_customer_id).to eq("cus_healed")
  end

  it "recreates the customer when Stripe reports it deleted" do
    allow(Stripe::Customer).to receive(:retrieve)
      .and_return(OpenStruct.new(id: "cus_existing", deleted: true))
    expect(Stripe::Customer).to receive(:create).and_return(OpenStruct.new(id: "cus_healed"))

    expect(user.ensure_stripe_customer!).to eq("cus_healed")
  end

  # Fail open. Dropping a valid id on a Stripe blip would orphan the account
  # from its live subscription and billing history — far worse than the 400 the
  # caller is about to surface anyway.
  it "keeps the stored id when Stripe cannot be reached" do
    allow(Stripe::Customer).to receive(:retrieve)
      .and_raise(Stripe::APIConnectionError.new("network down"))
    expect(Stripe::Customer).not_to receive(:create)

    expect(user.ensure_stripe_customer!).to eq("cus_existing")
    expect(user.reload.stripe_customer_id).to eq("cus_existing")
  end

  it "keeps the stored id when Stripe rejects the request for an unrelated reason" do
    allow(Stripe::Customer).to receive(:retrieve)
      .and_raise(Stripe::AuthenticationError.new("bad key"))
    expect(Stripe::Customer).not_to receive(:create)

    expect(user.ensure_stripe_customer!).to eq("cus_existing")
  end
end
