require 'rugged'
require 'progress'

module Uas2Git
  class Migrator
    def initialize(repo)
      @repo = repo
    end

    def migrate!
      # Importing changesets
      @paths = {}
      @index = Rugged::Index.new

      Progress.start('Importing ' + Uas2Git::Uas::Model::AssetVersion.count.to_s + ' asset versions in ' + Uas2Git::Uas::Model::Changeset.count.to_s + ' changesets', Uas2Git::Uas::Model::AssetVersion.count * 3) do
        Uas2Git::Uas::Model::Changeset.find_each do |changeset|
          import_changeset(changeset)
        end
      end
    end

    private

    def import_changeset(changeset)
      old_paths = @paths.clone
      asset_versions = changeset.asset_versions.includes(:parent, :asset, :type)

      asset_versions.find_each do |v|
        Progress.step do
          if v.parent then
            path = @paths[v.parent.serial] + '/' + v.name
          elsif %w(00000000000000001000000000000000 ffffffffffffffffffffffffffffffff).include?(v.asset.guid_hex) then
            path = v.name
          else
            path = 'ProjectSettings/' + v.name
          end

          @paths[v.asset.serial] = path
        end
      end

      asset_versions.find_each do |v|
        Progress.step do
          # Has moved or deleted?
          if old_paths.has_key?(v.asset.serial) && old_paths[v.asset.serial] != @paths[v.asset.serial] then
            old_path = old_paths[v.asset.serial]

            if v.type.description == 'dir' then
              @index.remove(old_path + '.meta')

              old_paths.select { |asset_serial, path| path.start_with?(old_path + '/') }.each { |asset_serial, path|
                old_paths[asset_serial] = @paths[v.asset.serial] + path[old_path.length .. -1]
              }

              @paths.select { |asset_serial, path| path.start_with?(old_path + '/') }.each { |asset_serial, path|
                @paths[asset_serial] = @paths[v.asset.serial] + path[old_path.length .. -1]
              }

              @index.remove_all(old_path + '/*') { |matched, pathspec|
                entry = @index[matched]
                entry[:path] = @paths[v.asset.serial] + entry[:path][old_path.length .. -1]
                @index << entry

                true
              }
            else
              v.contents.find_each do |c|
                @index.remove(old_path) if c.tag == 'asset'
                @index.remove(old_path + '.meta') if c.tag == 'asset.meta'
              end
            end
          end
        end
      end

      asset_versions.find_each do |v|
        Progress.step do
          if v.type.description == 'dir' then
            if v.parent then
              @index << { path: @paths[v.asset.serial] + '.meta', oid: dir_meta_oid(v.asset), mode: 0100644 }
            end
          else
            v.contents.each do |c|
              oid = LOReader.new(v.class.connection.raw_connection).open(c.stream) { |lo| Rugged::Blob.from_io(@repo, lo) }

              @index << { path: @paths[v.asset.serial], oid: oid, mode: 0100644 } if c.tag == 'asset'
              @index << { path: @paths[v.asset.serial] + '.meta', oid: oid, mode: 0100644 } if c.tag == 'asset.meta'
            end
          end
        end
      end

      # Exclude trashes
      tree_builder = Rugged::Tree::Builder.new(@repo.lookup(@index.write_tree(@repo)))
      tree_builder.remove('Trash') if tree_builder['Trash']
      tree = tree_builder.write(@repo)

      author = {
          :name => changeset.creator.username,
          :email => '',
          :time => changeset.commit_time.nil? ? Time.now : changeset.commit_time
      }

      Rugged::Commit.create(@repo, {
          :tree => tree,
          :author => author,
          :committer => author,
          :message => changeset.description,
          :parents => @repo.empty? ? [] : [ @repo.head.target ].compact,
          :update_ref => 'HEAD'
      })
    end

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
