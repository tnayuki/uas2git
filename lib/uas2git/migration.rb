require 'highline/import'
require 'optparse'
require 'rugged'
require 'progress'

module Uas2Git
  class Migration
    def initialize(args)
      @options = parse(args)

      show_help_message('Missing PROJECT_NAME parameter') if args.empty?
      show_help_message('Too many arguments') if args.size > 1

      @project_name = args.first

      begin
        show_help_message('The repository must be empty') unless Rugged::Repository.new('.').empty?
      rescue
      end

      if @options[:password].nil? then
        @options[:password] = ask('Enter password for ' + @options[:username] + '@' + @options[:host] + ': ') { |q| q.echo = false }
      end
    end

    def run!
      ActiveRecord::Base.establish_connection(
          :adapter  => 'postgresql',
          :host     => @options[:host],
          :port     => '10733',
          :username => @options[:username],
          :password => @options[:password],
          :database => @project_name
      )

      # Initialize a git repository
      repo = Progress.start('Initializing a git repository', 1) do
        Progress.step do
          Rugged::Repository.init_at('.')
        end
      end

      # Import files
      oids = {}
      meta_oids = {}

      asset_versions = Uas2Git::Uas::Model::AssetVersion.joins(:type).where('assettype.description <> \'dir\'')
      Progress.start('Importing ' + asset_versions.count.to_s + ' files', asset_versions.count) do
        asset_versions.find_each do |asset_version|
          Progress.step do
            asset_version.contents.each do |contents|
              oid = LOReader.new(asset_version.class.connection.raw_connection).open(contents.stream) do |lo|
                Rugged::Blob.from_chunks(repo, lo)
              end

              if contents.tag == 'asset' then
                oids[asset_version.asset.serial] = {} if oids[asset_version.asset.serial].nil?
                oids[asset_version.asset.serial][asset_version.revision] = oid
              elsif contents.tag == 'asset.meta' then
                meta_oids[asset_version.asset.serial] = {} if meta_oids[asset_version.asset.serial].nil?
                meta_oids[asset_version.asset.serial][asset_version.revision] = oid
              end
            end
          end
        end
      end

      # Precalculating directory paths from changesets
      dirs = {}
      prev_changeset = nil

      Progress.start('Precalculating directory paths', Uas2Git::Uas::Model::Changeset.count) do
        Uas2Git::Uas::Model::Changeset.find_each do |changeset|
          Progress.step do
            dirs[changeset.serial] = prev_changeset ? dirs[prev_changeset.serial].clone : {}

            changeset.asset_versions.joins(:type).where('assettype.description = \'dir\'').find_each do |asset_version|
              if asset_version.parent then
                dirs[changeset.serial][asset_version.asset.serial] = dirs[changeset.serial][asset_version.parent.serial] + '/' + asset_version.name
              else
                dirs[changeset.serial][asset_version.asset.serial] = asset_version.name
              end
            end

            prev_changeset = changeset
          end
        end
      end

      # Importing changesets
      Progress.start('Importing ' + Uas2Git::Uas::Model::Changeset.count.to_s + ' changesets', Uas2Git::Uas::Model::Changeset.count) do
        Uas2Git::Uas::Model::Changeset.find_each do |changeset|
          Progress.step do
            index = Rugged::Index.new

            Uas2Git::Uas::Model::AssetVersion.joins(:type).where('assettype.description <> \'dir\'').where(
                'created_in <= :c AND assetversion.serial IN (SELECT assetversion FROM changesetcontents WHERE changesetcontents.changeset <= :c) AND revision = (SELECT MAX(revision) FROM assetversion AV2 WHERE AV2.asset = assetversion.asset AND AV2.created_in <= :c)',
                { :c => changeset.serial }
            ).find_each do |asset_version|
              if asset_version.parent then
                path = dirs[changeset.serial][asset_version.parent.serial] + '/' + asset_version.name
              else
                path = 'ProjectSettings/' + asset_version.name
              end

              if !path.start_with?('Trash/') then
                index.add(:path => path, :oid => oids[asset_version.asset.serial][asset_version.revision], :mode => 0100644)
                if meta_oids.has_key?(asset_version.asset.serial) then
                  index.add(:path => path + '.meta', :oid => meta_oids[asset_version.asset.serial][asset_version.revision], :mode => 0100644)
                end
              end
            end

            Uas2Git::Uas::Model::AssetVersion.joins(:type).where('assettype.description = \'dir\'').where(
                'created_in <= :c AND assetversion.serial IN (SELECT assetversion FROM changesetcontents WHERE changesetcontents.changeset <= :c) AND revision = (SELECT MAX(revision) FROM assetversion AV2 WHERE AV2.asset = assetversion.asset AND AV2.created_in <= :c)',
                { :c => changeset.serial }
            ).find_each do |asset_version|

              next if asset_version.parent.nil?

              path = dirs[changeset.serial][asset_version.parent.serial] + '/' + asset_version.name

              next if path.start_with?('Trash/')

              index.add(
                  :path => path + '.meta',
                  :oid => repo.write(generate_directory_meta(asset_version.asset), :blob),
                  :mode => 0100644
              )
            end

            author = {
                :name => changeset.creator.username,
                :email => '',
                :time => changeset.commit_time.nil? ? Time.now : changeset.commit_time
            }

            Rugged::Commit.create(repo, {
                :tree => index.write_tree(repo),
                :author => author,
                :committer => author,
                :message => changeset.description,
                :parents => repo.empty? ? [] : [ repo.head.target ].compact,
                :update_ref => 'HEAD'
            })
          end
        end
      end

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
      options[:password] = nil

      @opts = OptionParser.new do |opts|
        opts.banner = 'Usage: uas2git PROJECT_NAME [options]'

        opts.separator ''
        opts.separator 'Specific options:'

        opts.on('-H', '--host NAME', 'Unity Asset Server host') do |host|
          options[:host] = host
        end

        opts.on('-u', '--username NAME', 'Crendential for Unity Asset Server') do |username|
          options[:username] = username
        end

        opts.on('-p', '--password PASSWD') do |password|
          options[:password] = password
        end

        opts.separator ''

        # No argument, shows at tail.  This will print an options summary.
        # Try it and see!
        opts.on_tail('-h', '--help', 'Show this message') do
          puts opts
          exit
        end
      end

      @opts.parse! args
      options
    end

    def generate_directory_meta(asset)
      guid_string = [asset.guid].pack('B*').unpack("H*").join

      <<EOF
fileFormatVersion: 2
guid: #{guid_string}
folderAsset: yes
DefaultImporter:
  userData:\s
EOF
    end

    def show_help_message(msg)
      puts "Error starting script: #{msg}\n\n"
      puts @opts.help
      exit
    end
  end
end
