# == Schema Information
#
# Table name: open_symbols
#
#  id               :bigint           not null, primary key
#  label            :string
#  image_url        :string
#  search_string    :string
#  symbol_key       :string
#  name             :string
#  locale           :string
#  license_url      :string
#  license          :string
#  original_os_id   :integer
#  repo_key         :string
#  unsafe_result    :string
#  protected_symbol :string
#  use_score        :string
#  relevance        :string
#  extension        :string
#  enabled          :boolean
#  author           :string
#  author_url       :string
#  source_url       :string
#  details_url      :string
#  hc               :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
require "test_helper"

class OpenSymbolTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
end
