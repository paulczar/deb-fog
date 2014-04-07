$:.unshift File.expand_path("../lib", __FILE__)
require "deb/s3"

Gem::Specification.new do |gem|
  gem.name        = "deb-s3"
  gem.version     = Deb::S3::VERSION

  gem.author      = "Paul Czarkowski"
  gem.email       = "paul.czarkowski@rackspace.com"
  gem.homepage    = "http://rackspace.com"
  gem.summary     = "Easily create and manage an APT repository with Fog."
  gem.description = gem.summary
  gem.executables = "deb-fog"

  gem.files = Dir["**/*"].select { |d| d =~ %r{^(README|bin/|ext/|lib/)} }

  gem.add_dependency "thor",    "~> 0.18.0"
  gem.add_dependency "fog", "~> 1.21"
end
