# == Schema Information
#
# Table name: board_cell_candidates
#
#  id                         :bigint           not null, primary key
#  board_screenshot_import_id :bigint           not null
#  row                        :integer
#  col                        :integer
#  label_raw                  :string
#  label_norm                 :string
#  confidence                 :decimal(, )
#  bbox                       :json
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#
class BoardScreenshotCell < ApplicationRecord
  belongs_to :board_screenshot_import
end
