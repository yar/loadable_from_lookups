$:.push File.expand_path("../lib", __FILE__)

# # Maintain your gem's version:
# require "fcmaps/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "loadable_from_lookups"
  # s.version     = Fcmaps::VERSION
  s.version     = "1.0"
  s.authors     = ["Yar Dmitriev"]
  s.email       = ["yar.dmitriev@gmail.com"]
  # s.homepage    = "n/a"
  s.summary     = "Suport for Rob's lookup files"
  s.description = ""

  s.files = Dir["{app,config,db,lib}/**/*"] #+ ["MIT-LICENSE", "Rakefile", "README.rdoc"]
  s.test_files = Dir["test/**/*"]

  # s.add_dependency "rails", "~> 3.2.2"
  # s.add_dependency "compass"

  # s.add_development_dependency "sqlite3"
end
