# frozen_string_literal: true

require "test_helper"

class AgentsTest < Minitest::Test
  class TestAgent < Lemans::Agent
    NAME = "test-agent"

    def run(_task, _environment) = Response.new(outcome: Lemans::Result::Outcome.new(:completed), usage: Lemans::Result::Usage.zero)
  end

  def teardown
    Lemans::Agents.unregister(TestAgent::NAME)
    Lemans::Agents.unregister("oracle")
  end

  def test_register
    Lemans::Agents.register(TestAgent::NAME, TestAgent)
    config = Lemans::Config::Agent.new(TestAgent::NAME, "some/model")

    agent = Lemans::Agents.build(TestAgent::NAME, profile: config, model: "other/model")

    assert_instance_of TestAgent, agent
    assert_equal "other/model", agent.model
    assert_includes Lemans::Agents.names, TestAgent::NAME
    assert_instance_of Lemans::Agents::Oracle, Lemans::Agents.build("oracle", profile: config)
  end

  def test_override_builtin
    config = Lemans::Config::Agent.new("oracle", "some/model")
    Lemans::Agents.register("oracle", TestAgent)

    assert_instance_of TestAgent, Lemans::Agents.build("oracle", profile: config)
    assert_equal 1, Lemans::Agents.names.count("oracle")

    Lemans::Agents.unregister("oracle")

    assert_instance_of Lemans::Agents::Oracle, Lemans::Agents.build("oracle", profile: config)
  end

  def test_unknown_agent
    Lemans::Agents.register(TestAgent::NAME, TestAgent)

    error = assert_raises(Lemans::ConfigError) do
      Lemans::Agents.build("nope", profile: Lemans::Config::Agent.new("nope", "some/model"))
    end

    assert_equal "unknown agent \"nope\" (known: nop, oracle, miniswen, miniswen-installed, test-agent)", error.message
  end
end
