# Copyright 2015, Greg Althaus
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
#  http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
# 

require 'rest-client'
require 'uri'

class BarclampDns::MgmtService < Service

  def do_transition(nr,data)
    wait_for_service(nr, data, 'dns-mgmt-service')
    deployment_role = nr.deployment_role
    until Attrib.get('dns-management-servers',deployment_role) do
      sleep 1
      deployment_role.reload
    end
  end

  def on_active(nr)
    # Preset all the pre-existing allocations.
    NetworkAllocation.all.each do |na|
      DnsNameFilter.claim_by_any(na)
    end
  end

  def on_node_change(n)
    NetworkAllocation.node(n).each do |na|
      DnsNameFilter.claim_by_any(na)
    end
  end

  def on_network_allocation_create(na)
    DnsNameFilter.claim_by_any(na)
  end

  def on_network_allocation_delete(na)
    DnsNameEntry.for_network_allocation(na).each do |dne|
      dne.destroy!
    end
  end

  def self.get_service(service_name)
    service = nil
    # This is not cool, but should be small in most environments.
    BarclampDns::MgmtService.all.each do |role|
      role.node_roles.each do |nr|
        next unless nr.active?
        services = Attrib.get('dns-management-servers', nr)
        next unless services
        services.each do |s|
          service = s if s['name'] == service_name
          return service if service
        end
      end
    end
    nil
  end

  def self.remove_ip_address(dne)
    self.update_ip_address(dne, 'REMOVE')
  end

  def self.add_ip_address(dne)
    update_ip_address(dne, 'ADD')
  end

  def self.update_ip_address(dne, action)
    service = get_service(dne.dns_name_filter.service)
    return unless service

    return unless Rails.env.production?

    address = dne.network_allocation.address
    name, domain = dne.name.split('.', 2)
    self.update_dns_record(service, domain, dne.tenant_id, dne.rr_type, name, address.addr, action)
  end

  def self.send_request(url, data)
    store = OpenSSL::X509::Store.new
    store.add_cert(OpenSSL::X509::Certificate.new(File.read('/var/run/rebar/ca.pem')))

    # get client key and cert
    client_cert = OpenSSL::X509::Certificate.new(File.read('/var/run/rebar/server.crt'))
    client_key  = OpenSSL::PKey.read(File.read('/var/run/rebar/server.key'))

    user = User.find_by(username: 'system')
    RestClient::Resource.new(
        url,
        :ssl_cert_store =>  store,
	:ssl_client_cert=>  client_cert,
	:ssl_client_key =>  client_key,
        :verify_ssl     =>  OpenSSL::SSL::VERIFY_PEER
    ).patch data.to_json, :content_type => :json, :accept => :json, :'X-Authenticated-Username' => 'system', :'X-Authenticated-Capability' => user.cap_map.to_json
  end

  def self.update_dns_record(service, zone, t_id, rr_type, name, value, action)
    url = "#{service['url']}/zones/#{zone}"

    data = {
        'tenant_id' => t_id,
        'changetype' => action,
        'name' => name,
        'content' => value,
        'type' => rr_type
    }

    send_request(url, data)
  end

end
