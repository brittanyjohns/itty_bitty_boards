json.extract! prompt_template, :id, :user_id, :prompt_text, :revised_prompt, :send_now, :deleted_at, :sent_at, :private, :response_type, :created_at, :updated_at
json.url prompt_template_url(prompt_template, format: :json)
