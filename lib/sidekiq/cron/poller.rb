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
        locktime = time.to_i + (poll_interval_average * 1.5).to_i

        if getset_pulling_locktime(locktime).to_i > time.to_i
          locktime_count = get_pulling_locktime_count.to_i + 1
          set_pulling_locktime_count(locktime_count)

          if locktime_count > 10
            logger.error "cron_job_puller:locktime:count (#{locktime_count})"
          else
            return
          end
        end

        set_pulling_locktime_count(0)

        enqueueable_jobs = Sidekiq::Cron::Job.enqueueable(time)

        enqueueable_jobs.each do |job|
          enqueue_job(job, time)
        end

        if enqueueable_jobs.blank?
          empty_count = get_empty_enqueueable_jobs_count.to_i + 1
          set_empty_enqueueable_jobs_count(empty_count)

          if empty_count > 10
            logger.error "cron_job_puller:empty_enqueueable_jobs:count (#{empty_count})"

            Sidekiq::Cron::Job.all.each do |job|
              enqueue_job(job, time)
            end

            set_empty_enqueueable_jobs_count(0)
          end
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

      def get_pulling_locktime_count
        Sidekiq.redis_pool.with do |conn|
          conn.get('cron_job_puller:locktime:count')
        end
      end

      def set_pulling_locktime_count(count)
        Sidekiq.redis_pool.with do |conn|
          conn.set('cron_job_puller:locktime:count', count)
        end
      end

      def get_empty_enqueueable_jobs_count
        Sidekiq.redis_pool.with do |conn|
          conn.get('cron_job_puller:empty_enqueueable_jobs:count')
        end
      end

      def set_empty_enqueueable_jobs_count(count)
        Sidekiq.redis_pool.with do |conn|
          conn.set('cron_job_puller:empty_enqueueable_jobs:count', count)
        end
      end

    end
  end
end
