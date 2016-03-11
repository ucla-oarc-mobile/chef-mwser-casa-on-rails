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

# a few case-y things based on hostname
unless node['fqdn'] == 'casa.m.ucla.edu'
  fqdn = 'casa-staging.m.ucla.edu'
  app_name = 'staging'
  app_revision = 'master'
  rails_env = 'staging'
end

# install mysql
db_root_obj = ChefVault::Item.load("passwords", "db_root")
db_root = db_root_obj[node['fqdn']]
db_casa_obj = ChefVault::Item.load("passwords", "casa")
db_casa = db_casa_obj[fqdn]
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

# set up casa db
mysql2_chef_gem 'default'
mysql_database 'casa' do
  connection mysql_connection
  action :create
end
mysql_database_user 'casa' do
  connection mysql_connection
  password db_casa
  database_name 'casa'
  action [:create,:grant]
end

# install nginx
node.set['nginx']['default_site_enabled'] = false
node.set['nginx']['install_method'] = 'package'
include_recipe 'nginx::repo'
include_recipe 'nginx'

directory '/etc/ssl/private' do
  recursive true
end

# add SSL certs to box
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

# nginx conf
template '/etc/nginx/sites-available/casa' do
  source 'casa.conf.erb'
  mode '0775'
  action :create
  variables(
    fqdn: fqdn,
    port: 3001,
    path: '/var/www/', # not used.
  )
  notifies :reload, 'service[nginx]', :delayed
end
nginx_site 'casa' do
  action :enable
end

# install ruby with rbenv, npm, git
node.default['rbenv']['rubies'] = ['2.2.3']
include_recipe 'ruby_build'
include_recipe 'ruby_rbenv::system'
include_recipe 'nodejs::npm'
rbenv_global '2.2.3'
rbenv_gem 'bundle'

rails_secrets = ChefVault::Item.load('secrets', 'rails_secret_tokens')

# set up casa!
casa_on_rails app_name do
  revision app_revision
  port 3001
  secret rails_secrets[fqdn]
  db_password db_casa
  deploy_path '/var/casa'
  bundler_path '/usr/local/rbenv/shims'
  rails_env rails_env
  uuid '2663792f-0ae4-413f-94ef-bbf3fd0d7484'
  contact_name 'Rose Rocchio'
  contact_email 'rrocchio@oit.ucla.edu'
  # assumes es is available at localhost
end
