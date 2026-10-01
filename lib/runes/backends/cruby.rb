# frozen_string_literal: true

# CRuby backends for the kernel facades. Loaded by lib/runes.rb (the harness
# keeps stdlib speed); the Spinel kernel entry (spin/kernel.rb) wires the
# pure backends instead and never loads this file.
require 'json'
require 'openssl'
require 'securerandom'

require_relative '../runtime'
require_relative '../workflow/util'
require_relative '../json_facade'
require_relative '../sha256_facade'
require_relative '../random_facade'
require_relative '../security/crypto_backend'
require_relative '../security/crypto_backends/openssl'

# CRuby runtime capabilities (docs/spinel/spec-tier-c.md §C3): dynamic rune
# bindings (third-party `use`), `use` cog loading, and `use` constant lookup.
module Runes
  module Runtime
    def self.require_cog(path)
      require path
    end

    def self.resolve_rune_class(loadable)
      camelized = Runes::Util.camelize(loadable)
      ['Runes::Plugins::' + camelized, camelized].each do |constant|
        return Object.const_get(constant) if Object.const_defined?(constant)
      end
      nil
    end

    def self.bind_rune_type(context, method_name)
      question = "#{method_name}?"
      bang = "#{method_name}!"
      [method_name, question, bang].each do |name|
        if context.respond_to?(name, true)
          raise Runes::CogInputContext::IllegalRuneNameError,
                "rune name #{method_name.inspect} collides with an existing #{name.inspect} context method"
        end
      end
      context.define_singleton_method(method_name) { |name| cog_output(name) }
      context.define_singleton_method(question) { |name| cog_output?(name) }
      context.define_singleton_method(bang) { |name| cog_output!(name) }
    end

    def self.bind_config_verb(context, method_name, on_config, rune_class)
      rune_method = proc do |target = nil, &config_proc|
        on_config.call(rune_class, target, config_proc)
      end
      context.define_singleton_method(method_name, &rune_method)
    end

    def self.bind_rune_verb(context, method_name, on_execute, rune_class)
      rune_method = proc do |*args, **kwargs, &input_proc|
        on_execute.call(rune_class, args, kwargs, input_proc)
      end
      context.define_singleton_method(method_name, &rune_method)
    end

    def self.eval_workflow_source(workflow, source, path)
      workflow.instance_eval(source, path, 1)
    end
  end
end

Runes::Runtime.dynamic_bindings = true

module Runes
  # Stdlib JSON behind the Runes::Json contract. Backend errors are
  # normalized to Runes::Json::ParseError by the facade itself.
  module JSONStdlibBackend
    def self.parse(str, max_nesting: nil, symbolize_names: false)
      options = {}
      options[:max_nesting] = max_nesting unless max_nesting.nil?
      options[:symbolize_names] = true if symbolize_names
      ::JSON.parse(str, **options)
    end

    def self.generate(obj)
      ::JSON.generate(obj)
    end
  end

  # OpenSSL fast path behind Runes::SHA256.
  module SHA256OpenSSLBackend
    def self.hex(str)
      OpenSSL::Digest::SHA256.hexdigest(str.to_s)
    end
  end

  # SecureRandom behind Runes::Random (CSPRNG: nonces and key material).
  module RandomSecureBackend
    def self.bytes(n)
      SecureRandom.random_bytes(n)
    end
  end
end

Runes::Json.backend = Runes::JSONStdlibBackend
Runes::SHA256.backend = Runes::SHA256OpenSSLBackend
Runes::Random.backend = Runes::RandomSecureBackend
Runes::Security::CryptoBackend.backend = Runes::Security::CryptoBackends::OpenSSLBackend

