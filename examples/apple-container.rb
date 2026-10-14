# frozen_string_literal: true

# Apple Container (https://github.com/apple/container) as a lemans backend:
# every sandbox is a lightweight Linux VM on the Mac.
#
#   brew install container && container system start
#   lemans -r ./examples/apple-container.rb run --backend apple-container
#
# Apple Container cannot move a running container to another network, so the
# sandbox lives on its own host-only (--internal) network for its whole life.
# Its only way out is an HTTP proxy container attached to both that network
# and the default one; a network policy switch replaces the proxy:
#
# - public: the proxy lets every host through
# - allowlist: the proxy lets the listed hosts through
# - none: no proxy at all
#
# Limitations: traffic that ignores http(s)_proxy (raw TCP, ssh) never gets
# out, and an allowlist takes host names only.

require "json"
require "open3"
require "securerandom"

class AppleContainerEnvironment < Lemans::Environment
  NAME = "apple-container"

  PROXY_PORT = 3128

  attr_reader :container

  def initialize(image:, resources:, network:, env: {}, labels: {}, build_timeout: nil, ttl: nil)
    super(image:, resources:, network:, env:, labels:, ttl:, build_timeout: build_timeout || 600)
    @name = "lemans-#{SecureRandom.hex(6)}"
    assert_policy_supported!(network)
  end

  def start
    build_image!(image) if image.built?
    container!("network", "create", "--internal", *label_args, internal_network)
    start_proxy!(network)
    container!("run", *run_args, timeout: build_timeout)
    @container = @name
    self
  rescue Lemans::InfrastructureError => e
    stop
    raise Lemans::InfrastructureError, "apple-container: could not start the sandbox: #{e.message}"
  end

  def exec(command, timeout: nil, env: {})
    timeout ||= DEFAULT_TIMEOUT
    started = now
    env = proxy_env.merge(env)
    argv = [ "exec", *env.flat_map { |key, value| [ "--env", "#{key}=#{value}" ] },
             container, "timeout", timeout.to_i.to_s, "bash", "-c", command ]
    exit_code, output = capture(*argv, timeout: timeout + 30)
    ExecResult.new(command:, exit_code:, output:, duration: (now - started).round(3))
  end

  def upload(local_path, remote_path) = container!("cp", local_path.to_s, "#{container}:#{remote_path}")

  def download(remote_path, local_path) = container!("cp", "#{container}:#{remote_path}", local_path.to_s)

  def switch_network_policy!(policy)
    assert_policy_supported!(policy)
    remove_proxy
    start_proxy!(policy)
    @network = policy
  end

  def stop
    capture("rm", "--force", @name, timeout: 60)
    remove_proxy
    capture("network", "rm", internal_network, timeout: 60)
    @container = nil
  end

  private

  def assert_policy_supported!(policy)
    return unless policy.allowlist? && policy.ip_targets.any?

    raise Lemans::ConfigError, "apple-container: an allowlist takes host names only (#{policy.ip_targets.join(", ")})"
  end

  def run_args
    [ "--detach", "--init", "--name", @name, "--network", internal_network,
      "--cpus", resources.cpus.to_s, "--memory", "#{resources.memory}M",
      "--cap-add", "SYS_ADMIN", "--cap-add", "NET_ADMIN",
      *env.flat_map { |key, value| [ "--env", "#{key}=#{value}" ] }, *label_args,
      "--entrypoint", "sh", image.name, "-c", "tail -f /dev/null" ]
  end

  def build_image!(spec)
    return if capture("image", "inspect", spec.name, timeout: 60).first.zero?

    container!("build", "--tag", spec.name, "--file", spec.dockerfile_path.to_s, spec.context_dir.to_s,
               timeout: build_timeout)
  end

  def start_proxy!(policy)
    @proxy_ip = nil
    return if policy.none?

    build_image!(Lemans::Environments::Docker.proxy_image)
    hosts = policy.public? ? [ "*" ] : policy.domains
    container!("run", "--detach", "--name", proxy_name, "--network", "default", "--network", internal_network,
               *label_args, Lemans::Environments::Docker.proxy_image.name, *hosts)
    wait_for_proxy!
    @proxy_ip = proxy_address
  end

  def wait_for_proxy!(attempts: 50)
    attempts.times do
      return if capture("logs", proxy_name, timeout: 60).last.include?("listening on")

      sleep 0.2
    end
    raise Lemans::InfrastructureError, "apple-container: the proxy did not start"
  end

  def proxy_address
    status = JSON.parse(container!("inspect", proxy_name)).first.fetch("status")
    status.fetch("networks").find { it["network"] == internal_network }.fetch("ipv4Address").split("/").first
  end

  def proxy_env
    return {} unless @proxy_ip

    url = "http://#{@proxy_ip}:#{PROXY_PORT}"
    no_proxy = "localhost,127.0.0.1"
    { "http_proxy" => url, "https_proxy" => url, "HTTP_PROXY" => url, "HTTPS_PROXY" => url,
      "no_proxy" => no_proxy, "NO_PROXY" => no_proxy }
  end

  def remove_proxy = capture("rm", "--force", proxy_name, timeout: 60)

  def proxy_name = "#{@name}-proxy"

  def internal_network = "#{@name}-net"

  def label_args = labels.flat_map { |key, value| [ "--label", "#{key}=#{value}" ] }

  def container!(*argv, timeout: 60)
    exit_code, output = capture(*argv, timeout:)
    return output if exit_code.zero?

    raise Lemans::InfrastructureError, "container #{argv.first(2).join(" ")} exited #{exit_code}: #{output[0, 2000]}"
  end

  def capture(*argv, timeout:)
    Open3.popen2e("container", *argv) do |stdin, out, wait|
      stdin.close
      reader = Thread.new { out.read }
      next [ wait.value.exitstatus || 1, reader.value.to_s.scrub ] if wait.join(timeout)

      Process.kill("KILL", wait.pid)
      wait.join
      [ 124, reader.value.to_s.scrub ]
    end
  rescue Errno::ENOENT
    raise Lemans::ConfigError, "apple-container: the container CLI is not installed (brew install container)"
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

Lemans::Environments.register(AppleContainerEnvironment::NAME, AppleContainerEnvironment)
