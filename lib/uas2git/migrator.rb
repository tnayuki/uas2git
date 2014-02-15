require 'rugged'
require 'progress'

module Uas2Git
  class Migrator
    def initialize(repo)
      @repo = repo
    end

    def migrate!
      # Import files
      oids = {}
      meta_oids = {}

      asset_versions = Uas2Git::Uas::Model::AssetVersion.joins(:type).where('assettype.description <> \'dir\'')
      Progress.start('Importing ' + asset_versions.count.to_s + ' files', asset_versions.count) do
        asset_versions.find_each do |asset_version|
          Progress.step do
            asset_version.contents.each do |contents|
              oid = LOReader.new(asset_version.class.connection.raw_connection).open(contents.stream) do |lo|
                Rugged::Blob.from_chunks(@repo, lo)
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
                  :oid => dir_meta_oid(asset_version.asset),
                  :mode => 0100644
              )
            end

            author = {
                :name => changeset.creator.username,
                :email => '',
                :time => changeset.commit_time.nil? ? Time.now : changeset.commit_time
            }

            Rugged::Commit.create(@repo, {
                :tree => index.write_tree(@repo),
                :author => author,
                :committer => author,
                :message => changeset.description,
                :parents => @repo.empty? ? [] : [ @repo.head.target ].compact,
                :update_ref => 'HEAD'
            })
          end
        end
      end
    end

    private
    def dir_meta_oid(asset)
      @dir_meta_oids ||= {}

      meta = <<EOF
fileFormatVersion: 2
guid: #{asset.guid_hex}
folderAsset: yes
DefaultImporter:
  userData:\s
EOF

      @dir_meta_oids[asset.serial] = @repo.write(meta, :blob)
    end
  end
end
