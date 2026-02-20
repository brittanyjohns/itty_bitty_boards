# app/models/page.rb
class Page < Profile
  def headline
    public_settings(kind: :public)["headline"]
  end
end
