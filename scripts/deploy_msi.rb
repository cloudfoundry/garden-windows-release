#!/usr/bin/env ruby

require 'net/ssh'
require 'net/ssh/gateway'

DEPLOYMENTS_RUNTIME = ENV['DEPLOYMENTS_RUNTIME'] or raise "Please set env var DEPLOYMENTS_RUNTIME"
ADMIN_PASS = ENV['ADMIN_PASS'] or raise "Please set env var ADMIN_PASS"
JUMP_MACHINE_IP = ENV['JUMP_MACHINE_IP']
MACHINE_IP = ENV['MACHINE_IP'] or raise "Please set env var MACHINE_IP"
CONSUL_IPS = ENV['CONSUL_IPS'] or raise "Please set env var CONSUL_IPS"
ETCD_CLUSTER = ENV['ETCD_CLUSTER'] or raise "Please set env var ETCD_CLUSTER"
CF_ETCD_CLUSTER = ENV['CF_ETCD_CLUSTER'] or raise "Please set env var CF_ETCD_CLUSTER"
ZONE = ENV['ZONE'] or raise "Please set env var ZONE"

options = {
  auth_methods: ["publickey"],
  use_agent: false,
  keys: ["#{DEPLOYMENTS_RUNTIME}/keypair/id_rsa_bosh"]
}

# Figure out the sha of the msi being installed using the download url
# or GO_REVISION_DIEGO_WINDOWS_MSI environment variable. The env.
# variable is set by gocd since diego-windows-msi is one of the
# Materials in the gocd job.
def expected_sha
  if sha_env = ENV['GO_REVISION_DIEGO_WINDOWS_MSI']
    sha_env
  elsif msi_download_url =~ /DiegoWindowsMSI-([0-9a-f]+).msi$/
    $1
  else
    raise "Pass either a download url or set GO_REVISION_DIEGO_WINDOWS_MSI"
  end
end


# Return the msi download url, using either the first argument or the
# GO_DEPENDENCY_LABEL_DIEGOMSI environment variable (which is the gocd
# job id of the last DiegoWindowsMSI build)
def msi_download_url
  url = ARGV[0]
  # return the argument if it was provided and is valid
  return url if url && url =~ /^http/

  job_id = ENV['GO_DEPENDENCY_LABEL_DIEGOMSI'] or raise  "Usage: $0 http://path/to/msi"
  "https://s3.amazonaws.com/diego-windows-msi/DiegoMSI/defaultStage/defaultJob/#{job_id}.1/DiegoWindowsMSI-#{expected_sha}.msi"
end

msi_location="c:\\diego.msi"
block = ->(ssh) do
  hostname = ssh.exec!("hostname").chomp
  puts "Hostname: #{hostname}"

  puts "Uninstall"
  puts ssh.exec!("msiexec /norestart /passive /x #{msi_location}")
  ssh.exec!("del /Y #{msi_location}")

  puts "Download"
  puts ssh.exec!("powershell /C wget #{msi_download_url} -OutFile #{msi_location}")

  puts "Install"
  puts ssh.exec!("msiexec /norestart /passive /i #{msi_location} CONTAINERIZER_USERNAME=.\\Administrator CONTAINERIZER_PASSWORD=#{ADMIN_PASS} EXTERNAL_IP=#{MACHINE_IP} CONSUL_IPS=#{CONSUL_IPS} ETCD_CLUSTER=#{ETCD_CLUSTER} CF_ETCD_CLUSTER=#{CF_ETCD_CLUSTER} LOGGREGATOR_SHARED_SECRET=loggregator-secret MACHINE_NAME=#{hostname} STACK=windows2012R2 ZONE=#{ZONE}")

  output = ssh.exec!("powershell /C type $Env:ProgramW6432/CloudFoundry/DiegoWindows/RELEASE_SHA")
  actual_sha = output.chomp.split(/\s+/).last
  puts actual_sha.inspect

  if actual_sha != expected_sha
    puts "Installation failed: expected #{expected_sha}, got #{actual_sha}"
    exit(1)
  end
  puts "Installation succeeded, #{expected_sha} == #{actual_sha}"
end

if JUMP_MACHINE_IP
  gateway = Net::SSH::Gateway.new(JUMP_MACHINE_IP, 'ec2-user', options)
  gateway.ssh(MACHINE_IP, "ci", options, &block)
else
  Net::SSH.start(MACHINE_IP, "ci", options, &block)
end