json.extract! openai_prompt, :id, :user_id, :prompt_text, :revised_prompt, :send_now, :deleted_at, :sent_at, :private, :response_type, :created_at, :updated_at
json.url openai_prompt_url(openai_prompt, format: :json)
