# Speak Anyway

## Empowering communication through the power of AI

- Ruby version: 2.6.3

- System dependencies:

  - postgresql
  - redis
  - imagemagick
  - ffmpeg

- Environment Variables:

  - `AWS_ACCESS_KEY_ID` - AWS Access Key ID
  - `AWS_SECRET_ACCESS_KEY` - AWS Secret Access Key
  - `AWS_REGION` - AWS Region
  - `OPENAI_ACCESS_TOKEN` - OpenAI Access Token
  - `OPENAI_ORGANIZATION` - OpenAI Organization (optional)
  - `STRIPE_PUBLIC_KEY` - Stripe Public Key
  - `STRIPE_PRIVATE_KEY` - Stripe Private Key
  - `STRIPE_SIGNING_SECRET` - Stripe Signing Secret

- Database creation:

  - `rails db:create`
  - `rails db:migrate`

- Database initialization:

  - `rails db:seed`

- How to run the test suite:

  - WIP

- Services (job queues, cache servers, search engines, etc.):

  - `redis-server`
  - `bundle exec sidekiq`

- Deployment instructions:
  Deployed to Hatchbox.io
