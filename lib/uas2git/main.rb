require 'highline/import'
require 'optparse'
require 'rugged'
require 'progress'

module Uas2Git
  class Main
    def initialize(args)
      @options = parse(args)

      show_help_message('Missing PROJECT_NAME parameter') if args.empty?
      show_help_message('Too many arguments') if args.size > 1

      @project_name = args.first

      begin
        show_help_message('The repository must be empty') unless Rugged::Repository.new('.').empty?
      rescue
      end

    end

    def run!
      password = ask('Enter password for ' + @options[:username] + '@' + @options[:host] + ': ') { |q| q.echo = false }

      ActiveRecord::Base.establish_connection(
          :adapter  => 'postgresql',
          :host     => @options[:host],
          :port     => '10733',
          :username => @options[:username],
          :password => password,
          :database => @project_name
      )

      # Initialize a git repository
      repo = Progress.start('Initializing a git repository', 1) do
        Progress.step do
          Rugged::Repository.init_at('.')
        end
      end

      Migrator.new(repo).migrate!

      # Checking out the working copy
      Progress.start('Checking out the work tree', 1) do
        Progress.step do
          repo.reset('HEAD', :hard)
        end
      end
    end

    def parse(args)
      # Set up reasonable defaults for options.
      options = {}
      options[:host] = 'localhost'
      options[:username] = 'admin'

      @opts = OptionParser.new do |opts|
        opts.banner = 'Usage: uas2git PROJECT_NAME [options]'

        opts.separator ''
        opts.separator 'Specific options:'

        opts.on('-h HOSTNAME', 'Unity Asset Server host (default: "localhost")') do |host|
          options[:host] = host
        end

        opts.on('-U NAME', 'Unity Asset Server user name (default: "admin")') do |username|
          options[:username] = username
        end

        opts.separator ''

        opts.on_tail('--help', 'Show this message') do
          puts opts
          exit
        end
      end

      @opts.parse! args
      options
    end

    def show_help_message(msg)
      puts "Error starting script: #{msg}\n\n"
      puts @opts.help
      exit
    end
  end
end
