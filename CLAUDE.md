# SpeakAnyWay — Backend

Ruby on Rails 7 app (hybrid: API + HTML views). Deployed on EC2 via Hatchbox.

## Stack

- **Framework:** Rails 7
- **Language:** Ruby
- **Database:** PostgreSQL
- **Auth:** Devise + devise-jwt
- **Authorization:** Pundit
- **Background jobs:** Sidekiq (v7) + Redis
- **Payments:** Stripe via Pay gem; also Braintree and Paddle
- **File storage:** S3 (Active Storage)
- **Email:** Mailgun (via Action Mailer)
- **TTS/Audio:** AWS Polly
- **AI:** OpenAI API (`ruby-openai`) — board generation, scenario builder, image generation
- **Serializers:** jsonapi-serializer gem
- **Hosting:** Hatchbox / EC2

## Routing

- Routes are mixed: some at root level, some under `/api/`, some under `/api/v1/`
- JSON API routes are generally under `namespace :api` (with `defaults: { format: :json }`)
- Auth routes (`/api/v1/`) live in `app/controllers/api/v1/`
- Do not assume all routes follow a single convention — check `config/routes.rb`

## Code conventions

- Standard Ruby style — no unnecessary metaprogramming
- Fat models, thin controllers
- Return JSON with `{ data: ... }` envelope on API responses
- Use snake_case everywhere (Ruby/Rails standard)

## File structure

- Controllers in `app/controllers/` (various namespaces — see routing above)
- Models in `app/models/`
- Serializers in `app/serializers/`
- Background jobs in `app/jobs/` and `app/sidekiq/`
- OpenAI / external integrations in `app/services/`
- Authorization policies in `app/policies/`

## Common commands

- `rails s` — start server (port 3000)
- `rails c` — Rails console
- `rails db:migrate` — run migrations
- `bundle exec rubocop` — lint (if configured)
- `bundle exec sidekiq` — start background job worker

## Subscription model

- Most features are free
- Premium features (Menu Board Creator, AI image generation) require active subscription
- Subscription managed via Stripe/Pay — check status before allowing access to premium endpoints

## AAC image rules

- No text in images — visual elements only
- Export as transparent PNG
- Clean, simple, non-cartoonish style
- Do not use the word "Autism" in any image prompt or alt text
- Always refer to the app as "SpeakAnyWay" (never "SAW") in any user-facing content

## Do not

- Do not install new gems without asking first
- Do not modify any deployment or server config files
- Do not log sensitive user data
- Do not expose internal errors in API responses — return generic messages to the client
- Do not hardcode any environment-specific values (use ENV variables)

## Testing preferences:

- Prefer FactoryBot.build over create where possible
- Add focused tests for changed behavior
- Avoid destructive S3/ActiveStorage behavior in tests
