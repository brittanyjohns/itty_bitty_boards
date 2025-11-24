# == Schema Information
#
# Table name: board_screenshot_imports
#
#  id             :bigint           not null, primary key
#  user_id        :bigint           not null
#  name           :string
#  status         :string
#  guessed_rows   :integer
#  guessed_cols   :integer
#  confidence_avg :decimal(, )
#  error_message  :text
#  metadata       :jsonb
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
class BoardScreenshotImport < ApplicationRecord
  belongs_to :user
  has_one_attached :image
  has_many :board_screenshot_cells, dependent: :destroy
  has_many :boards, foreign_key: :board_screenshot_import_id

  validates :status, inclusion: { in: %w[queued processing needs_review committed failed completed] }

  include Rails.application.routes.url_helpers

  def index_view
    {
      id: id,
      name: name,
      created_at: created_at,
      status: status,
      guessed_rows: guessed_rows,
      guessed_cols: guessed_cols,
      confidence_avg: confidence_avg,
      screenshot_url: display_url,
    }
  end

  def show_view
    cells = board_screenshot_cells.order(:row, :col).select(:id, :row, :col, :label_raw, :label_norm, :confidence, :bbox, :bg_color)
    {
      id: id,
      name: name,
      created_at: created_at,
      status: status,
      guessed_rows: guessed_rows,
      guessed_cols: guessed_cols,
      confidence_avg: confidence_avg,
      screenshot_url: display_url,
      cells: cells,
      boards: boards,
    }
  end

  def display_url
    return if !image.attached?
    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      cdn_host = ENV["CDN_HOST"]
      if cdn_host
        "#{cdn_host}/#{image.key}" # Construct CloudFront URL
      else
        image.url # Fallback to the direct Active Storage URL
      end
    else
      image.url
    end
  end
end
