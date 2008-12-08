require "loadable_from_lookups"

class ActiveRecord::Base
  extend LoadableFromLookups
end