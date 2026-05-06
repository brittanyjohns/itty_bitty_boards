module MissionControl
  class SystemHealthMetrics
    def self.call = new.call

    def call
      sidekiq = sidekiq_stats
      {
        sidekiq_enqueued:   sidekiq[:enqueued],
        sidekiq_failed:     sidekiq[:failed],
        sidekiq_processed:  sidekiq[:processed],
        sidekiq_retries:    sidekiq[:retries],
        sidekiq_dead:       sidekiq[:dead],
        sidekiq_queues:     sidekiq[:queues],
        redis_connected:    redis_connected?,
        db_connected:       db_connected?,
      }
    end

    private

    def sidekiq_stats
      stats = Sidekiq::Stats.new
      queues = Sidekiq::Queue.all.to_h { |q| [q.name, q.size] }
      {
        enqueued:  stats.enqueued,
        failed:    stats.failed,
        processed: stats.processed,
        retries:   stats.retry_size,
        dead:      stats.dead_size,
        queues:    queues,
      }
    rescue => e
      Rails.logger.error "SystemHealthMetrics: sidekiq error #{e.message}"
      { enqueued: nil, failed: nil, processed: nil, retries: nil, dead: nil, queues: {} }
    end

    def redis_connected?
      Redis.current.ping == "PONG"
    rescue => e
      Rails.logger.error "SystemHealthMetrics: redis error #{e.message}"
      false
    end

    def db_connected?
      ActiveRecord::Base.connection.active?
    rescue => e
      false
    end
  end
end
