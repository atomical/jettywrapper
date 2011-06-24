# Jettywrapper is a Singleton class, so you can only create one jetty instance at a time.
require 'rubygems'
require 'logger'
require 'loggable'
require 'singleton'
require 'ftools'
require 'socket'
require 'timeout'
require 'ruby-debug'

class Jettywrapper
  
  include Singleton
  include Loggable
  
  attr_accessor :pid          # If Jettywrapper is running, what pid is it running as? 
  attr_accessor :port         # What port should jetty start on? Default is 8888
  attr_accessor :jetty_home   # Where is jetty located? 
  attr_accessor :startup_wait # After jetty starts, how long to wait until starting the tests? 
  attr_accessor :quiet        # Keep quiet about jetty output?
  attr_accessor :solr_home    # Where is solr located? Default is jetty_home/solr
  attr_accessor :fedora_home  # Where is fedora located? Default is jetty_home/fedora
  attr_accessor :logger       # Where should logs be written?
  attr_accessor :base_path    # The root of the application. Used for determining where log files and PID files should go.
  
  # configure the singleton with some defaults
  def initialize(params = {})
    # @pid = nil
    if defined?(Rails.root)
      @base_path = Rails.root
    else
      @base_path = "."
    end
    @logger = Logger.new("#{@base_path}/tmp/jettywrapper-debug.log")
    @logger.debug 'Initializing jettywrapper'
  end
  
  # Methods inside of the class << self block can be called directly on Jettywrapper, as class methods. 
  # Methods outside the class << self block must be called on Jettywrapper.instance, as instance methods.
  class << self
    
    # Set the jetty parameters. It accepts a Hash of symbols. 
    # @param [Hash<Symbol>] params
    # @param [Symbol] :jetty_home Required. Where is jetty located? 
    # @param [Symbol] :jetty_port What port should jetty start on? Default is 8888
    # @param [Symbol] :startup_wait After jetty starts, how long to wait before running tests? If you don't let jetty start all the way before running the tests, they'll fail because they can't reach jetty.
    # @param [Symbol] :solr_home Where is solr? Default is jetty_home/solr
    # @param [Symbol] :fedora_home Where is fedora? Default is jetty_home/fedora/default
    # @param [Symbol] :quiet Keep quiet about jetty output? Default is true. 
    def configure(params = {})
      hydra_server = self.instance
      hydra_server.quiet = params[:quiet].nil? ? true : params[:quiet]
      if defined?(Rails.root)
       base_path = Rails.root
      else
       raise "You must set either RAILS_ROOT or :jetty_home so I know where jetty is" unless params[:jetty_home]
      end
      hydra_server.jetty_home = params[:jetty_home] || File.expand_path(File.join(base_path, 'jetty'))
      hydra_server.solr_home = params[:solr_home]  || File.join( hydra_server.jetty_home, "solr")
      hydra_server.fedora_home = params[:fedora_home] || File.join( hydra_server.jetty_home, "fedora","default")
      hydra_server.port = params[:jetty_port] || 8888
      hydra_server.startup_wait = params[:startup_wait] || 5
      return hydra_server
    end
     
    # Wrap the tests. Startup jetty, yield to the test task, capture any errors, shutdown
    # jetty, and return the error. 
    # @example Using this method in a rake task
    #   require 'jettywrapper'
    #   desc "Spin up jetty and run tests against it"
    #   task :newtest do
    #     jetty_params = { 
    #       :jetty_home => "/path/to/jetty", 
    #       :quiet => false, 
    #       :jetty_port => 8983, 
    #       :startup_wait => 30
    #     }
    #     error = Jettywrapper.wrap(jetty_params) do   
    #       Rake::Task["rake:spec"].invoke 
    #       Rake::Task["rake:cucumber"].invoke 
    #     end 
    #     raise "test failures: #{error}" if error
    #   end
    def wrap(params)
      error = false
      jetty_server = self.instance
      jetty_server.quiet = params[:quiet] || true
      jetty_server.jetty_home = params[:jetty_home]
      jetty_server.solr_home = params[:solr_home]
      jetty_server.port = params[:jetty_port] || 8888
      jetty_server.startup_wait = params[:startup_wait] || 5
      jetty_server.fedora_home = params[:fedora_home] || File.join( jetty_server.jetty_home, "fedora","default")

      begin
        # puts "starting jetty on #{RUBY_PLATFORM}"
        jetty_server.start
        sleep jetty_server.startup_wait
        yield
      rescue
        error = $!
        puts "*** Error starting hydra-jetty: #{error}"
      ensure
        # puts "stopping jetty server"
        jetty_server.stop
      end

      return error
    end
    
    # Convenience method for configuring and starting jetty with one command
    # @param [Hash] params: The configuration to use for starting jetty
    # @example 
    #    Jettywrapper.start_with_params(:jetty_home => '/path/to/jetty', :jetty_port => '8983')
    def start(params)
       Jettywrapper.configure(params)
       Jettywrapper.instance.start
       return Jettywrapper.instance
    end
    
    # Convenience method for configuring and starting jetty with one command. Note
    # that for stopping, only the :jetty_home value is required (including other values won't 
    # hurt anything, though). 
    # @param [Hash] params: The jetty_home to use for stopping jetty
    # @return [Jettywrapper.instance]
    # @example 
    #    Jettywrapper.stop_with_params(:jetty_home => '/path/to/jetty')
    def stop(params)
       Jettywrapper.configure(params)
       Jettywrapper.instance.stop
       return Jettywrapper.instance
    end
    
    # Determine whether the jetty at the given jetty_home is running
    # @param [Hash] params: :jetty_home is required. Which jetty do you want to check the status of?
    # @return [Boolean]
    # @example
    #    Jettywrapper.is_running?(:jetty_home => '/path/to/jetty')
    def is_jetty_running?(params)      
      Jettywrapper.configure(params)
      pid = Jettywrapper.instance.pid
      return false unless pid
      true
    end
    
    # Return the pid of the specified jetty, or return nil if it isn't running
    # @param [Hash] params: :jetty_home is required.
    # @return [Fixnum] or [nil]
    # @example
    #    Jettywrapper.pid(:jetty_home => '/path/to/jetty')
    def pid(params)
      Jettywrapper.configure(params)
      pid = Jettywrapper.instance.pid
      return nil unless pid
      pid
    end
    
    # Check to see if the port is open so we can raise an error if we have a conflict
    # @param [Fixnum] port the port to check
    # @return [Boolean]
    # @example
    #  Jettywrapper.is_port_open?(8983)
    def is_port_in_use?(port)
      begin
        Timeout::timeout(1) do
          begin
            s = TCPSocket.new('127.0.0.1', port)
            s.close
            return true
          rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
            return false
          rescue
            return false
          end
        end
      rescue Timeout::Error
      end

      return false
    end
    
    # Check to see if the pid is actually running. This only works on unix. 
    def is_running?(pid)
      begin
        return Process.getpgid(pid) != -1
      rescue Errno::ESRCH
        return false
      end
    end
    
    end #end of class << self
    
        
   # What command is being run to invoke jetty? 
   def jetty_command
     "java -Djetty.port=#{@port} -Dsolr.solr.home=#{@solr_home} -Dfedora.home=#{@fedora_home} -jar start.jar"
   end
   
   # Start the jetty server. Check the pid file to see if it is running already, 
   # and stop it if so. After you start jetty, write the PID to a file. 
   # This is the instance start method. It must be called on Jettywrapper.instance
   # You're probably better off using Jettywrapper.start(:jetty_home => "/path/to/jetty")
   # @example
   #    Jettywrapper.configure(params)
   #    Jettywrapper.instance.start
   #    return Jettywrapper.instance
   def start
     @logger.debug "Starting jetty with these values: "
     @logger.debug "jetty_home: #{@jetty_home}"
     @logger.debug "solr_home: #{@solr_home}"
     @logger.debug "fedora_home: #{@fedora_home}"
     @logger.debug "jetty_command: #{jetty_command}"
     
     # Check to see if we can start.
     # 1. If there is a pid, check to see if it is really running
     # 2. Check to see if anything is blocking the port we want to use     
     if pid
       if Jettywrapper.is_running?(pid)
         raise("Server is already running with PID #{pid}")
       else
         @logger.warn "Removing stale PID file at #{pid_path}"
         File.delete(pid_path)
       end
       if Jettywrapper.is_port_in_use?(@jetty_port)
         raise("Port #{self.jetty_port} is already in use.")
       end
     end
     Dir.chdir(@jetty_home) do
       self.send "#{platform}_process".to_sym
     end
     File.makedirs(pid_dir) unless File.directory?(pid_dir)
     begin
       f = File.new(pid_path,  "w")
     rescue Errno::ENOENT, Errno::EACCES
       f = File.new(File.join(@base_path,'tmp',pid_file),"w")
     end
     f.puts "#{@pid}"
     f.close
     @logger.debug "Wrote pid file to #{pid_path} with value #{@pid}"
   end
 
   # Instance stop method. Must be called on Jettywrapper.instance
   # You're probably better off using Jettywrapper.stop(:jetty_home => "/path/to/jetty")
   # @example
   #    Jettywrapper.configure(params)
   #    Jettywrapper.instance.stop
   #    return Jettywrapper.instance
   def stop    
     if pid
       begin
         self.send "#{platform}_stop".to_sym
       rescue Errno::ESRCH
         @logger.error "I tried to kill the process #{pid} but it seems it wasn't running."
       end
       begin
         File.delete(pid_path)
       rescue
       end
     end
   end
 
    # Spawn a process on windows
    def win_process
      @pid = Process.create(
         :app_name         => jetty_command,
         :creation_flags   => Process::DETACHED_PROCESS,
         :process_inherit  => false,
         :thread_inherit   => true,
         :cwd              => "#{@jetty_home}"
      ).process_id
    end

    # Determine whether we're running on windows or unix. We need to know this so 
    # we know how to start and stop processes. 
    def platform
      case RUBY_PLATFORM
        when /mswin32/
           return 'win'
        else
           return 'nix'
      end
    end

   def nix_process
     @pid = fork do
       # STDERR.close if @quiet
       exec jetty_command
     end
   end

   # stop jetty the windows way
   def win_stop
     Process.kill(1, pid)
   end

   # stop jetty the *nix way
   def nix_stop
     return nil if pid == nil
     begin
       pid_keeper = pid
       @logger.debug "Killing process #{pid}"
       Process.kill('TERM',pid)
       sleep 2
       FileUtils.rm(pid_path)
       if Jettywrapper.is_running?(pid_keeper)
         raise "Couldn't kill process #{pid_keeper}"
       end
     rescue Errno::ESRCH
       @logger.debug "I tried to kill #{pid_keeper} but it appears it wasn't running."
     end
   end

   # The fully qualified path to the pid_file
   def pid_path
     File.join(pid_dir, pid_file)
   end

   # The file where the process ID will be written
   def pid_file
     @pid_file || jetty_home_to_pid_file(@jetty_home)
   end
   
    # Take the @jetty_home value and transform it into a legal filename
    # @return [String] the name of the pid_file
    # @example
    #    /usr/local/jetty1 => _usr_local_jetty1.pid
    def jetty_home_to_pid_file(jetty_home)
      begin
        jetty_home.gsub(/\//,'_') << ".pid"
      rescue
        raise "Couldn't make a pid file for jetty_home value #{jetty_home}"
        raise $!
      end
    end

   # The directory where the pid_file will be written
   def pid_dir
     File.expand_path(@pid_dir || File.join(@base_path,'tmp','pids'))
   end
   
   # Check to see if there is a pid file already
   # @return true if the file exists, otherwise false
   def pid_file?
      return true if File.exist?(pid_path)
      false
   end

   # the process id of the currently running jetty instance
   def pid
      @pid || File.open( pid_path ) { |f| return f.gets.to_i } if File.exist?(pid_path)
   end
   
end