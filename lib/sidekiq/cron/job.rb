require 'fugit'
require 'sidekiq'
require 'sidekiq/util'
require 'sidekiq/cron/support'

module Sidekiq
  module Cron
    class Job
      include Util
      extend Util

      # how long we would like to store informations about previous enqueues
      REMEMBER_THRESHOLD = 24 * 60 * 60
      ENQUEUE_TIME_FORMAT = '%Y-%m-%d %H:%M:%S %z'.freeze
      ENQUEUE_TIME_FORMAT_OLD = '%Y-%m-%d %H:%M:%S'.freeze

      attr_accessor :name, :cron, :description, :klass, :args, :message
      attr_reader   :last_enqueue_timestamp, :next_enqueue_timestamp, :fetch_missing_args, :status

      def initialize(input_args = {})
        args = Hash[input_args.map { |k, v| [k.to_s, v] }]
        @fetch_missing_args = args.delete('fetch_missing_args')
        @fetch_missing_args = true if @fetch_missing_args.nil?

        @name = args['name']
        @cron = args['cron']
        @description = args['description'] if args['description']

        # get class from klass or class
        @klass = (args['klass'] || args['class']).to_s

        # set status of job
        @status = args['status'] || status_from_redis

        # set last enqueue time - from args or from existing job
        if !args['last_enqueue_time'].to_s.empty?
          @last_enqueue_timestamp = parse_enqueue_time(args['last_enqueue_time']).to_i
        else
          @last_enqueue_timestamp = last_enqueue_time_from_redis
        end

        # set next_enqueue_time - from args or from existing job
        @next_enqueue_timestamp = args['next_enqueue_time'].to_i
        @next_enqueue_timestamp = next_enqueue_time_from_redis if @next_enqueue_timestamp == 0

        # get right arguments for job
        @args = args['args'].nil? ? [] : parse_args(args['args'])

        @active_job = args['active_job'] == true || ((args['active_job']).to_s =~ /^(true|t|yes|y|1)$/i) == 0 || false
        @active_job_queue_name_prefix = args['queue_name_prefix']
        @active_job_queue_name_delimiter = args['queue_name_delimiter']

        if args['message']
          @message = args['message']
          message_data = Sidekiq.load_json(@message) || {}
          @queue = message_data['queue'] || 'default'
        elsif @klass
          message_data = {
            'class' => @klass.to_s,
            'args'  => @args
          }

          # get right data for message
          # only if message wasn't specified before
          klass_data = case @klass
                       when Class
                         @klass.get_sidekiq_options
                       when String
                         begin
                           Sidekiq::Cron::Support.constantize(@klass).get_sidekiq_options
                         rescue Exception => e
                           # Unknown class
                           { 'queue' => 'default' }
                         end
                       end

          message_data = klass_data.merge(message_data)
          # override queue if setted in config
          # only if message is hash - can be string (dumped JSON)
          @queue = if args['queue']
                     message_data['queue'] = args['queue']
                   else
                     message_data['queue'] || 'default'
                   end

          # dump message as json
          @message = message_data
        end

        @queue_name_with_prefix = queue_name_with_prefix
      end

      # test if job should be enqued If yes add it to queue
      def test_and_enque_for_time!(time)
        # should this job be enqued?
        return unless should_enque?(time)

        enque!
      end

      # crucial part of whole enquing job
      def should_enque?(time)
        return false if disabled?
        return false if not_pass_next_enqueue_time?(time)

        # support old data without next_enqueue_timestamp
        return false if did_pass_prev_enqueue_time?(time)

        true
      end

      def not_pass_next_enqueue_time?(time)
        @next_enqueue_timestamp > 0 && @next_enqueue_timestamp > time.to_i
      end

      def did_pass_prev_enqueue_time?(time)
        @next_enqueue_timestamp == 0 && @last_enqueue_timestamp > calculate_previous_enqueue_time(time).to_i
      end

      # enque cron job to queue
      def enque!(time = Time.now.utc)
        @last_enqueue_timestamp = time.to_i
        @next_enqueue_timestamp = calculate_next_enqueue_time(time).to_i

        klass_const =
          begin
            Sidekiq::Cron::Support.constantize(@klass.to_s)
          rescue NameError
            nil
          end

        jid =
          if klass_const
            if defined?(ActiveJob::Base) && klass_const < ActiveJob::Base
              job = enqueue_active_job(klass_const)
              job.try(:job_id)
            else
              enqueue_sidekiq_worker(klass_const)
            end
          else
            if @active_job
              Sidekiq::Client.push(active_job_message)
            else
              Sidekiq::Client.push(sidekiq_worker_message)
            end
          end

        save_enqueue_time_options

        save_job_history(jid)

        logger.debug { "Cron Jobs - enqueued #{@name}: #{@message}" }
      end

      def save_enqueue_time_options
        Sidekiq.redis do |conn|
          # update last enqueue time & next enqueue time
          conn.hmset(redis_key, 'last_enqueue_time', @last_enqueue_timestamp, 'next_enqueue_time', @next_enqueue_timestamp)
        end
      end

      # Parse cron specification '* * * * *' and returns
      # time when last run should be performed
      def calculate_previous_enqueue_time(time)
        parsed_cron.previous_time(time.utc).utc
      end

      def calculate_next_enqueue_time(time)
        parsed_cron.next_time(time.utc).utc
      end

      def parse_enqueue_time(timestamp)
        return Time.at(timestamp.to_i).utc if timestamp.is_a?(Integer) || timestamp.to_s =~ /^\d+$/

        DateTime.strptime(timestamp, ENQUEUE_TIME_FORMAT).to_time.utc
      rescue ArgumentError
        DateTime.strptime(timestamp, ENQUEUE_TIME_FORMAT_OLD).to_time.utc
      end

      def last_enqueue_time_from_redis
        return 0 unless fetch_missing_args

        Sidekiq.redis do |conn|
          begin
            parse_enqueue_time(conn.hget(redis_key, 'last_enqueue_time')).to_i
          rescue StandardError
            0
          end
        end
      end

      def next_enqueue_time_from_redis
        return 0 unless fetch_missing_args

        Sidekiq.redis do |conn|
          conn.hget(redis_key, 'next_enqueue_time').to_i
        end
      end

      def status_from_redis
        return 'enabled' unless fetch_missing_args

        Sidekiq.redis do |conn|
          conn.hget(redis_key, 'status') || 'enabled'
        end
      end

      def disable!
        @status = 'disabled'
        save
      end

      def enable!
        @status = 'enabled'
        save
      end

      def enabled?
        @status == 'enabled'
      end

      def disabled?
        !enabled?
      end

      def errors
        @errors ||= []
      end

      def valid?
        # clear previous errors
        @errors = []

        errors << "'name' must be set" if @name.nil? || @name.empty?

        if @cron.nil? || @cron.empty?
          errors << "'cron' must be set"
        else
          begin
            @parsed_cron = Fugit.do_parse_cron(@cron)
          rescue StandardError => e
            errors << "'cron' -> #{@cron.inspect} -> #{e.class}: #{e.message}"
          end
        end

        errors << "'klass' (or class) must be set" unless klass_valid

        errors.empty?
      end

      def klass_valid
        case @klass
        when Class
          true
        when String
          !@klass.empty?
        else
          false
        end
      end

      # active_job related
      def is_active_job?
        @active_job || defined?(ActiveJob::Base) && Sidekiq::Cron::Support.constantize(@klass.to_s) < ActiveJob::Base
      rescue NameError
        false
      end

      def enqueue_active_job(klass_const)
        klass_const.set(queue: @queue).perform_later(*@args)
      end

      def enqueue_sidekiq_worker(klass_const)
        klass_const.set(queue: queue_name_with_prefix).perform_async(*@args)
      end

      # siodekiq worker message
      def sidekiq_worker_message
        @message.is_a?(String) ? Sidekiq.load_json(@message) : @message
      end

      def queue_name_with_prefix
        return @queue unless is_active_job?

        if !@active_job_queue_name_delimiter.to_s.empty?
          queue_name_delimiter = @active_job_queue_name_delimiter
        elsif defined?(ActiveJob::Base) && defined?(ActiveJob::Base.queue_name_delimiter) && !ActiveJob::Base.queue_name_delimiter.empty?
          queue_name_delimiter = ActiveJob::Base.queue_name_delimiter
        else
          queue_name_delimiter = '_'
        end

        if !@active_job_queue_name_prefix.to_s.empty?
          queue_name = "#{@active_job_queue_name_prefix}#{queue_name_delimiter}#{@queue}"
        elsif defined?(ActiveJob::Base) && defined?(ActiveJob::Base.queue_name_prefix) && !ActiveJob::Base.queue_name_prefix.to_s.empty?
          queue_name = "#{ActiveJob::Base.queue_name_prefix}#{queue_name_delimiter}#{@queue}"
        else
          queue_name = @queue
        end

        queue_name
      end

      # active job has different structure how it is loading data from sidekiq
      # queue, it createaswrapper arround job
      def active_job_message
        {
          'class'        => 'ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper',
          'wrapped'      => @klass,
          'queue'        => @queue_name_with_prefix,
          'description'  => @description,
          'args'         => [{
            'job_class'  => @klass,
            'job_id'     => SecureRandom.uuid,
            'queue_name' => @queue_name_with_prefix,
            'arguments'  => @args
          }]
        }
      end

      # add job to cron jobs
      # input:
      #   name: (string) - name of job
      #   cron: (string: '* * * * *' - cron specification when to run job
      #   class: (string|class) - which class to perform
      # optional input:
      #   queue: (string) - which queue to use for enquing (will override class queue)
      #   args: (array|hash|nil) - arguments for permorm method
      def save
        # if job is invalid return false
        return false unless valid?

        # update next_enqueue_timestamp
        @next_enqueue_timestamp = calculate_next_enqueue_time(Time.now.utc).to_i

        Sidekiq.redis do |conn|
          # add to set of all jobs
          conn.sadd(self.class.jobs_key, redis_key)

          # add informations for this job!
          conn.hmset(redis_key, *hash_to_redis(to_hash))
        end

        logger.info { "Cron Jobs - add job with name: #{@name}" }
      end

      def exists?
        self.class.exists?(@name)
      end

      # jid history
      def save_job_history(jid)
        jid_history = {
          jid: jid,
          enqueued: @last_enqueue_timestamp,
          next_enqueue_at: @next_enqueue_timestamp
        }
        @history_size ||= (Sidekiq.options[:cron_history_size] || 10).to_i - 1
        Sidekiq.redis do |conn|
          conn.lpush(jid_history_key, Sidekiq.dump_json(jid_history))
          # keep only last 10 entries in a fifo manner
          conn.ltrim(jid_history_key, 0, @history_size)
        end
      end

      def jid_history_from_redis
        out =
          Sidekiq.redis do |conn|
            begin
              conn.lrange(jid_history_key, 0, -1)
            rescue StandardError
              nil
            end
          end

        # returns nil if out nil
        out && out.map do |jid_history_raw|
          Sidekiq.load_json jid_history_raw
        end
      end

      # remove job from cron jobs by name
      # input:
      #   first arg: name (string) - name of job (must be same - case sensitive)
      def destroy
        Sidekiq.redis do |conn|
          # delete from set
          conn.srem self.class.jobs_key, redis_key

          # delete runned timestamps
          # conn.del job_enqueued_key

          # delete jid_history
          conn.del jid_history_key

          # delete main job
          conn.del redis_key
        end

        logger.info { "Cron Jobs - deleted job with name: #{@name}" }
      end

      def sort_name
        "#{enabled? ? 0 : 1}_#{name}".downcase
      end

      def pretty_message
        JSON.pretty_generate Sidekiq.load_json(message)
      rescue JSON::ParserError
        message
      end

      # export job data to hash
      def to_hash
        {
          name: @name,
          klass: @klass,
          cron: @cron,
          description: @description,
          args: @args.is_a?(String) ? @args : Sidekiq.dump_json(@args || []),
          message: @message.is_a?(String) ? @message : Sidekiq.dump_json(@message || {}),
          status: @status,
          active_job: @active_job,
          queue_name_prefix: @active_job_queue_name_prefix,
          queue_name_delimiter: @active_job_queue_name_delimiter,
          last_enqueue_time: @last_enqueue_timestamp,
          next_enqueue_time: @next_enqueue_timestamp
        }
      end

      # get all cron jobs
      def self.all
        job_hashes = all_job_hashes

        job_hashes.each do |h|
          # no need to fetch missing args from redis since we just got this hash from there
          Sidekiq::Cron::Job.new(h.merge(fetch_missing_args: false))
        end
      end

      # get current time enqueable cron jobs
      def self.enqueueable(enqueue_at = Time.now.utc)
        now = enqueue_at.to_i

        job_hashes = all_job_hashes

        jobs = job_hashes.each do |h|
          next_timestamp = h['next_enqueue_time'].to_i

          if h['status'] == 'enabled' && (next_timestamp == 0 || next_timestamp < now)
            Sidekiq::Cron::Job.new(h.merge(fetch_missing_args: false))
          end
        end

        jobs.compact
      end

      def self.all_job_hashes
        job_hashes = []

        Sidekiq.redis do |conn|
          set_members = conn.smembers(jobs_key)
          job_hashes = conn.pipelined do
            set_members.each do |key|
              conn.hgetall(key)
            end
          end
        end

        job_hashes.compact.reject(&:empty?).collect
      end

      # find cron job by name
      def self.find(name)
        # if name is hash try to get name from it
        name = name[:name] || name['name'] if name.is_a?(Hash)

        output = nil
        Sidekiq.redis do |conn|
          output = Job.new conn.hgetall(redis_key(name)) if exists?(name)
        end
        output
      end

      # create new instance of cron job
      def self.create(hash)
        new(hash).save
      end

      # load cron jobs from Hash
      # input structure should look like:
      # {
      #   'name_of_job' => {
      #     'class'       => 'MyClass',
      #     'cron'        => '1 * * * *',
      #     'args'        => '(OPTIONAL) [Array or Hash]',
      #     'description' => '(OPTIONAL) Description of job'
      #   },
      #   'My super iber cool job' => {
      #     'class' => 'SecondClass',
      #     'cron'  => '*/5 * * * *'
      #   }
      # }
      #
      def self.load_from_hash(hash)
        array = hash.inject([]) do |out, (key, job)|
          job['name'] = key
          out << job
        end
        load_from_array(array)
      end

      # like to {#load_from_hash}
      # If exists old jobs in redis but removed from args, destroy old jobs
      def self.load_from_hash!(hash)
        destroy_removed_jobs(hash.keys)
        load_from_hash(hash)
      end

      # load cron jobs from Array
      # input structure should look like:
      # [
      #   {
      #     'name'        => 'name_of_job',
      #     'class'       => 'MyClass',
      #     'cron'        => '1 * * * *',
      #     'args'        => '(OPTIONAL) [Array or Hash]',
      #     'description' => '(OPTIONAL) Description of job'
      #   },
      #   {
      #     'name'  => 'Cool Job for Second Class',
      #     'class' => 'SecondClass',
      #     'cron'  => '*/5 * * * *'
      #   }
      # ]
      #
      def self.load_from_array(array)
        errors = {}
        array.each do |job_data|
          job = new(job_data)
          errors[job.name] = job.errors unless job.save
        end
        errors
      end

      # like to {#load_from_array}
      # If exists old jobs in redis but removed from args, destroy old jobs
      def self.load_from_array!(array)
        job_names = array.map { |job| job['name'] }
        destroy_removed_jobs(job_names)
        load_from_array(array)
      end

      def self.count
        Sidekiq.redis do |conn|
          conn.scard(jobs_key).to_i
        end
      end

      def self.exists?(name)
        Sidekiq.redis do |conn|
          conn.exists(redis_key(name))
        end
      end

      # destroy job by name
      def self.destroy(name)
        # if name is hash try to get name from it
        name = name[:name] || name['name'] if name.is_a?(Hash)

        if job = find(name)
          job.destroy
        else
          false
        end
      end

      # remove all job from cron
      def self.destroy_all!
        all.each(&:destroy)
        logger.info { 'Cron Jobs - deleted all jobs' }
      end

      # remove "removed jobs" between current jobs and new jobs
      def self.destroy_removed_jobs(new_job_names)
        current_job_names = Sidekiq.redis do |conn|
          # use job_key directly, remove "cron_job:" prefix
          conn.smembers(jobs_key).map{|job_key| job_key[9..-1]}
        end

        removed_job_names = current_job_names - new_job_names
        removed_job_names.each { |j| Sidekiq::Cron::Job.destroy(j) }
        removed_job_names
      end

      # Redis key for set of all cron jobs
      def self.jobs_key
        'cron_jobs'
      end

      # Redis key for storing one cron job
      def self.redis_key(name)
        "cron_job:#{name}"
      end

      def self.jid_history_key(name)
        "cron_job:#{name}:jid_history"
      end

      private

      def parsed_cron
        @parsed_cron ||= Fugit.parse_cron(@cron)
      end

      # Try parsing inbound args into an array.
      # args from Redis will be encoded JSON;
      # try to load JSON, then failover
      # to string array.
      def parse_args(args)
        case args
        when String
          begin
            Sidekiq.load_json(args)
          rescue JSON::ParserError
            [*args]   # cast to string array
          end
        when Hash
          [args]      # just put hash into array
        when Array
          args        # do nothing, already array
        else
          [*args]     # cast to string array
        end
      end

      # def not_past_scheduled_time?(current_time)
      #   last_cron_time = parsed_cron.previous_time(current_time).utc
      #     # or could it be?
      #   #last_cron_time = last_time(current_time)
      #   return false if (current_time.to_i - last_cron_time.to_i) > 60
      #   true
      # end

      # Redis key for storing one cron job
      def redis_key
        self.class.redis_key(@name)
      end

      def jid_history_key
        self.class.jid_history_key(@name)
      end

      # Give Hash
      # returns array for using it for redis.hmset
      def hash_to_redis(hash)
        hash.inject([]) { |arr, kv| arr + [kv[0], kv[1]] }
      end
    end
  end
end
