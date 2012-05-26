# Forecasts and metars (and potentially other objects) are historically loaded
# from text lookup files. Now we begin to store all the values in the database
# so text loading technique may or may not be useful in the future.

# This module maps all the lookup fields into a single text field of the database,
# making its content accessible through "vars" property. It also allows to prefill
# the ActiveRecord object from a text lookup.

# Importing the records into the database is beyond the scope of this mixin because
# it requires interaction of multiple models, e.g. missing locations, countries.
# require "memcache_util"

module LoadableFromLookups
  UNWANTED_CHARS = /[^\w\d_ -]/

  module ClassMethods
    attr_accessor :options
    LOOKUP_EXTENSIONS = { :php => ".array.php",
                          :ruby_hash => ".hash.rb",
                          :lookup => ".lookup" }

    # finder
    def find_latest
      order("issued_at DESC").first
    end

    # Iterate over all available lookups
    def each_lookup(&block)
      Dir.chdir(self.options[:dir]) do
        Dir.new(".").each do |filename|
          if filename.include?(LOOKUP_EXTENSIONS[self.options[:format]])
            location_name = filename \
              .gsub(LOOKUP_EXTENSIONS[self.options[:format]], "") \
              .gsub(self.options[:postfix], "")

            next if self.options[:unwanted_chars] && location_name =~ self.options[:unwanted_chars]

            obj = from_lookup(location_name)
            yield obj, location_name
          end
        end
      end
    end

    def from_lookup(filename_part)
      obj = self.new

      # Load primary lookup
      obj.lookup_filename_part = filename_part
      filename = filename_part + self.options[:postfix] + LOOKUP_EXTENSIONS[self.options[:format]]
      obj.lookup_filename = filename
      if self.options[:timestamp_method]
        obj.lookup_timestamp = self.options[:timestamp_method].call(filename_part)
      else
        obj.lookup_timestamp = obj.load_data
      end
      obj.lookup_mtime = Time.at(obj.lookup_timestamp)
      return obj
    end

  end

  module InstanceMethods
    def load_data
      self._tried_to_load_data = true
      options = self.class.options
      # Load primary lookup
      main_lookup_timestamp = nil
      Dir.chdir(options[:dir]) do
        mtime = File.mtime(self.lookup_filename)
        self.data = Rails.cache.fetch(self.lookup_filename + "_data_" + mtime.to_i.to_s, :expires_in => 6.hours) do # TODO (literal const.)
          self.read_lookup(self.lookup_filename)
        end
        # TODO: what if timestamp_method is not provided?
        # obj.lookup_mtime = mtime
        # obj.lookup_timestamp = mtime.to_i
        main_lookup_timestamp = mtime.to_i
      end

      # Load all dependent lookups
      main_lookup_vars = nil
      begin
        if options[:dependent]
          options[:dependent].each do |dep_options|
            Dir.chdir(dep_options[:dir]) do
              if dep_options[:key]
                main_lookup_vars = self.vars_without_caching
                dep_filename_part = main_lookup_vars[dep_options[:key]] # not used at snow
              else
                dep_filename_part = self.lookup_filename_part
              end
              dep_filename = dep_filename_part + dep_options[:postfix] + ClassMethods::LOOKUP_EXTENSIONS[dep_options[:format]]
              dep_mtime = File.mtime(dep_filename).to_i
              dep_data = Rails.cache.fetch(dep_filename + "_data_" + dep_mtime.to_s, :expires_in => 6.hours) do
                self.read_lookup(dep_filename, dep_options[:format])
              end
              self.data = self.data.strip + ".merge(" + dep_data + ")"
              # obj.lookup_filename += "+#{dep_filename}"
              # obj.lookup_timestamp = [obj.lookup_timestamp, dep_mtime].max
            end
          end
        end
      rescue
        logger.error $!
      end
      return main_lookup_timestamp
    rescue Errno::ENOENT
      logger.error "#{$!}"
      return nil
    end

    def vars
      @vars ||= Rails.cache.fetch("#{self.class.to_s}/#{lookup_filename||id}/#{lookup_timestamp}", :expires_in => 6.hours) do
        vars_without_caching
  		end
    end

    def vars_without_caching
			begin
				eval(data)
			rescue SyntaxError
			  if self.class.options[:exceptions_unchanged]
			    raise
				else
  				raise "Cannot eval for forecast #{lookup_filename||id}"
			  end
			end
    end

    def issued_at
      if self.id || self.attributes["issued_at"]
        return self.attributes["issued_at"]
      else
        if vars["_gmtissued"] # As in forecasts
          begin
            write_attribute :issued_at, Time.gm(*(Time.parse(vars["_gmtissued"])))
          rescue
            logger.error "Wrong datetime: #{vars["_gmtissued"]}, error message: #{$!}"
            write_attribute :issued_at, Time.now.utc
          end
        else # As in metars
          begin
            write_attribute :issued_at, Time.parse(vars["_date0"] + " " + vars["_time0"])
          rescue
            write_attribute :issued_at, Time.now.utc # Silently! (TODO)
          end
        end
        return self.attributes["issued_at"]
      end
    end

    def vars=(values)
      str = "{\n"
      values.each do |key, value|
        str += "\"#{key}\" => \"#{value}\",\n"
      end
      str += "}"
      write_attribute("data", str)
    end

    def data=(str)
      write_attribute("data", str)
      @vars = nil # bust the cache
    end

    def data
      unless self._tried_to_load_data || self.id
        load_data
      end
      read_attribute("data")
    end

    def p_period(key, i)
      vars["_p#{key}_#{i}"]
    end

    def t_period(key, i)
      vars["_t#{key}_#{i}"]
    end

    def d_period(key, i)
      vars["_d#{key}_#{i}"]
    end

    def p_period_with_dot(key, i)
      vars["_p#{key}.#{i}"]
    end

    def t_period_with_dot(key, i)
      vars["_t#{key}.#{i}"]
    end

    def d_period_with_dot(key, i)
      vars["_d#{key}.#{i}"]
    end

    def hr_period(key, i)
      vars["_#{key}_hr_#{i}"]
    end

    def day_period(key, i)
      vars["_#{key}_day_#{i}"]
    end

    def six_hr_period(key, i)
      vars["_#{key}_6h_#{i}"]
    end

    # returns vars hash
    def read_lookup(path, format=nil)
      format ||= self.class.options[:format]

      raw_content = File.read(path)

      content = raw_content.filter_utf8
      if content != raw_content
        logger.error("UNICODE PROBLEM: characters illegal for utf8 found in #{path}, removing - watch out for misspelled words!")
      end

      case format
      when :ruby_hash
        # do nothing
      when :php # old php format
        content.gsub!("<?\n$vars = array(\n", "{")
        content.gsub!("<?$vars = array(\n", "{")
        content.gsub!(");\n?>", "}")
      when :lookup
        content.gsub!('"', '\"')
        content.gsub!('#', '\#')
        content.gsub!(/^s(_.*?)\|(.*?)$/, '"\1" => "\2",')
        content.gsub!(/^([^_"][^|]*?)\|(.*?)$/, '"\1" => "\2",')
        content.gsub!('_top', '_max')
        content.gsub!('_bot', '_min')
        content.gsub!('rztop', 'rzmax')
        content.gsub!('rzbot', 'rzmin')
        content = "{" + content + "}"
      end
      content
    end
  end

  # supported formats are :php and :ruby_hash
  def loadable_from_lookups(options)
    self.send :attr, :lookup_mtime, true
    self.send :attr, :lookup_timestamp, true
    self.send :attr, :lookup_filename, true
    self.send :attr, :lookup_filename_part, true
    self.send :attr, :_tried_to_load_data, true
    self.send :extend, ClassMethods
    self.send :include, InstanceMethods
    self.options = options
    self.options[:unwanted_chars] ||= UNWANTED_CHARS
  end

  class LookupFileMissingError < StandardError
  end
end

class String
  # remove all chars illegal for utf8
  def filter_utf8
    "#{self}".encode("UTF-8", :invalid => :replace, :undef => :replace, :replace => "?")
  end
end

class ActiveRecord::Base
  extend LoadableFromLookups
end
