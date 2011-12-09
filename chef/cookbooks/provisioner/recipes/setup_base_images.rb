# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied
# See the License for the specific language governing permissions and
# limitations under the License
#

package "syslinux"

# Set up the OS images as well
# Common to all OSes
admin_ip = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin").address
domain_name = node[:dns].nil? ? node[:domain] : (node[:dns][:domain] || node[:domain])
web_port = node[:provisioner][:web_port]
use_local_security = node[:provisioner][:use_local_security]

append_line = "append initrd=initrd0.img root=/sledgehammer.iso rootfstype=iso9660 rootflags=loop"

tftproot = node[:provisioner][:root]

if node[:provisioner][:use_serial_console]
  append_line += " console=tty0 console=ttyS1,115200n8"
end
if ::File.exists?("/etc/crowbar.install.key")
  append_line += " crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip}"
end

pxecfg_dir="#{tftproot}/discovery/pxelinux.cfg"

# Generate the appropriate pxe config file for each state
[ "discovery","update","hwinstall"].each do |state|
  template "#{pxecfg_dir}/#{state}" do
    mode 0644
    owner "root"
    group "root"
    source "default.erb"
    variables(:append_line => "#{append_line} crowbar.state=#{state}",
              :install_name => state,  
              :kernel => "vmlinuz0")
  end
end

# and the execute state as well
cookbook_file "#{pxecfg_dir}/execute" do
  mode 0644
  owner "root"
  group "root"
  source "localboot.default"
end

# Make discovery our default state
link "#{pxecfg_dir}/default" do
  to "discovery"
end

include_recipe "bluepill"

package "nginx"

service "nginx" do
  action :disable
end

link "/etc/nginx/sites-enabled/default" do
  action :delete
end

# Set up our the webserver for the provisioner.
file "/var/log/provisioner-webserver.log" do
  owner "nobody"
  action :create
end

template "/etc/nginx/provisioner.conf" do
  source "base-nginx.conf.erb"
  variables(:docroot => "/tftpboot",
            :port => 8091,
            :logfile => "/var/log/provisioner-webserver.log",
            :pidfile => "/var/run/provisioner-webserver.pid")
end

bluepill_service "provisioner-webserver" do
  variables(:processes => [ {
                              "daemonize" => false,
                              "pid_file" => "/var/run/provisioner-webserver.pid",
                              "start_command" => "nginx -c /etc/nginx/provisioner.conf",
                              "stderr" => "/var/log/provisioner-webserver.log",
                              "stdout" => "/var/log/provisioner-webserver.log",
                              "name" => "provisioner-webserver"
                            } ] )
  action [:create, :load]
end

# Set up the TFTP server as well.
case node[:platform]
when "ubuntu", "debian"
  package "tftpd-hpa"
  bash "stop ubuntu tftpd" do
    code "service tftpd-hpa stop; killall in.tftpd; rm /etc/init/tftpd-hpa.conf"
    only_if "test -f /etc/init/tftpd-hpa.conf"
  end
when "redhat","centos"
  package "tftp-server"
end

bluepill_service "tftpd" do
  variables(:processes => [ {
                              "daemonize" => true,
                              "start_command" => "in.tftpd -4 -L -a 0.0.0.0:69 -s #{tftproot}",
                              "stderr" => "/dev/null",
                              "stdout" => "/dev/null",
                              "name" => "tftpd"
                            } ] )
  action [:create, :load]
end

bash "copy validation pem" do
  code <<-EOH
  cp /etc/chef/validation.pem #{tftproot}
  chmod 0444 #{tftproot}/validation.pem
EOH
  not_if "test -f #{tftproot}/validation.pem"  
end
case node[:platform]
when "ubuntu","debian"
  directory "#{tftproot}/curl"
  
  [ "/usr/bin/curl",
    "/usr/lib/libcurl.so.4",
    "/usr/lib/libidn.so.11",
    "/usr/lib/liblber-2.4.so.2",
    "/usr/lib/libldap_r-2.4.so.2",
    "/usr/lib/libgssapi_krb5.so.2",
    "/usr/lib/libssl.so.0.9.8",
    "/usr/lib/libcrypto.so.0.9.8",
    "/usr/lib/libsasl2.so.2",
    "/usr/lib/libgnutls.so.26",
    "/usr/lib/libkrb5.so.3",
    "/usr/lib/libk5crypto.so.3",
    "/usr/lib/libkrb5support.so.0",
    "/lib/libkeyutils.so.1",
    "/usr/lib/libtasn1.so.3",
    "/lib/librt.so.1",
    "/lib/libcom_err.so.2",
    "/lib/libgcrypt.so.11",
    "/lib/libgpg-error.so.0"
  ].each { |file|
    basefile = file.gsub("/usr/bin/", "").gsub("/usr/lib/", "").gsub("/lib/", "")
    bash "copy #{file} to curl dir" do
      code "cp #{file} #{tftproot}/curl"
      not_if "test -f #{tftproot}/curl/#{basefile}"
    end  
  }
end

# By default, install the same OS that the admin node is running
# If the comitted proposal has a defualt, try it.
# Otherwise use the OS the provisioner node is using.

unless default_os = node[:provisioner][:default_os]
  node[:provisioner][:default_os] = default = "#{node[:platform]}-#{node[:platform_version]}"
  node.save
end
                                
known_oses = node[:provisioner][:supported_oses] || \
             [ "redhat-5.6", "redhat-5.7", "centos-5.7","ubuntu-10.10" ]
known_oses.each do |os|
 
  append = ""
  initrd = ""
  kernel = ""
  web_path = "http://#{admin_ip}:#{web_port}/#{os}"
  admin_web="#{web_path}/install"
  crowbar_repo_web="#{web_path}/crowbar-extra"
  os_dir="#{tftproot}/#{os}"
  role="#{os}_install"

  # Don't bother for OSes that are not actaully present on the provisioner node.
  next unless File.directory? os_dir and File.directory? "#{os_dir}/install"

  if node["provisioner"]["deployable_oses"] and \
     node["provisioner"]["deployable_oses"][os]
    # If we have a deployable_oses entry for this OS, use it.
    append = node["provisioner"]["deployable_oses"][os]["append"]
    initrd = node["provisioner"]["deployable_oses"][os]["initrd"]
    kernel = node["provisioner"]["deployable_oses"][os]["kernel"]
    role = node["provisioner"]["deployable_oses"][os]["role"]
  else
    # Set some defaults for deployable_oses for this OS.
    if node[:provisioner][:use_serial_console]
      append << " console=tty0 console=ttyS1,115200n8 "
    end
    if ::File.exists?("/etc/crowbar.install.key")
      append << "crowbar.install.key=#{::File.read("/etc/crowbar.install.key").chomp.strip} "
    end
    case
    when /^(redhat|centos)/ =~ os
      initrd="images/pxeboot/initrd.img"
      kernel="images/pxeboot/vmlinuz"
      append << " method=#{admin_web} ks=#{web_path}/compute.ks ksdevice=bootif"
    when /^ubuntu/ =~ os
      append << " url=#{web_path}/net_seed debian-installer/locale=en_US.utf8 console-setup/layoutcode=us localechooser/translation/warn-light=true localechooser/translation/warn-severe=true netcfg/dhcp_timeout=120 netcfg/choose_interface=auto netcfg/get_hostname=\"redundant\" root=/dev/ram rw quiet --"
      initrd = "install/netboot/ubuntu-installer/amd64/initrd.gz"
      kernel = "install/netboot/ubuntu-installer/amd64/linux"
    end
  end

  # These should really be made libraries or something.
  case
  when /^(redhat|centos)/ =~ os
    # Default kickstarts and crowbar_join scripts for redhat.
    template "#{os_dir}/compute.ks" do
      mode 0644
      source "compute.ks.erb"
      owner "root"
      group "root"
      variables(
                :admin_node_ip => admin_ip,
                :web_port => web_port,
                :os_repo => "#{admin_web}/Server",
                :crowbar_repo => crowbar_repo_web,
                :admin_web => admin_web,
                :crowbar_join => "#{web_path}/crowbar_join.sh")  
    end
      
    template "#{os_dir}/crowbar_join.sh" do
      mode 0644
      owner "root"
      group "root"
      source "crowbar_join.redhat.sh.erb"
      variables(:admin_ip => admin_ip)
    end

  when /^ubuntu/ =~ os
    # Default files needed for Ubuntu.
    template "#{os_dir}/net_seed" do
      mode 0644
      owner "root"
      group "root"
      source "net_seed.erb"
      variables(:install_name => os,  
                :cc_use_local_security => use_local_security,
                :cc_install_web_port => web_port,
                :cc_built_admin_node_ip => admin_ip,
                :install_path => "#{os}/install")
    end
    
    cookbook_file "#{os_dir}/net-post-install.sh" do
      mode 0644
      owner "root"
      group "root"
      source "net-post-install.sh"
    end
    
    cookbook_file "#{os_dir}/net-pre-install.sh" do
      mode 0644
      owner "root"
      group "root"
      source "net-pre-install.sh"
    end

    template "#{os_dir}/crowbar_join.sh" do
      mode 0644
      owner "root"
      group "root"
      source "crowbar_join.ubuntu.sh.erb"
      variables(:admin_ip => admin_ip)
    end
  end
  
  # Save this OS config if we need to.
  node[:provisioner][:deployable_oses] ||= Mash.new
  node[:provisioner][:deployable_oses][os] ||= {
    :kernel => kernel,
    :append => append,
    :initrd => initrd,
    :role => "#{os}_install"
  }

  # Create the pxe linux config for this OS.
  template "#{pxecfg_dir}/#{role}" do
    mode 0644
    owner "root"
    group "root"
    source "default.erb"
    variables(:append_line => "append initrd=../#{os}/install/#{initrd} " + append,
              :install_name => os,  
              :kernel => "../#{os}/install/#{kernel}")
  end
  
  # If this is our default, create the appropriate symlink.
  if os == default_os
    link "#{pxecfg_dir}/os_install" do
      link_type :symbolic
      to "#{role}"
    end
  end
end
# Save this node config.
node.save
