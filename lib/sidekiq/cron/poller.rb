require 'sidekiq'
require 'sidekiq/util'
require 'sidekiq/cron'
require 'sidekiq/scheduled'

module Sidekiq
  module Cron

    # The Poller checks Redis every N seconds for sheduled cron jobs
    class Poller < Sidekiq::Scheduled::Poller
      DEFAULT_CRON_POLL_INTERVAL = 10
      DEFAULT_CRON_SAFE_INTERVAL = 60
      DEFAULT_CRON_ENQUEUE_LOCKTIME = 300

      attr_reader :current_process_pid
      attr_reader :process_base_interval
      attr_reader :safe_random_interval
      attr_reader :active_process_pids
      attr_reader :active_process_count
      attr_reader :active_process_interval

      def initialize
        @current_process_pid = ::Process.pid
        @process_base_interval = 0
        @safe_random_interval = 0
        @active_process_pids = []
        @active_process_count = 0
        @active_process_interval = 0

        super
      end

      def enqueue
        time = Time.now.utc
        timestamp = time.to_f
        current_locktime = get_pulling_locktime.to_f

        logger.warn "[#{current_process_pid}] current_locktime skip? [#{current_locktime > timestamp}] (#{current_locktime} > #{timestamp})"
        return if current_locktime > timestamp

        timeout_locktime = timestamp + DEFAULT_CRON_ENQUEUE_LOCKTIME - timestamp % DEFAULT_CRON_SAFE_INTERVAL
        unique_locktime = getset_pulling_locktime(timeout_locktime).to_f

        logger.warn "[#{current_process_pid}] unique_locktime skip? [#{unique_locktime > timestamp}] (#{unique_locktime} > #{timestamp})"
        return if unique_locktime > timestamp

        enqueueable_jobs = if current_locktime + DEFAULT_CRON_SAFE_INTERVAL < timestamp
                             Sidekiq::Cron::Job.all
                           else
                             Sidekiq::Cron::Job.enqueueable(time)
                           end

        enqueueable_jobs.each do |job|
          enqueue_job(job, time)
        end

        # reset locktime to zero (try_to_enqueue_all_cron_jobs)
        next_locktime = if enqueueable_jobs.size == 0
                          0
                        else
                          timestamp + DEFAULT_CRON_SAFE_INTERVAL - timestamp % DEFAULT_CRON_SAFE_INTERVAL
                        end

        set_pulling_locktime(next_locktime)

        cleanup_next_enqueue_schedule(time.to_i)

        logger.warn "[#{current_process_pid}] enqueueable jobs size: (#{enqueueable_jobs.size})"
      rescue => ex
        set_pulling_locktime(0)
        # Most likely a problem with redis networking.
        # Punt and try again at the next interval
        logger.error ex.message
        logger.error ex.backtrace.first
        handle_exception(ex) if respond_to?(:handle_exception)
      end

      def cleanup_next_enqueue_schedule_process
        Sidekiq.redis_pool.with do |conn|
          conn.zrem('cron_job_puller:enqueue', current_process_pid)
        end
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

      # for cron job always check every 10 secs,
      # regardless how many processes
      # standard poller schedule: [01, 11, 21, 31, 41, 51]
      def random_poll_interval
        now = Time.now.to_f

        interval = calculate_process_based_interval(now)

        interval = calculate_safe_enqueue_interval(now, interval) + safe_random_interval

        logger.warn "[#{current_process_pid}] random_poll_interval: (#{interval})"

        interval
      end

      def load_current_active_process_stats
        new_process_pids = Sidekiq::ProcessSet.new.map{ |p| p.stopping? ? nil : p['pid'] }.compact
        new_process_pids = [current_process_pid] if new_process_pids.size == 0

        # update rand interval in case process_count changed
        # avoid concurrent poller triggers
        @safe_random_interval = 0

        if @active_process_pids != new_process_pids
          @safe_random_interval = 7 * rand
          @active_process_pids = new_process_pids
          @active_process_count = @active_process_pids.size
          @process_base_interval = @active_process_count * DEFAULT_CRON_POLL_INTERVAL
          @active_process_interval = @active_process_pids.index(current_process_pid).to_i * DEFAULT_CRON_POLL_INTERVAL + DEFAULT_CRON_POLL_INTERVAL + 1
        end
      end

      def calculate_process_based_interval(now)
        load_current_active_process_stats

        interval = active_process_interval - now % process_base_interval
        interval += process_base_interval if interval < 0

        interval
      end

      def calculate_safe_enqueue_interval(now, interval)
        return interval if interval <= DEFAULT_CRON_SAFE_INTERVAL

        # set next enqueue schedule for current_process_pid
        future_enqueue_schedule = (now + interval).to_i
        if future_enqueue_schedule % DEFAULT_CRON_SAFE_INTERVAL == 1
          set_next_enqueue_schedule(future_enqueue_schedule)

          return interval
        end

        next_enqueue_schedule = (now + DEFAULT_CRON_SAFE_INTERVAL - now % DEFAULT_CRON_SAFE_INTERVAL).to_i + 1
        next_enqueue_process_pid = get_next_enqueue_schedule(next_enqueue_schedule).first.to_i
        return interval if active_process_pids.index(next_enqueue_process_pid)

        # set next enqueue schedule
        set_next_enqueue_schedule(next_enqueue_schedule)

        # avoid concurrent update for next_enqueue_schedule
        next_enqueue_process_pid = get_next_enqueue_schedule(next_enqueue_schedule).first.to_i
        return interval if next_enqueue_process_pid != current_process_pid

        logger.warn "[#{current_process_pid}] calculate_safe_enqueue_interval override: (#{interval})"

        next_enqueue_schedule - now
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

      def set_next_enqueue_schedule(time)
        Sidekiq.redis_pool.with do |conn|
          conn.zadd('cron_job_puller:enqueue', [time, current_process_pid])
        end
      end

      def get_next_enqueue_schedule(time)
        Sidekiq.redis_pool.with do |conn|
          conn.zrangebyscore('cron_job_puller:enqueue', time, time)
        end
      end

      def cleanup_next_enqueue_schedule(time)
        Sidekiq.redis_pool.with do |conn|
          conn.zremrangebyscore('cron_job_puller:enqueue', 0, time)
        end
      end
    end
  end
end
