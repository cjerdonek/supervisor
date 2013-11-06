#
# Cookbook Name:: supervisor
# Recipe:: default
#
# Copyright 2011, Opscode, Inc.
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

supported_platforms = %w(debian smartos ubuntu)

if !supported_platforms.include? node['platform']
  if !node['supervisor']['support_required']
    Chef::Log.info "Skipping supervisor recipe: platform #{node['platform']} " \
                     "not supported and support_required set to false"
    return
  end
  Chef::Application.fatal! "The supervisor recipe does not support platform " \
    "#{node['platform']}. You can skip this recipe by setting " \
    "node['supervisor']['support_required'] to false or use one of: " \
    "#{supported_platforms.join(", ")}"
end

include_recipe "python"

# foodcritic FC023: we prefer not having the resource on non-smartos
if platform_family?("smartos")
  package "py27-expat" do
    action :install
  end
end

# Until pip 1.4 drops, see https://github.com/pypa/pip/issues/1033
python_pip "setuptools" do
  only_if do
    cmd = "pip --version"
    version = `#{cmd}`.strip
    Chef::Log.debug "#{cmd}: '#{version}'"
    parts = version.split[1].split(".")
    version = "#{parts[0]}.#{parts[1]}".to_f
    do_upgrade = version < 1.4
    if do_upgrade
      Chef::Log.warn "pip version '#{version}': are you using an old version?"
    end
    do_upgrade
  end
  action :upgrade
end

python_pip "supervisor" do
  action :upgrade
  version node['supervisor']['version'] if node['supervisor']['version']
end

directory node['supervisor']['dir'] do
  owner "root"
  group "root"
  mode "755"
end

directory node['supervisor']['log_dir'] do
  owner "root"
  group "root"
  mode "755"
  recursive true
end

template "/etc/default/supervisor" do
  source "debian/supervisor.default.erb"
  owner "root"
  group "root"
  mode "644"
  only_if { platform_family?("debian") }
end

service_name = "supervisor"
service_actions = [:enable, :start]
service_supports = { :status => true, :restart => true }

init_template_dir = value_for_platform_family(
  ["rhel", "fedora"] => "rhel",
  "debian" => "debian"
)

if node['platform'] != "smartos"
  template "/etc/init.d/supervisor" do
    source "#{init_template_dir}/supervisor.init.erb"
    owner "root"
    group "root"
    mode "755"
    variables({
      # TODO: use this variable in the debian platform-family template
      # instead of altering the PATH and calling "which supervisord".
      :supervisord => "#{node['python']['prefix_dir']}/bin/supervisord"
    })
  end

else
  service_name = "supervisord"
  service_actions = [:enable]
  service_supports = nil

  directory "/opt/local/share/smf/supervisord" do
    owner "root"
    group "root"
    mode "755"
  end

  template "/opt/local/share/smf/supervisord/manifest.xml" do
    source "manifest.xml.erb"
    owner "root"
    group "root"
    mode "644"
    notifies :run, "execute[svccfg-import-supervisord]", :immediately
  end

  execute "svccfg-import-supervisord" do
    command "svccfg import /opt/local/share/smf/supervisord/manifest.xml"
    action :nothing
  end

end

# We create the conf file after the init.d script because changes to the
# conf file template trigger the reload action on the service.  If the init.d
# script hasn't been created yet, we get an error like the following:
#
#   service[supervisord]: unable to locate the init.d script!
#
supervisor_conf_template = template node['supervisor']['conffile'] do
  source "supervisord.conf.erb"
  owner "root"
  group "root"
  mode "644"
  variables({
    :inet_port => node['supervisor']['inet_port'],
    :inet_username => node['supervisor']['inet_username'],
    :inet_password => node['supervisor']['inet_password'],
    :supervisord_minfds => node['supervisor']['minfds'],
    :supervisord_minprocs => node['supervisor']['minprocs'],
    :supervisor_version => node['supervisor']['version'],
  })
end

# We structured things so that if a reload is needed because of a
# configuration file change, it occurs before the start issued below.
# Also note that the reload action for Chef's service resource does nothing
# if the service is not started, which is fine since the start action
# below will occur after anyways (loading the new config in the process).
#
# For the purposes of cross-checking the implementation and behavior of
# the Chef service resource, I believe amazon and centos use the default
# provider: Chef::Provider::Service::Init.
service service_name do
  if !service_supports.nil?
    supports service_supports
  end
  action service_actions
  # The service provider base class Chef::Provider::Service raises
  # an UnsupportedAction in its reload_service method, so we check for
  # reload support in advance.
  if supports[:reload]
    subscribes :reload, "#{supervisor_conf_template}", :immediately
  elsif supports[:restart]
    subscribes :restart, "#{supervisor_conf_template}", :immediately
  end
end
