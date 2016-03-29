#
# Cookbook Name:: mwser-casa-on-rails
# Recipe:: default
#
# Copyright (C) 2015 UC Regents
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# require chef-vault
chef_gem 'chef-vault'
require 'chef-vault'

package 'git'

# install ruby with rbenv, npm, git
node.default['rbenv']['rubies'] = ['2.2.3']
include_recipe 'ruby_build'
include_recipe 'ruby_rbenv::system'
include_recipe 'nodejs::npm'
rbenv_global '2.2.3'
rbenv_gem 'bundle'

# install mysql
db_root_obj = ChefVault::Item.load("passwords", "db_root")
db_root = db_root_obj[node['fqdn']]
db_casa_obj = ChefVault::Item.load("passwords", "casa")

mysql_service 'default' do
  port '3306'
  version '5.6'
  initial_root_password db_root
  action [:create, :start]
end
mysql_connection = {
  :host => '127.0.0.1',
  :port => 3306,
  :username => 'root',
  :password => db_root
}
mysql2_chef_gem 'default'

# install nginx
node.set['nginx']['default_site_enabled'] = false
node.set['nginx']['install_method'] = 'package'
include_recipe 'nginx::repo'
include_recipe 'nginx'

directory '/etc/ssl/private' do
  recursive true
end

rails_secrets = ChefVault::Item.load('secrets', 'rails_secret_tokens')

casa_instances = [
  { name: 'open', fqdn: 'open.apps.ucla.edu', contact_name: 'Joshua Selsky', contact_email: 'jselsky@oit.ucla.edu', uuid: 'da782175-1a9e-46ef-ae44-c088d34606f3' }
]

casa_instances.each_with_index do |c, i|
  # a few instance variables
  port = 3000 + i
  fqdn = c[:fqdn]
  db_pw = db_casa_obj[fqdn]
  app_name = "casa-#{c[:name]}"

  # setup database
  mysql_database app_name do
    connection mysql_connection
    action :create
  end
  mysql_database_user app_name do
    connection mysql_connection
    password db_pw
    database_name app_name
    action [:create,:grant]
  end
  
  # add SSL certs to box (if they exist)
  begin
    ssl_key_cert = ChefVault::Item.load('ssl', fqdn) # gets ssl cert from chef-vault
    file "/etc/ssl/certs/#{fqdn}.crt" do
      owner 'root'
      group 'root'
      mode '0777'
      content ssl_key_cert['cert']
      notifies :reload, 'service[nginx]', :delayed
    end
    file "/etc/ssl/private/#{fqdn}.key" do
      owner 'root'
      group 'root'
      mode '0600'
      content ssl_key_cert['key']
      notifies :reload, 'service[nginx]', :delayed
    end
    ssl_enabled = true
  rescue ChefVault::Exceptions::KeysNotFound # untested.
    Chef::Log.info("No SSL certs available for #{fqdn}, continuing without SSL support for this instance")
    ssl_enabled = false
  end
  
  # nginx conf
  template "/etc/nginx/sites-available/#{app_name}" do
    source 'casa.conf.erb'
    mode '0775'
    action :create
    variables(
      fqdn: fqdn,
      port: port,
      app_name: app_name,
      ssl_enabled: ssl_enabled
    )
    notifies :reload, 'service[nginx]', :delayed
  end
  nginx_site app_name do
    action :enable
  end
  
  # set up casa!
  casa_on_rails c[:name] do
    revision c[:revision] if c[:revision]
    port port
    secret rails_secrets[fqdn]
    db_name app_name
    db_user app_name
    db_password db_pw
    es_index app_name
    deploy_path "/var/#{app_name}"
    bundler_path '/usr/local/rbenv/shims'
    rails_env 'production'
    uuid c[:uuid]
    contact_name c[:contact_name]
    contact_email c[:contact_email]
    # assumes es is available at localhost
  end
end
