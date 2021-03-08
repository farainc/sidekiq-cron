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
        timestamp = time.to_i

        locktime = timestamp + (poll_interval_average * 1.5).to_i

        return if getset_pulling_locktime(locktime).to_i > timestamp

        enqueueable_jobs, job_count = Sidekiq::Cron::Job.enqueueable(time)

        if enqueueable_jobs.blank? 
          empty_job_time = get_pulling_empty_enqueueable_job_time.to_i

          if empty_job_time == 0
            empty_job_time = timestamp
            empty_job_time += 60

            set_pulling_empty_enqueueable_job_time(empty_job_time)
          end

          if empty_job_time < timestamp
            enqueueable_jobs = Sidekiq::Cron::Job.all

            logger.error "Sidekiq::Cron::Poller:enqueueable_jobs:empty (#{job_count})"

            set_pulling_empty_enqueueable_job_time(0)
          end
        else
          set_pulling_empty_enqueueable_job_time(0)
        end

        enqueueable_jobs.each do |job|
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

      def get_pulling_empty_enqueueable_job_time
        Sidekiq.redis_pool.with do |conn|
          conn.get('cron_job_puller:empty_enqueueable_job_time')
        end
      end

      def set_pulling_empty_enqueueable_job_time(timestamp)
        Sidekiq.redis_pool.with do |conn|
          conn.set('cron_job_puller:empty_enqueueable_job_time', timestamp)
        end
      end
    end
  end
end
