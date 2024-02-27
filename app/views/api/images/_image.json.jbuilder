# id                  :bigint           not null, primary key
#  label               :string
#  image_prompt        :text
#  display_description :text
#  private             :boolean
#  user_id             :integer
#  generate_image      :boolean          default(FALSE)
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  status              :string
#  error               :string
#  revised_prompt      :string
#  image_type          :string
#  open_symbol_status  

json.extract! image, :id, :label, :image_prompt, :private, :user_id, :created_at, :updated_at, :status, :error, :revised_prompt, :image_type, :open_symbol_status
json.url image_url(image, format: :json)
