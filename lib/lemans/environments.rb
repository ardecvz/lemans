# frozen_string_literal: true

module Lemans
  # The backends `lemans run --backend` can name, and the one place a name
  # becomes a class. An unknown backend fails as a config mistake.
  module Environments
    BACKENDS = { "daytona" => "Daytona", "docker" => "Docker" }.freeze

    @registered = {}

    class << self
      def register(name, environment_class) = @registered[name] = environment_class

      def unregister(name) = @registered.delete(name)

      def names = BACKENDS.keys | @registered.keys

      def build(backend, **) = lookup(backend.to_s).new(**)

      def lookup(name)
        @registered[name] || (BACKENDS[name] && const_get(BACKENDS[name])) or
          raise ConfigError, "unknown backend #{name.inspect} (known: #{names.join(", ")})"
      end
    end
  end
end
