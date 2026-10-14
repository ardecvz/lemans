# frozen_string_literal: true

require "test_helper"

class EnvironmentsTest < Minitest::Test
  class TestBackend < Lemans::Environment
    attr_reader :options

    def initialize(**options)
      @options = options
    end
  end

  def teardown
    Lemans::Environments.unregister("test-backend")
    Lemans::Environments.unregister("docker")
  end

  def test_register
    Lemans::Environments.register("test-backend", TestBackend)

    environment = Lemans::Environments.build(:"test-backend", ttl: 60)

    assert_instance_of TestBackend, environment
    assert_equal({ ttl: 60 }, environment.options)
    assert_equal %w[daytona docker test-backend], Lemans::Environments.names
  end

  def test_override_builtin
    Lemans::Environments.register("docker", TestBackend)

    assert_instance_of TestBackend, Lemans::Environments.build("docker")
    assert_equal %w[daytona docker], Lemans::Environments.names

    Lemans::Environments.unregister("docker")

    assert_equal Lemans::Environments::Docker, Lemans::Environments.lookup("docker")
  end

  def test_unknown_backend
    error = assert_raises(Lemans::ConfigError) { Lemans::Environments.build("nope") }

    assert_equal "unknown backend \"nope\" (known: daytona, docker)", error.message
  end
end
