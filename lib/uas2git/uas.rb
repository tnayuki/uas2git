require 'active_record'
require 'safe_attributes/base'

module Uas2Git
  module Uas
    module Model
      class Asset < ActiveRecord::Base
        self.table_name = 'asset'
        self.primary_key = 'serial'

        has_many :versions, :class_name => 'AssetVersion', :primary_key => 'serial', :foreign_key => 'asset'
      end

      class AssetContents < ActiveRecord::Base
        self.table_name = 'assetcontents'
        self.primary_key = [ 'assetversion', 'tag' ]

        belongs_to :asset_version, :class_name => 'AssetVersion', :primary_key => 'serial', :foreign_key => 'assetversion'
      end

      class AssetType < ActiveRecord::Base
        self.table_name = 'assettype'
        self.primary_key = 'serial'
      end

      class AssetVersion < ActiveRecord::Base
        self.table_name = 'assetversion'
        self.primary_key = 'serial'

        belongs_to :asset, :class_name => 'Asset', :primary_key => 'serial', :foreign_key => 'asset'
        belongs_to :parent, :class_name => 'Asset', :primary_key => 'serial', :foreign_key => 'parent'
        belongs_to :created_in, :class_name => 'Changeset', :primary_key => 'serial', :foreign_key => 'created_in'
        belongs_to :type, :class_name => 'AssetType', :primary_key => 'serial', :foreign_key => 'assettype'
        has_many :contents, :class_name => 'AssetContents', :primary_key => 'serial', :foreign_key => 'assetversion'
      end

      class Changeset < ActiveRecord::Base
        include SafeAttributes::Base

        bad_attribute_names :my_attr
        validates_presence_of :my_attr

        self.table_name = 'changeset'
        self.primary_key = 'serial'

        has_many :contents, :class_name => 'ChangesetContents', :foreign_key => 'changeset'
        has_many :asset_versions, :through => :contents

        belongs_to :creator, :class_name => 'Person', :primary_key => 'serial', :foreign_key => 'creator'
      end

      class ChangesetContents < ActiveRecord::Base
        self.table_name = 'changesetcontents'

        belongs_to :changeset, :foreign_key => 'changeset'
        belongs_to :asset_version, :foreign_key => 'assetversion'
      end

      class Person < ActiveRecord::Base
        self.table_name = 'person'
        self.primary_key = 'serial'

        has_many :changesets, :foreign_key => 'creator'
      end
    end
  end
end
