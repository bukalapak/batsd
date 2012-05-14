module Batsd
  # 
  # This is a thin wrapper around the redis client to
  # handle multistep procedures that could be executed using
  # Redis scripting
  #
  class Redis

    # Opens a new connection to the redis instance specified 
    # in the configuration or localhost:6379
    #
    def initialize(options)
      @redis = ::Redis.new(options[:redis] || {host: "127.0.0.1", port: 6379} )
      @redis.ping
      @retentions = options[:retentions].keys
    end
    
    # Expose the redis client directly
    def client
      @redis
    end

    # Store a counter measurement for each of the specified retentions
    #
    # * For shortest retention (where timestep == flush interval), add the
    #   value and timestamp to the appropriate zset
    #
    # * For longer retention intervals, increment the appropriate counter
    #   by the value specified.
    #
    # TODO: This can be done in a single network request by rewriting
    # it as a redis script in Lua
    #
    def store_and_update_all_counters(timestamp, key, value)
      @retentions.each_with_index do |t, index|
        if index.zero?
          @redis.zadd key, timestamp, "#{timestamp}<X>#{value}"
        else index.zero?
          @redis.incrby "#{key}:#{t}", value
          @redis.expire "#{key}:#{t}", t.to_i * 2
        end
      end
    end

    # Store a timer to a zset
    #
    def store_timer(timestamp, key, value)
      @redis.zadd key, timestamp, "#{timestamp}<X>#{value}"
    end

    # Store unaggregated, raw timer values in bucketed keys
    # so that they can actually be aggregated "raw"
    #
    # The set of tiemrs are stored as a single string key delimited by 
    # \x0. In benchmarks, this is more efficient in memory by 2-3x, and
    # less efficient in time by ~10%
    #
    # TODO: can this be done more efficiently with redis scripting?
    def store_raw_timers_for_aggregations(key, values)
      @retentions.each_with_index do |t, index|
        next if index.zero?
        @redis.append "#{key}:#{t}", "<X>#{values.join("<X>")}"
        @redis.expire "#{key}:#{t}", t.to_i * 2
      end
    end
    
    # Returns the value of a key and then deletes it.
    #
    # TODO: This can be done in a single network request by rewriting
    # it as a redis script in Lua
    #
    def get_and_clear_key(key)
      val = @redis.get key
      @redis.del key
      val
    end

    # Truncate a zset since a treshold time
    #
    def truncate_zset(key, since)
      @redis.zremrangebyscore key, 0, since
    end

    # Return properly formatted values from the zset
    def values_from_zset(metric, begin_ts, end_ts)
      values = @redis.zrangebyscore(metric, begin_ts, end_ts)
      values.collect{|val| ts, val = val.split("<X>"); {timestamp: ts, value: val } }
    end

    # Convenience accessor to members of datapoints set
    #
    def datapoints(with_gauges=true)
      datapoints = @redis.smembers "datapoints"
      unless with_gauges
        datapoints.reject!{|d| (d.match(/^gauge/) rescue false) }
      end
      datapoints
    end

    # Stores a reference to the datapoint in 
    # the 'datapoints' set
    #
    def add_datapoint(key)
      @redis.sadd "datapoints", key
    end

  end
end
