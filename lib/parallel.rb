require 'rbconfig'
require 'parallel/version'
require 'parallel/processor_count'

module Parallel
  extend Parallel::ProcessorCount

  class DeadWorker < StandardError
  end

  class Break < StandardError
  end

  class Kill < StandardError
  end

  class RemoteWorkerTimeout < StandardError
  end

  Stop = Object.new

  class ExceptionWrapper
    attr_reader :exception
    def initialize(exception)
      dumpable = Marshal.dump(exception) rescue nil
      unless dumpable
        exception = RuntimeError.new("Undumpable Exception -- #{exception.inspect}")
      end

      @exception = exception
    end
  end

  class Worker
    attr_reader :pid, :read, :write
    attr_accessor :thread
    def initialize(read, write, pid)
      @read, @write, @pid = read, write, pid
    end

    def close_pipes
      read.close
      write.close
    end

    def wait
      Process.wait(pid)
    rescue Interrupt
      # process died
    end

    def work(data)
      begin
        Marshal.dump(data, write)
      rescue Errno::EPIPE
        raise DeadWorker
      end

      result = begin
        Marshal.load(read)
      rescue EOFError
        raise DeadWorker
      end
      raise result.exception if ExceptionWrapper === result
      result
    end
  end

  class RemoteWorker < Worker
    def initialize(socket)
      super(socket, socket, nil)
    end

    def close_pipes
      Marshal.dump(nil, write)
      read.close
    end

    def wait
    end

  end

  class JobFactory
    TICK_MS = 100  # for throttling
    TICK_MULTIPLIER = (1000 / TICK_MS)

    def initialize(source, mutex, max_rate=nil)
      @lambda = (source.respond_to?(:call) && source) || queue_wrapper(source)
      @source = source.to_a unless @lambda # turn Range and other Enumerable-s into an Array
      @mutex = mutex
      @index = -1
      @stopped = false
      @job_per_tick = (max_rate * (TICK_MS / 1000.0)).ceil if max_rate
      @thorottle_mutex = Mutex.new
    end

    def get_tick
     (Time.now.to_f * TICK_MULTIPLIER).floor
    end

    def under_limit?
      @thorottle_mutex.synchronize do
        tick = get_tick
        if tick != @current_tick
          @current_tick = tick
          @current_calls = 0
        end
        if @current_calls < @job_per_tick
          @current_calls += 1
          return true
        else
          return false
        end
      end
    end

    def throttle
      loop do
        return if @job_per_tick.nil? || @index >= size-1 || under_limit?
        sleep rand(TICK_MS / 1000.0)
      end
    end

    def next
      throttle

      if producer?
        # - index and item stay in sync
        # - do not call lambda after it has returned Stop
        item, index = @mutex.synchronize do
          return if @stopped
          item = @lambda.call
          @stopped = (item == Parallel::Stop)
          return if @stopped
          [item, @index += 1]
        end
      else
        index = @mutex.synchronize { @index += 1 }
        return if index >= size
        item = @source[index]
      end
      [item, index]
    end

    def size
      if producer?
        Float::INFINITY
      else
        @source.size
      end
    end

    # generate item that is sent to workers
    # just index is faster + less likely to blow up with unserializable errors
    def pack(item, index)
      producer? ? [item, index] : index
    end

    # unpack item that is sent to workers
    def unpack(data)
      producer? ? data : [@source[data], data]
    end

    private

    def producer?
      @lambda
    end

    def queue_wrapper(array)
      array.respond_to?(:num_waiting) && array.respond_to?(:pop) && lambda { array.pop(false) }
    end
  end

  class UserInterruptHandler
    INTERRUPT_SIGNAL = :SIGINT

    class << self
      # kill all these pids or threads if user presses Ctrl+c
      def kill_on_ctrl_c(pids, options)
        @to_be_killed ||= []
        old_interrupt = nil
        signal = options.fetch(:interrupt_signal, INTERRUPT_SIGNAL)

        if @to_be_killed.empty?
          old_interrupt = trap_interrupt(signal) do
            $stderr.puts 'Parallel execution interrupted, exiting ...'
            @to_be_killed.flatten.each { |pid| kill(pid) }
          end
        end

        @to_be_killed << pids

        yield
      ensure
        @to_be_killed.pop # do not kill pids that could be used for new processes
        restore_interrupt(old_interrupt, signal) if @to_be_killed.empty?
      end

      def kill(thing)
        Process.kill(:KILL, thing)
      rescue Errno::ESRCH
        # some linux systems already automatically killed the children at this point
        # so we just ignore them not being there
      end

      private

      def trap_interrupt(signal)
        old = Signal.trap signal, 'IGNORE'

        Signal.trap signal do
          yield
          if old == "DEFAULT"
            raise Interrupt
          else
            old.call
          end
        end

        old
      end

      def restore_interrupt(old, signal)
        Signal.trap signal, old
      end
    end
  end

  class << self
    def in_threads(options={:count => 2})
      options[:begin].call if options[:begin]
      count, _ = extract_count_from_options(options)
      result = Array.new(count).each_with_index.map do |_, i|
        Thread.new { yield(i) }
      end.map!(&:value)
      options[:end].call if options[:end]
      result
    end

    def in_processes(options = {}, &block)
      count, options = extract_count_from_options(options)
      count ||= processor_count
      map(0...count, options.merge(:in_processes => count), &block)
    end

    def each(array, options={}, &block)
      map(array, options.merge(:preserve_results => false), &block)
      array
    end

    def each_with_index(array, options={}, &block)
      each(array, options.merge(:with_index => true), &block)
    end

    def map(source, options = {}, &block)
      options[:mutex] = Mutex.new

      if RUBY_PLATFORM =~ /java/ and not options[:in_processes]
        method = :in_threads
        size = options[method] || processor_count
      elsif options[:in_threads]
        method = :in_threads
        size = options[method]
      else
        method = :in_processes
        if Process.respond_to?(:fork)
          size = options[method] || processor_count
        else
          warn "Process.fork is not supported by this Ruby"
          size = 0
        end
      end

      job_factory = JobFactory.new(source, options[:mutex], options[:max_rate])
      size = [job_factory.size, size].min

      options[:return_results] = (options[:preserve_results] != false || !!options[:finish])

      if size == 0
        work_direct(job_factory, options, &block)
      elsif method == :in_threads
        work_in_threads(job_factory, options.merge(:count => size), &block)
      else
        work_in_processes(job_factory, options.merge(:count => size), &block)
      end
    end

    def map_with_index(array, options={}, &block)
      map(array, options.merge(:with_index => true), &block)
    end

    private

    def add_progress_bar!(job_factory, options)
      if progress_options = options[:progress]
        raise "Progressbar can only be used with array like items" if job_factory.size == Float::INFINITY
        require 'ruby-progressbar'

        if progress_options.respond_to? :to_str
          progress_options = { title: progress_options.to_str }
        end

        progress_options = {
          total: job_factory.size,
          format: '%t |%E | %B | %a'
        }.merge(progress_options)

        progress = ProgressBar.create(progress_options)
        old_finish = options[:finish]
        options[:finish] = lambda do |item, i, result|
          old_finish.call(item, i, result) if old_finish
          progress.increment
        end
      end
    end

    def work_direct(job_factory, options, &block)
      results = []
      add_progress_bar!(job_factory, options)
      while set = job_factory.next
        item, index = set
        results << with_instrumentation(item, index, options) do
          call_with_index(item, index, options, &block)
        end
      end
      results
    end

    def work_in_threads(job_factory, options, &block)
      raise "interrupt_signal is no longer supported for threads" if options[:interrupt_signal]
      results = []
      results_mutex = Mutex.new # arrays are not thread-safe on jRuby
      exception = nil

      add_progress_bar!(job_factory, options)
      in_threads(options) do
        # as long as there are more jobs, work on one of them
        while !exception && set = job_factory.next
          begin
            item, index = set
            result = with_instrumentation item, index, options do
              call_with_index(item, index, options, &block)
            end
            results_mutex.synchronize { results[index] = result }
          rescue StandardError => e
            exception = e
          end
        end
      end

      handle_exception(exception, results)
    end

    def work_in_processes(job_factory, options, &blk)
      if ENV['DPARALLEL_MASTER']
        # run as a slave mode, each workers connect to remote master
        print "[##$$] run as a slave mode...\n"
        create_slave_workers(job_factory, options, &blk)
        while (Process.wait rescue nil); end
        exit 0
      end

      if options[:distribute]
        # run as a master of distributed slaves
        puts "run as master, launching remote workers ..."
        workers = create_remote_workers(job_factory, options, &blk)
        options[:count] = workers.size
      else
        workers = create_workers(job_factory, options, &blk)
      end
      results = []
      results_mutex = Mutex.new # arrays are not thread-safe
      exception = nil

      add_progress_bar!(job_factory, options)
      UserInterruptHandler.kill_on_ctrl_c(workers.map(&:pid), options) do
        in_threads(options) do |i|
          worker = workers[i]
          worker.thread = Thread.current

          begin
            loop do
              break if exception
              item, index = job_factory.next
              break unless index

              begin
                result = with_instrumentation item, index, options do
                  worker.work(job_factory.pack(item, index))
                end
                results_mutex.synchronize { results[index] = result } # arrays are not threads safe on jRuby
              rescue StandardError => e
                exception = e
                if Parallel::Kill === exception
                  (workers - [worker]).each do |w|
                    w.thread.kill
                    UserInterruptHandler.kill(w.pid)
                  end
                end
              end
            end
          ensure
            unless options[:sleep_after]
              worker.close_pipes
              worker.wait # if it goes zombie, rather wait here to be able to debug
            end
          end
        end
      end

      handle_exception(exception, results)
    end

    def create_workers(job_factory, options, &block)
      workers = []
      Array.new(options[:count]).each do
        workers << worker(job_factory, options.merge(:started_workers => workers), &block)
      end
      workers
    end

    def worker(job_factory, options, &block)
      child_read, parent_write = IO.pipe
      parent_read, child_write = IO.pipe

      pid = Process.fork do
        begin
          options.delete(:started_workers).each(&:close_pipes)

          parent_write.close
          parent_read.close

          process_incoming_jobs(child_read, child_write, job_factory, options, &block)
        rescue Interrupt
        ensure
          child_read.close
          child_write.close
        end
      end

      child_read.close
      child_write.close

      Worker.new(parent_read, parent_write, pid)
    end

    def create_slave_workers(job_factory, options, &block)
      master_host, master_port = ENV['DPARALLEL_MASTER'].split(/\|/, 2)
      Array.new(options[:count]).each do
        slave_worker(job_factory, options, master_host, master_port, &block)
      end
    end

    def slave_worker(job_factory, options, master_host, master_port, &block)
      Process.fork do
        begin
          socket = TCPSocket.new(master_host, master_port)
          process_incoming_jobs(socket, socket, job_factory, options, &block)
        rescue => e
          STDERR.print "worker ##$$ exception: #{e.class}\n"
          exit 1
        end
      end
    end

    def create_remote_workers(job_factory, options, &block)
      workers = []

      unless (local_address = options[:local_address])
        local_address = Socket.getifaddrs.find{ |x|
          x.addr.ipv4? and not x.addr.ipv4_loopback?
        }.addr.ip_address
      end
      server = TCPServer.new(local_address, 0)
      my_port = server.local_address.ip_port
      my_ip = server.local_address.ip_address

      unless (command = options[:distribute_command])
        command = [ $0, *ARGV ].map{ |e| "'#{e}'" }.join(' ')
      end

      pids = options[:distribute].map{ |node|
        spawn 'ssh', '-q', node,
              "export DPARALLEL_MASTER='#{my_ip}|#{my_port}' DPARALLEL_MY_NODE='#{node}'; #{command}"
        sleep 0.1  # to avoid ssh-rush
      }

      timeout_sec = options[:distribute_timeout] || 60
      total_workers = options[:count] * options[:distribute].size
      begin
        timeout(timeout_sec) do
          while workers.length < total_workers
            client = server.accept
            workers << remote_worker(job_factory, options, client, &block)
          end
        end
      rescue Timeout::Error
        pids.each do |pid| Process.kill(:QUIT, pid) end
        raise RemoteWorkerTimeout
      end

      workers
    end

    def remote_worker(job_factory, options, socket, &block)
      RemoteWorker.new(socket)
    end

    def process_incoming_jobs(read, write, job_factory, options, &block)
      until read.eof?
        data = Marshal.load(read)
        break if data.nil?
        item, index = job_factory.unpack(data)
        result = begin
          call_with_index(item, index, options, &block)
        rescue StandardError => e
          ExceptionWrapper.new(e)
        end
        Marshal.dump(result, write)
      end
    end

    def handle_exception(exception, results)
      return nil if [Parallel::Break, Parallel::Kill].include? exception.class
      raise exception if exception
      results
    end

    # options is either a Integer or a Hash with :count
    def extract_count_from_options(options)
      if options.is_a?(Hash)
        count = options[:count]
      else
        count = options
        options = {}
      end
      [count, options]
    end

    def call_with_index(item, index, options, &block)
      args = [item]
      args << index if options[:with_index]
      if options[:return_results]
        block.call(*args)
      else
        block.call(*args)
        nil # avoid GC overhead of passing large results around
      end
    end

    def with_instrumentation(item, index, options)
      on_start = options[:start]
      on_finish = options[:finish]
      options[:mutex].synchronize { on_start.call(item, index) } if on_start
      result = yield
      result unless options[:preserve_results] == false
    ensure
      options[:mutex].synchronize { on_finish.call(item, index, result) } if on_finish
    end
  end
end
