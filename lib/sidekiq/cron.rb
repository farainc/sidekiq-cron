require "sidekiq/cron/job"
require "sidekiq/cron/poller"
require "sidekiq/cron/launcher"

module Sidekiq
  module Cron
  end
end

if Redis::VERSION < '4.2'
  module RedisCompatible
    extend ActiveSupport::Concern

    def exists?(key)
      exists(key)
    end
  end

  Redis.send(:include, RedisCompatible)
end