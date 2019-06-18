# frozen_string_literal: true
require "mixlib/cli" unless defined?(Mixlib::CLI)

module Kafkat
  module Command
    class NotFoundError < StandardError; end
    class InvalidCommand < StandardError; end
    class InvalidArgument < StandardError; end

    def self.category
      @category ||= Hash.new { |hash, key| hash[key] = [] }
    end

    def self.deprecated
      @deprecated ||= {}
    end

    def self.all
      @all ||= {}
    end

    def self.get(name)
      klass = all[name.downcase]
      raise NotFoundError unless klass

      klass
    end

    def self.list_commands
      category.keys.sort.each do |cg|
        puts "**** #{cg.upcase} COMMANDS ***"
        category[cg].sort.each do |cmd|
          puts get(cmd).banner
        end
        puts
      end
      puts "Use '--help' with any of the commands to see...\n"
      nil
    end

    def self.load_all(force = false)
      return true if @loaded && !force
      files = Dir[File.expand_path('../command', __FILE__) + '/*.rb']
      files.each do |path|
        # set the stage for loading custom commands at runtime
        raise InvalidCommand unless Kernel.load(path)
      end
      @loaded = true
    end

    class Base
      include Mixlib::CLI

      include Formatting
      include CommandIO
      include Kafkat::Logging

      attr_reader :config

      MERGEABLE_ARGS = [:zk_path, :log_path, :kafka_path]

      option :help,
        short: "-h",
        long: "--help",
        description: "Show this message",
        on: :tail,
        boolean: true,
        show_options: true,
        exit: 0

      option :config_file,
        short: "-c",
        long: "--config CONFIG",
        description: "Configuration file to use."

      option :zk_path,
        short: '-z',
        long: '--zookeeper PATH',
        description: 'The zookeeper path string in the form <host>:<port>,...'

      option :log_path,
        short: '-l',
        long: '--log-path PATH',
        description: 'Where topic data is stored.'

      option :kafka_path,
        short: '-k',
        long: '--kafka-path PATH',
        description: 'Where kafka has been installed.'

      def initialize
        super
        parse_options

        if config[:config_file]
          Config.load_file!(config[:config_file])
        else
          Config.load!
        end
        mergeable_options = config.select do |key, value|
          MERGEABLE_ARGS.include?(key) && !value.nil?
        end
        Config.merge!(mergeable_options)

      rescue JSON::ParserError => e
        puts "Could not parse configuration file: #{e}"
        exit 1
      rescue Mixlib::Config::UnknownConfigOptionError => e
        puts "Invalid configuration file: #{e}"
        exit 1
      end

      def self.register_as(name)
        # I really want to get rid of this, but keeping it in for a little longer
        s = name.split('_')
        Command.category[s.first] << name
        Command.all[name] = self
      end

      def self.deprecated(name)
        Command.deprecated[name] = command_name
        Command.all[name] = self
      end

      def self.description(desc)
        @description = desc
      end

      def invoked_as(name)
        @invoked_name = name
      end

      def command_name
        @command_name ||= self.class.name.split('::').last
          .gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2')
          .gsub(/([a-z\d])([A-Z])/,'\1_\2')
          .downcase
      end

      def self.command_name
        @command_name ||= name.split('::').last
          .gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2')
          .gsub(/([a-z\d])([A-Z])/,'\1_\2')
          .downcase
      end

      def print_help_and_exit(exitcode = 0)
        begin
          parse_options
        rescue OptionParser::InvalidOption => e
          puts "#{e}\n"
        rescue OptionParser::MissingArgument => e
          puts "#{e}\n"
        end
        puts "#{opt_parser}\n"
        exit exitcode
      end

      def run
        raise NotImplementedError
      end

      def arguments
        args = cli_arguments.dup
        # There's a bunch of this logic that can go away after the deprecated
        # commands are removed.
        args.shift(@invoked_name.split('_').size)
        args
      end

      def admin
        @admin ||= begin
          Interface::Admin.new
        end
      end

      def zookeeper
        @zookeeper ||= begin
          Interface::Zookeeper.new
        end
      end

      def kafka_logs
        @kafka_logs ||= begin
          Interface::KafkaLogs.new
        end
      end
    end
  end
end
