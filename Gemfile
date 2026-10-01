source 'https://rubygems.org'

gem 'mqtt', '~> 0.7'
gem 'sqlite3', '~> 2.9'
gem 'dotenv', '~> 3.1'
gem 'wasmtime', '~> 47.0'

group :test, :development do
  gem 'minitest', '~> 5.25'
  gem 'rake', '~> 13.2'
  # Bundled gem since Ruby 4.0: the Tier B Native binder (Fiddle) exercises
  # the same C functions the Spinel FFI binds (test/native_backend_test.rb,
  # spin/kernel_cruby.rb). Not a runtime dependency of the shipped harness.
  gem 'fiddle'
end
