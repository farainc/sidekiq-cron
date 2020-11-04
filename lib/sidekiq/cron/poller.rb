require 'sidekiq'
require 'sidekiq/util'
require 'sidekiq/cron'
require 'sidekiq/scheduled'

module Sidekiq
  module Cron
    POLL_INTERVAL = 30

    # The Poller checks Redis every N seconds for sheduled cron jobs
    class Poller < Sidekiq::Scheduled::Poller
      def enqueue
        time = Time.now.utc
        locktime = time.to_i + (poll_interval_average * 0.5).to_i

        return if getset_pulling_locktime(locktime).to_i > time.to_i

        Sidekiq::Cron::Job.enqueueable(time).each do |job|
          enqueue_job(job, time)
        end

        getset_pulling_locktime(0)
      rescue => ex
        getset_pulling_locktime(0)
        # Most likely a problem with redis networking.
        # Punt and try again at the next interval
        logger.error ex.message
        logger.error ex.backtrace.first
        handle_exception(ex) if respond_to?(:handle_exception)
      end

      private

      def enqueue_job(job, time = Time.now.utc)
        job.test_and_enque_for_time!(time) if job && job.valid?
      rescue => ex
        # problem somewhere in one job
        logger.error "CRON JOB: #{ex.message}"
        logger.error "CRON JOB: #{ex.backtrace.first}"
        handle_exception(ex) if respond_to?(:handle_exception)
      end

      def poll_interval_average
         Sidekiq.options[:poll_interval] || POLL_INTERVAL
      end

      def getset_pulling_locktime(locktime)
        Sidekiq.redis_pool.with do |conn|
          conn.getset('cron_job_puller:locktime', locktime)
        end
      end
    end
  end
end
