# Forecasts and metars (and potentially other objects) are historically loaded
# from text lookup files. Now we begin to store all the values in the database
# so text loading technique may or may not be useful in the future.

# This module maps all the lookup fields into a single text field of the database, 
# making its content accessible through "vars" property. It also allows to prefill
# the ActiveRecord object from a text lookup.

# Importing the records into the database is beyond the scope of this mixin because
# it requires interaction of multiple models, e.g. missing locations, countries.
require "iconv"

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
            yield obj, location_name
          end
        end
      end      
    end

    def from_lookup(filename_part)
      Dir.chdir(self.options[:dir]) do
        filename = filename_part + self.options[:postfix] + LOOKUP_EXTENSIONS[self.options[:format]]
        cached_obj = Rails.cache.fetch(filename + "_" + File.mtime(filename).to_i.to_s, :expires_in => 6.hours) do
          obj = self.new
          obj.data = obj.read_lookup(filename)          

          if obj.vars["_gmtissued"] # As in forecasts
            begin
              obj.issued_at = Time.gm(*(ParseDate.parsedate(obj.vars["_gmtissued"])))
            rescue
              logger.error "Wrong datetime: " + vars["_gmtissued"] + $!
              obj.issued_at = Time.now.utc
            end          
          else # As in metars
            begin
              obj.issued_at = Time.parse(obj.vars["_date0"] + " " + obj.vars["_time0"])
            rescue
              obj.issued_at = Time.now.utc # Silently!
            end          
          end
          obj
        end
        return cached_obj.frozen? ? cached_obj.clone : cached_obj
      end
    end
  
  end
    
  module InstanceMethods
    # getter
    def vars
      if data.mb_chars.size == 65535
        data.gsub! /,[^,]*\Z/m, "}"
      end
			begin
				eval(read_attribute("data"))      
			rescue SyntaxError
				raise "Cannot eval for forecast #{id}"
			end
    end
    
    # setter
    def vars=(values)
      str = "{\n"
      values.each do |key, value|
        str += "\"#{key}\" => \"#{value}\",\n"
      end
      str += "}"
      write_attribute("data", str)      
    end    

    # returns vars hash
    def read_lookup(path)
      case self.class.options[:format]
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
