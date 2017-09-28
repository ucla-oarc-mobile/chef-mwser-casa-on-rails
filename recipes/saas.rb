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
caliper_api = ChefVault::Item.load('secrets', 'caliper_api')

casa_instances = [
  { name: 'open', fqdn: 'open.apps.ucla.edu', revision: '1.2.6', contact_name: 'Joshua Selsky', contact_email: 'jselsky@oit.ucla.edu', uuid: 'da782175-1a9e-46ef-ae44-c088d34606f3' },
  { name: 'imsglobal', fqdn: 'casa.imsglobal.org', revision: '1.2.6', contact_name: 'Lisa Mattson', contact_email: 'lmattson@imsglobal.org', uuid: '60b89d1d-acf7-4275-9a0a-f694a2393ab2' },
  { name: 'umbc', fqdn: 'umbc.apps.ucla.edu', revision: '1.2.6', contact_name: 'Joshua Selsky', contact_email: 'jselsky@oit.ucla.edu', uuid: '24b72770-bdfa-402b-af47-56bcab72586c' },
  { name: 'ucsd', fqdn: 'ucsd.apps.ucla.edu', revision: '1.2.6', contact_name: 'Jeff Henry', contact_email: 'pjhenry@ucsd.edu', uuid: 'ee3e7562-d7ba-4bd8-b9dc-b916babc28d4' },
  { name: 'berkeley', fqdn: 'berkeley.apps.ucla.edu', revision: '1.2.6', contact_name: 'Sara Leavitt', contact_email: 'saral@berkeley.edu', uuid: '069624c7-d547-48ea-8dfa-3ffb989efb52' },
  { name: 'demo', fqdn: 'demo.apps.ucla.edu', revision: '1.2.6', contact_name: 'Rose Rocchio', contact_email: 'rrocchio@oit.ucla.edu', uuid: '79847ad5-0de1-4bd2-ac74-27c582755b21' },
  { name: 'ucsc', fqdn: 'ucsc.apps.ucla.edu', revision: '1.2.6', contact_name: 'Charles McIntyre', contact_email: 'mcintyre@ucsc.edu', uuid: 'fcfac792-acf5-423e-befd-19e8af05c79e' },
  { name: 'caliper', fqdn: 'caliper.apps.ucla.edu', revision: '1.2.0-caliper', contact_name: 'Rose Rocchio', contact_email: 'rrocchio@oit.ucla.edu', uuid: '79847ad5-0de1-4bd2-ac74-27c582755b33'},
  { name: 'ucf', fqdn: 'ucf.apps.ucla.edu', revision: '1.2.6', contact_name: 'Shea Silverman', contact_email: 'shea.silverman@ucf.edu', uuid: 'c8ab0623-1cfb-4c66-a797-eebbe5feef97'},
  { name: 'ucr', fqdn: 'ucr.apps.ucla.edu', revision: '1.2.6', contact_name: 'Rose Rocchio', contact_email: 'rrocchio@oit.ucla.edu', uuid: 'd91435fb-cb17-40e5-b4c8-d0f4afb7d1f2'},
  { name: 'ccle', fqdn: 'ccle.apps.ucla.edu', revision: '1.2.6', contact_name: 'Rose Rocchio', contact_email: 'rrocchio@oit.ucla.edu', uuid: '058e4b77-d990-49e5-8381-55645374c6c2'}
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
  

# For using strong DH group to prevent Logjam attack
execute "openssl-dhparam" do
  command "openssl dhparam -out /etc/nginx/dhparams.pem 2048"
  ignore_failure true
  not_if { ::File.exist?('/etc/nginx/dhparams.pem') }
end

#add "ssl_dhparam /etc/nginx/dhparams.pem;" to "/etc/nginx/nginx.conf"
template '/etc/nginx/nginx.conf' do
  source 'casa-nginx.conf.erb'
  mode '0644'
  action :create
  variables(
    fqdn: fqdn,
    path: '/var/www/', # not used.
  )
  notifies :reload, 'service[nginx]', :delayed
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
    caliper_url 'http://dev1.intellifylearning.com/v1custom/eventdata' if c[:name] == 'caliper'
    caliper_sensor_id '89535BDD-F345-45C0-9851-5E08FC1C016E' if c[:name] == 'caliper'
    caliper_api_key caliper_api[fqdn] if c[:name] == 'caliper'
    # assumes es is available at localhost
  end
end
