require 'sidekiq'
require 'sidekiq/util'
require 'sidekiq/cron'
require 'sidekiq/scheduled'

module Sidekiq
  module Cron

    # The Poller checks Redis every N seconds for sheduled cron jobs
    class Poller < Sidekiq::Scheduled::Poller
      def enqueue
        time = Time.now.utc
        timestamp = time.to_i
        current_locktime = get_pulling_locktime

        logger.warn "[#{time}] [#{Process.pid}] current_locktime: (#{current_locktime} > #{timestamp} = #{current_locktime > timestamp})"
        return if current_locktime > timestamp

        next_locktime = timestamp + 60 - timestamp % 60
        unique_locktime = getset_pulling_locktime(next_locktime).to_i

        logger.warn "[#{time}] [#{Process.pid}] unique_locktime: (#{unique_locktime} > #{timestamp} = #{unique_locktime > timestamp})"
        return if unique_locktime > timestamp

        enqueueable_jobs = if current_locktime + 60 < timestamp
                             Sidekiq::Cron::Job.all
                           else
                             Sidekiq::Cron::Job.enqueueable(time)
                           end

        enqueueable_jobs.each do |job|
          enqueue_job(job, time)
        end

        # reset locktime to zero (try_to_enqueue_all_cron_jobs)
        set_pulling_locktime(0) if enqueueable_jobs.size == 0
        logger.warn "[#{time}] [#{Process.pid}] enqueueable jobs size [#{enqueueable_jobs.size}]"
      rescue => ex
        set_pulling_locktime(0)
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

      # for cron job always check every 10 secs, regardless how many processes
      # 01 / 11 / 21 / 31 / 41 / 51
      def random_poll_interval
        now = Time.now.to_i

        pids = Sidekiq::ProcessSet.new.to_a.map{ |p| p['pid'] }
        pids = [Process.pid] if pids.size.zero?

        x = pids.size * 10 + 1
        y = (pids.index(Process.pid).to_i + 1) * 10

        x - now % y
      end

      def getset_pulling_locktime(locktime)
        Sidekiq.redis_pool.with do |conn|
          conn.getset('cron_job_puller:locktime', locktime)
        end
      end

      def get_pulling_locktime
        Sidekiq.redis_pool.with do |conn|
          conn.get('cron_job_puller:locktime')
        end
      end

      def set_pulling_locktime(locktime)
        Sidekiq.redis_pool.with do |conn|
          conn.set('cron_job_puller:locktime', locktime)
        end
      end
    end
  end
end
