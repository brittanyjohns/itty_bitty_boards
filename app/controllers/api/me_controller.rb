# app/controllers/api/me_controller.rb
class API::MeController < API::ApplicationController
  before_action :authenticate_token!

  # GET /api/me/credits
  def credits
    balance = CreditService.balance(current_user)
    render json: {
      plan: balance[:plan],
      topup: balance[:topup],
      total: balance[:total],
      reset_at: balance[:reset_at]&.iso8601,
      plan_type: current_user.plan_type,
    }
  end

  # GET /api/me/credit_transactions
  def credit_transactions
    page = (params[:page] || 1).to_i.clamp(1, 1000)
    per = (params[:per_page] || 25).to_i.clamp(1, 100)
    scope = current_user.credit_transactions.order(created_at: :desc)
    total = scope.count
    rows = scope.offset((page - 1) * per).limit(per)
    render json: {
      page: page,
      per_page: per,
      total: total,
      transactions: rows.map { |t| credit_transaction_json(t) },
    }
  end

  # GET /api/me/followed_pages
  def followed_pages
    pages = Page
      .joins("INNER JOIN page_follows ON page_follows.followed_page_id = profiles.id")
      .where("page_follows.follower_user_id = ?", current_user.id)
      .order("page_follows.created_at DESC")
      .limit(200)

    render json: pages.map { |p| page_json(p) }
  end

  # GET /api/me/page_followers
  # followers of *my* page (assuming your page is profileable: current_user)
  def page_followers
    my_page = Profile.find_by(profileable: current_user)
    return render json: [] if my_page.nil?

    followers = User
      .joins("INNER JOIN page_follows ON page_follows.follower_user_id = users.id")
      .where("page_follows.followed_page_id = ?", my_page.id)
      .order("page_follows.created_at DESC")
      .limit(200)

    render json: followers.map { |u| user_json(u) }
  end

  private

  def page_json(page)
    {
      id: page.id,
      # include whatever you need for UI cards
      title: page.try(:title),
      slug: page.try(:slug),
      profileable_type: page.profileable_type,
      profileable_id: page.profileable_id,
      public_url: page.public_url,
      avatar: page.avatar_url,
      headline: page.try(:headline) || page.try(:intro)
    }
  end

  def user_json(user)
    {
      id: user.id,
      name: user.try(:name),
      email: user.try(:email) # only include if you’re okay exposing this
    }
  end

  def credit_transaction_json(t)
    {
      id: t.id,
      amount: t.amount,
      kind: t.kind,
      source: t.source,
      feature_key: t.feature_key,
      expires_at: t.expires_at&.iso8601,
      created_at: t.created_at.iso8601,
      metadata: t.metadata,
    }
  end
end
