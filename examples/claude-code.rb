# frozen_string_literal: true

# Claude Code as a lemans agent: the CLI runs headless inside the sandbox.
#
#   lemans -r ./examples/claude-code.rb run --agent claude-code --model claude-sonnet-5-5
#
# A `#<effort>` suffix sets the effort level (low, medium, high, xhigh, max):
# `--model claude-sonnet-5-5#high`.
#
# Credentials: export CLAUDE_CODE_OAUTH_TOKEN (`claude setup-token`, uses a
# Claude subscription) or ANTHROPIC_API_KEY.
#
# The sandbox image needs bash and curl: the installer pulls the native binary
# while the setup network is open. To skip that per trial (recommended), bake it into the image:
#
#   RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh && \
#       bash /tmp/claude-install.sh && rm /tmp/claude-install.sh
#
# The agent phase only needs the API:
#
#   agent:
#     environment:
#       network:
#         mode: allowlist
#         hosts: [api.anthropic.com]

require "json"
require "shellwords"
require "tempfile"

class ClaudeCodeAgent < Lemans::Agent
  NAME = "claude-code"

  CREDENTIALS = %w[CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY].freeze
  PATH = "export PATH=$HOME/.local/bin:$PATH;"
  API_HOST = "api.anthropic.com"
  STREAM_PATH = "/tmp/lemans-claude.jsonl"

  OUTCOMES = {
    "success" => :completed,
    "error_max_turns" => :step_limit_reached,
    "error_max_budget_usd" => :cost_ceiling_reached
  }.freeze

  def initialize(...)
    super
    raise Lemans::ConfigError, "claude-code: export one of #{CREDENTIALS.join(", ")}" if ENV.slice(*CREDENTIALS).empty?

    policy = profile.environment.network
    return if policy.public? || policy.domains.include?(API_HOST)

    raise Lemans::ConfigError, "claude-code: the agent network must reach #{API_HOST} " \
                               "(agent.environment.network: public, or an allowlist listing it)"
  end

  def install(_task, environment)
    environment.exec!("set -o pipefail; #{PATH} command -v claude || { curl -fsSL https://claude.ai/install.sh | bash && command -v claude; }",
                      timeout: 300)
  end

  # TODO: convert the stream into an ATIF trajectory (miniswen-compatible, so
  # lemans-viewer can show it) and return it as the Response's trajectory.
  def run(task, environment, history: nil)
    finished = environment.exec("#{command_for(task)} > #{STREAM_PATH}", timeout:, env: claude_env)
    stream = download_stream(environment)
    artifacts = stream ? { "claude.jsonl" => stream } : {}
    if finished.exit_code == 124
      return Lemans::Agent::Response.new(outcome: Lemans::Result::Outcome.new(:agent_timeout), usage: unknown_usage, artifacts:)
    end

    report = result_from(stream)
    unless report
      return Lemans::Agent::Response.new(artifacts:, error: "claude-code: no result in the stream " \
                                                            "(exit #{finished.exit_code}): #{finished.output.to_s[0, 2000]}")
    end

    # A failed API call (bad credentials, overload) still reports "success"
    outcome = OUTCOMES[report["subtype"]] unless report["subtype"] == "success" && report["is_error"]
    usage = usage_for(report)
    raw_result = JSON.generate(report)
    unless outcome
      return Lemans::Agent::Response.new(usage:, raw_result:, artifacts:, error: report["result"] || report["subtype"])
    end

    Lemans::Agent::Response.new(outcome: Lemans::Result::Outcome.new(outcome), usage:, raw_result:, artifacts:)
  end

  private

  def command_for(task)
    argv = [ "claude", "-p", task.instruction, "--output-format", "stream-json", "--verbose", "--dangerously-skip-permissions",
             "--no-session-persistence", "--max-turns", profile.step_limit ]
    name, effort = model.to_s.split("#", 2)
    argv += [ "--model", name ] unless name.to_s.empty?
    argv += [ "--effort", effort ] if effort
    argv += [ "--max-budget-usd", profile.cost_limit ] if profile.cost_limit
    "#{PATH} cd #{Shellwords.escape(task.environment.workdir)} && #{argv.map { Shellwords.escape(it.to_s) }.join(" ")}"
  end

  def download_stream(environment)
    Tempfile.create(%w[claude .jsonl]) do |file|
      environment.download(STREAM_PATH, file.path)
      File.read(file.path)
    end
  rescue Lemans::InfrastructureError
    nil
  end

  # The session ends with a "result" event: outcome, usage, and cost
  def result_from(stream)
    stream.to_s.each_line.reverse_each do |line|
      event = JSON.parse(line)
      return event if event["type"] == "result"
    rescue JSON::ParserError
      next
    end
    nil
  end

  # IS_SANDBOX lets --dangerously-skip-permissions run as root
  def claude_env
    ENV.slice(*CREDENTIALS).merge("IS_SANDBOX" => "1", "DISABLE_AUTOUPDATER" => "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1")
  end

  def usage_for(report)
    tokens = report.fetch("usage", {})
    cached = tokens["cache_read_input_tokens"].to_i
    Lemans::Result::Usage.new(
      input_tokens: tokens["input_tokens"].to_i + cached + tokens["cache_creation_input_tokens"].to_i,
      output_tokens: tokens["output_tokens"].to_i,
      cached_tokens: cached,
      steps: report["num_turns"].to_i,
      cost_usd: report["total_cost_usd"],
      cost_source: Lemans::Result::CostSource.build(name: :claude_code, model: report.fetch("modelUsage", {}).keys.first)
    )
  end

  def unknown_usage = Lemans::Result::Usage.zero.with(cost_usd: nil)
end

Lemans::Agents.register(ClaudeCodeAgent::NAME, ClaudeCodeAgent)
