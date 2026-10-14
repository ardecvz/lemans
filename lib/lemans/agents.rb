# frozen_string_literal: true

module Lemans
  # The agents by name, resolved the way Environments.build resolves backends:
  # the abstract class carries no list of its own children.
  module Agents
    REGISTRY = {
      "nop" => "Nop",
      "oracle" => "Oracle",
      "miniswen" => "Miniswen",
      "miniswen-installed" => "MiniswenInstalled"
    }.freeze

    @registered = {}

    class << self
      def register(name, agent_class) = @registered[name] = agent_class

      def unregister(name) = @registered.delete(name)

      def names = REGISTRY.keys | @registered.keys

      def build(name, profile:, model: nil) = lookup(name).new(profile: profile, model: model)

      def lookup(name)
        @registered[name] || (REGISTRY[name] && const_get(REGISTRY[name])) or
          raise ConfigError, "unknown agent #{name.inspect} (known: #{names.join(", ")})"
      end
    end
  end
end
