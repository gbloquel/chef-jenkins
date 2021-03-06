#
# Cookbook Name:: jenkins
# Based on hudson
# Recipe:: default
#
# Author:: AJ Christensen <aj@junglist.gen.nz>
# Author:: Doug MacEachern <dougm@vmware.com>
# Author:: Fletcher Nichol <fnichol@nichol.ca>
#
# Copyright 2010, VMware, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Install sshkey gem into chef
chef_gem "sshkey"

pkey = "#{node['jenkins']['server']['home']}/.ssh/id_rsa"
tmp = "/tmp"

user node['jenkins']['server']['user'] do
  home node['jenkins']['server']['home']
  shell "/bin/bash"
end

directory node['jenkins']['server']['home'] do
  recursive true
  owner node['jenkins']['server']['user']
  group node['jenkins']['server']['group']
end

directory "#{node['jenkins']['server']['home']}/.ssh" do
  mode 0700
  owner node['jenkins']['server']['user']
  group node['jenkins']['server']['group']
end

# Generate and deploy ssh public/private keys
Gem.clear_paths
require 'sshkey'
sshkey = SSHKey.generate(:type => 'RSA', :comment => "#{node['jenkins']['server']['user']}@#{node['fqdn']}")
node.set_unless['jenkins']['server']['pubkey'] = sshkey.ssh_public_key
    
# Save public_key to node, unless it is already set.
ruby_block "save node data" do
  block do
    node.save unless Chef::Config['solo']
  end
  action :create
end

# Save private key, unless pkey file exists
template pkey do
  owner  node['jenkins']['server']['user']
  group node['jenkins']['server']['group']
  variables( :ssh_private_key => sshkey.private_key )
  mode 0600
  not_if { File.exists?("#{node['jenkins']['server']['home']}/.ssh/id_rsa") }
end

# Template public key out to pkey.pub file
template "#{pkey}.pub" do
  owner  node['jenkins']['server']['user']
  group node['jenkins']['server']['group']
  mode 0644
end

directory "#{node['jenkins']['server']['home']}/plugins" do
  owner node['jenkins']['server']['user']
  group node['jenkins']['server']['group']
  only_if { node['jenkins']['server']['plugins'].size > 0 }
end

node['jenkins']['server']['plugins'].each do |name|
  remote_file "#{node['jenkins']['server']['home']}/plugins/#{name}.hpi" do
    source "#{node['jenkins']['mirror']}/plugins/#{name}/latest/#{name}.hpi"
    backup false
    owner node['jenkins']['server']['user']
    group node['jenkins']['server']['group']
    action :create_if_missing
  end
end

include_recipe "java"

case node['platform']
when "ubuntu", "debian"
  include_recipe "apt"

  apt_repository "jenkins" do
    uri "#{node['jenkins']['package_url']}/debian"
    components %w[binary/]
    key "http://pkg.jenkins-ci.org/debian/jenkins-ci.org.key"
    action :add
  end
when "centos", "redhat", "centos", "scientific", "amazon"
  include_recipe "yumrepo::jenkins"
end

#"jenkins stop" may (likely) exit before the process is actually dead
#so we sleep until nothing is listening on jenkins.server.port (according to netstat)
ruby_block "netstat" do
  block do
    10.times do
      if IO.popen("netstat -lnt").entries.select { |entry|
          entry.split[3] =~ /:#{node['jenkins']['server']['port']}$/
        }.size == 0
        break
      end
      Chef::Log.debug("service[jenkins] still listening (port #{node['jenkins']['server']['port']})")
      sleep 1
    end
  end
  action :nothing
end

service "jenkins" do
  supports [ :stop, :start, :restart, :status ]
  status_command "test -f #{node['jenkins']['pid_file']} && kill -0 `cat #{node['jenkins']['pid_file']}`"
  action :nothing
end

ruby_block "block_until_operational" do
  block do
    until IO.popen("netstat -lnt").entries.select { |entry|
        entry.split[3] =~ /:#{node['jenkins']['server']['port']}$/
      }.size == 1
      Chef::Log.debug "service[jenkins] not listening on port #{node['jenkins']['server']['port']}"
      sleep 1
    end

    loop do
      url = URI.parse("#{node['jenkins']['server']['url']}/job/test/config.xml")
      res = Chef::REST::RESTRequest.new(:GET, url, nil).call
      break if res.kind_of?(Net::HTTPSuccess) or res.kind_of?(Net::HTTPNotFound)
      Chef::Log.debug "service[jenkins] not responding OK to GET / #{res.inspect}"
      sleep 1
    end
  end
  action :nothing
end

log "jenkins: install and start" do
  notifies :install, "package[jenkins]", :immediately
  notifies :start, "service[jenkins]", :immediately unless node['jenkins']['install_starts_service']
  notifies :create, "ruby_block[block_until_operational]", :immediately
  not_if do
    File.exists? "/usr/share/jenkins/jenkins.war"
  end
end

case node['platform']
when "ubuntu", "debian"
	template "/etc/default/jenkins"
when "centos", "redhat", "suse", "fedora", "scientific", "amazon"
	template "/etc/sysconfig/jenkins" do
		source jenkins-rh.erb
	end
end


package "jenkins"

# restart if this run only added new plugins
log "plugins updated, restarting jenkins" do
  #ugh :restart does not work, need to sleep after stop.
  notifies :stop, "service[jenkins]", :immediately
  notifies :create, "ruby_block[netstat]", :immediately
  notifies :start, "service[jenkins]", :immediately
  notifies :create, "ruby_block[block_until_operational]", :immediately
  only_if do
    if File.exists?(node['jenkins']['pid_file'])
      htime = File.mtime(node['jenkins']['pid_file'])
      Dir["#{node['jenkins']['server']['home']}/plugins/*.hpi"].select { |file|
        File.mtime(file) > htime
      }.size > 0
    end
  end
  action :nothing
end

# Front Jenkins with an HTTP server
case node['jenkins']['http_proxy']['variant']
when "nginx", "apache2"
  include_recipe "jenkins::proxy_#{node['jenkins']['http_proxy']['variant']}"
end

if node['jenkins']['iptables_allow'] == "enable"
  include_recipe "iptables"
  iptables_rule "port_jenkins" do
    if node['jenkins']['iptables_allow'] == "enable"
      enable true
    else
      enable false
    end
  end
end
