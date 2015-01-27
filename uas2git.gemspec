# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'uas2git/version'

Gem::Specification.new do |spec|
  spec.name          = 'uas2git'
  spec.version       = Uas2Git::VERSION
  spec.authors       = ['Toru Nayuki']
  spec.email         = ['tnayuki@icloud.com']
  spec.summary       = 'A tool for migrating Unity Asset Server projects to git'
  spec.homepage      = 'https://github.com/tnayuki/uas2git'
  spec.license       = 'MIT'

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'activerecord'
  spec.add_runtime_dependency 'highline'
  spec.add_runtime_dependency 'rugged'
  spec.add_runtime_dependency 'pg'
  spec.add_runtime_dependency 'progress'
  spec.add_runtime_dependency 'safe_attributes'

  spec.add_development_dependency 'bundler', '~> 1.5'
  spec.add_development_dependency 'rake'
end
