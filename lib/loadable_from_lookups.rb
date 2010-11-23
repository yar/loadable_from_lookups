# Forecasts and metars (and potentially other objects) are historically loaded
# from text lookup files. Now we begin to store all the values in the database
# so text loading technique may or may not be useful in the future.

# This module maps all the lookup fields into a single text field of the database, 
# making its content accessible through "vars" property. It also allows to prefill
# the ActiveRecord object from a text lookup.

# Importing the records into the database is beyond the scope of this mixin because
# it requires interaction of multiple models, e.g. missing locations, countries.
require "iconv"
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
      find :first, :order => "issued_at DESC"
    end  
    
    # Iterate over all available lookups
    def each_lookup(&block)
      Dir.chdir(self.options[:dir]) do
        Dir.new(".").each do |filename|
          if filename.include?(LOOKUP_EXTENSIONS[self.options[:format]])
            location_name = filename \
              .gsub(LOOKUP_EXTENSIONS[self.options[:format]], "") \
              .gsub(self.options[:postfix], "") \
              .gsub(self.options[:unwanted_chars], "")
            obj = self.new
            obj.data = obj.read_lookup(filename)          
            mtime = File.mtime(filename).to_i
            obj.lookup_timestamp = mtime
            obj.lookup_filename = filename
            yield obj, location_name
          end
        end
      end      
    end

    def from_lookup(filename_part)
      obj = self.new

      # Load primary lookup
      Dir.chdir(self.options[:dir]) do
        filename = filename_part + self.options[:postfix] + LOOKUP_EXTENSIONS[self.options[:format]]
        mtime = File.mtime(filename).to_i
        obj.data = Rails.cache.fetch(filename + "_data_" + mtime.to_s, :expires_in => 6.hours) do # TODO (literal const.)
          obj.read_lookup(filename)          
        end
        obj.lookup_timestamp = mtime
        obj.lookup_filename = filename
      end
        
      # Load all dependent lookups
			begin
				if options[:dependent]
					options[:dependent].each do |dep_options|
						Dir.chdir(dep_options[:dir]) do
							if dep_options[:key]
								dep_filename_part = obj.vars_without_caching[dep_options[:key]]
							else
								dep_filename_part = filename_part
							end
							dep_filename = dep_filename_part + dep_options[:postfix] + LOOKUP_EXTENSIONS[dep_options[:format]]
							dep_mtime = File.mtime(dep_filename).to_i
							dep_data = Rails.cache.fetch(dep_filename + "_data_" + dep_mtime.to_s, :expires_in => 6.hours) do
								obj.read_lookup(dep_filename, dep_options[:format])
							end
							obj.data += ".merge(" + dep_data + ")"
							obj.lookup_filename += "+#{dep_filename}"
							obj.lookup_timestamp = [obj.lookup_timestamp, dep_mtime].max
						end
					end
				end
			rescue
        logger.error $!
			end

      if obj.vars["_gmtissued"] # As in forecasts
        begin
          obj.issued_at = Time.gm(*(Time.parse(obj.vars["_gmtissued"])))
        rescue
          logger.error "Wrong datetime: #{obj.vars["_gmtissued"]}, error message: #{$!}"
          obj.issued_at = Time.now.utc
        end          
      else # As in metars
        begin
          obj.issued_at = Time.parse(obj.vars["_date0"] + " " + obj.vars["_time0"])
        rescue
          obj.issued_at = Time.now.utc # Silently! (TODO)
        end          
      end
      return obj
    rescue Errno::ENOENT
			logger.error $!
      return nil
    end
  
  end
    
  module InstanceMethods
    def vars
      return @vars if @vars
      
      tmp = Rails.cache.fetch("#{self.class.to_s}/#{lookup_filename||id}/#{lookup_timestamp}", :expires_in => 6.hours) do
        vars_without_caching
  		end
      return @vars = tmp.dup
    end
    
    def vars_without_caching
      if data.mb_chars.size == 65535
        data.gsub! /,[^,]*\Z/m, "}"
      end
			begin
				eval(read_attribute("data"))      
			rescue SyntaxError
				raise "Cannot eval for forecast #{id}"
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
      case format
      when :ruby_hash
        content = File.read(path)
      when :php # old php format
        content = File.read(path)
        content.gsub!("<?\n$vars = array(\n", "{")
        content.gsub!("<?$vars = array(\n", "{")
        content.gsub!(");\n?>", "}")
      when :lookup
        content = File.read(path)
        content.gsub!('"', '\"')
        content.gsub!(/^s(_.*)\|(.*)$/, '"\1" => "\2",')
        content.gsub!('_top', '_max')
        content.gsub!('_bot', '_min')
        content.gsub!('rztop', 'rzmax')
        content.gsub!('rzbot', 'rzmin')
        content = "{" + content + "}"
      end
      filtered_content = content.filter_utf8
      if filtered_content != content
        logger.error("Characters illegal for utf8 found in #{path}, removing - watch out for misspelled words!")
      end
      filtered_content
    end
  end
  
  # supported formats are :php and :ruby_hash 
  def loadable_from_lookups(options)
    self.send :attr, :lookup_timestamp, true
    self.send :attr, :lookup_filename, true
    self.send :extend, ClassMethods
    self.send :include, InstanceMethods
    self.options = options
    self.options[:unwanted_chars] ||= UNWANTED_CHARS
  end
end

class String
  @@ic = Iconv.new('UTF-8//IGNORE', 'UTF-8')

  # remove all chars illegal for utf8
  def filter_utf8
    @@ic.iconv(self + ' ')[0..-2]
  end
end
