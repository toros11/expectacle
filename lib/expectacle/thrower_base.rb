# frozen_string_literal: true

require 'pty'
require 'expect'
require 'yaml'
require 'erb'
require 'logger'

module Expectacle
  # Basic state setup/management
  class ThrowerBase
    # @return [Logger] Logger instance.
    attr_accessor :logger
    # @return [String] Base directory path to find params/hosts/commands file.
    attr_reader :base_dir

    # Constructor
    # @param timeout [Integer] Seconds to timeout. (default: 60sec)
    # @param verbose [Boolean] Flag to enable verbose output.
    #   (default: `true`)
    # @param base_dir [String] Base directory to find files.
    #   (default: `Dir.pwd`)
    # @param logger [IO] IO Object to logging. (default `$stdout`)
    # @return [Expectacle::ThrowerBase]
    def initialize(timeout: 60, verbose: true,
                   base_dir: Dir.pwd, logger: $stdout)
      # default
      @host_param = {}
      # remote connection timeout (sec)
      @timeout = timeout
      # cli mode flag
      @enable_mode = false
      # debug (use debug print to stdout)
      $expect_verbose = verbose
      # base dir
      @base_dir = File.expand_path(base_dir)
      # logger
      @logger = Logger.new(logger)
      setup_default_logger
      # check if exit command was recieved
      @recieved_exit
    end

    # Path to prompt file directory.
    # @return [String]
    def prompts_dir
      File.join @base_dir, 'prompts'
    end

    # Path to host list file directory.
    # @return [String]
    def hosts_dir
      File.join @base_dir, 'hosts'
    end

    # Path to command list file directory.
    # @return [String]
    def commands_dir
      File.join @base_dir, 'commands'
    end

    # Setup common settings of logger instance.
    def setup_logger
      @logger.level = Logger::INFO
      @logger.formatter = proc do |severity, datetime, progname, msg|
        "#{datetime} #{progname} [#{severity}] #{msg}\n"
      end
    end

    private

    def setup_default_logger
      @logger.progname = 'Expectacle'
      @logger.datetime_format = '%Y-%m-%d %H:%M:%D %Z'
      setup_logger
    end

    def ready_to_open_host_session
      # prompt regexp of device
      load_prompt_file
      spawn_cmd = make_spawn_command
      if @prompt && spawn_cmd
        yield spawn_cmd
      else
        @logger.error 'Invalid parameter in param file(S)'
      end
    end


    def do_on_interactive_process
      until @reader.eof?
        @reader.expect(expect_regexp, @timeout) do |match|
          return if @recieved_exit and not match.include?(@prompt[:yn][:match])
          yield match
        end
      end
    rescue Errno::EIO => error
      # on linux, PTY raises Errno::EIO when spawned process closed.
      @logger.debug "PTY raises Errno::EIO, #{error.message}"
    end

    def open_interactive_process(spawn_cmd)
      @logger.info "Begin spawn: #{spawn_cmd}"
      PTY.spawn(spawn_cmd) do |reader, writer, _pid|
        @recieved_exit = false
        @enable_mode = false
        @reader = reader
        @writer = writer
        @writer.sync = true
        yield
      end
      @logger.info "End spawn: #{@host_param[:hostname]}"
    end

    def ssh_command
      ['ssh',
       '-o StrictHostKeyChecking=no',
       '-o KexAlgorithms=+diffie-hellman-group1-sha1', # for old cisco device
       "-l #{embed_user_name}",
       @host_param[:ipaddr]].join(' ')
    end

    def make_spawn_command
      case @host_param[:protocol]
      when /^telnet$/i
        ['telnet', @host_param[:ipaddr]].join(' ')
      when /^ssh$/i
        ssh_command
      else
        @logger.error "Unknown protocol #{@host_param[:protocol]}"
        nil
      end
    end

    def load_yaml_file(file_type, file_name)
      YAML.load_file file_name
    rescue StandardError => error
      @logger.error "Cannot load #{file_type}: #{file_name}"
      raise error
    end

    def load_prompt_file
      prompt_file = "#{prompts_dir}/#{@host_param[:type]}_prompt.yml"
      @prompt = load_yaml_file('prompt file', prompt_file)
    end

    def expect_regexp
      /
        ( #{@prompt[:password]} | #{@prompt[:enable_password]}
        | #{@prompt[:username]}
        | #{@prompt[:command1]} | #{@prompt[:command2]}
        | #{@prompt[:sub1]} | #{@prompt[:sub2]}
        | #{@prompt[:yn][:match]} | #{@consol_server_return}
        )\s*$
      /x
    end

    def write_and_logging(message, command, secret = false)
      logging_message = secret ? message : message + command
      @logger.info logging_message
      @writer.puts command
      @recieved_exit = command == 'exit'
    end

    def check_embed_envvar(command)
      return unless command =~ /<%=\s*ENV\[[\'\"]?(.+)[\'\"]\]?\s*%>/
      envvar_name = Regexp.last_match(1)
      if !ENV.key?(envvar_name)
        @logger.error "Variable name: #{envvar_name} is not found in ENV"
      elsif ENV[envvar_name] =~ /^\s*$/
        @logger.warn "Env var: #{envvar_name} exists, but null string"
      end
    end

    def embed_password
      @host_param[:enable] = '_NOT_DEFINED_' unless @host_param.key?(:enable)
      base_str = @enable_mode ? @host_param[:enable] : @host_param[:password]
      check_embed_envvar(base_str)
      passwd_erb = ERB.new(base_str)
      passwd_erb.result(binding)
    end

    def embed_command(command)
      command_erb = ERB.new(command)
      command_erb.result(binding)
    end

    def embed_user_name
      check_embed_envvar(@host_param[:username])
      uname_erb = ERB.new(@host_param[:username])
      uname_erb.result(binding)
    end
  end
end
