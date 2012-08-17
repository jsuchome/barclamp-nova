# Copyright 2011, Dell 
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
require 'chef'

class NovaService < ServiceObject

  def initialize(thelogger)
    @bc_name = "nova"
    @logger = thelogger
  end

  def self.allow_multiple_proposals?
    true
  end

  def proposal_dependencies(role)
    answer = []
    answer << { "barclamp" => "database", "inst" => role.default_attributes["nova"]["db"]["sql_instance"] }
    answer << { "barclamp" => "keystone", "inst" => role.default_attributes["nova"]["keystone_instance"] }
    answer << { "barclamp" => "glance", "inst" => role.default_attributes["nova"]["glance_instance"] }
    if role.default_attributes["nova"]["volume"]["type"] == "rados"
        answer << { "barclamp" => "ceph", "inst" => role.default_attributes["nova"]["volume"]["ceph_instance"] }
    end
    answer
  end

  #
  # Lots of enhancements here.  Like:
  #    * Don't reuse machines
  #    * validate hardware.
  #
  def create_proposal
    @logger.debug("Nova create_proposal: entering")
    base = super
    @logger.debug("Nova create_proposal: done with base")

    nodes = NodeObject.all
    nodes.delete_if { |n| n.nil? or n.admin? }
    head = nodes.shift
    nodes = [ head ] if nodes.empty?
    base["deployment"]["nova"]["elements"] = {
      "nova-multi-controller" => [ head.name ],
      "nova-multi-compute" => nodes.map { |x| x.name }
    }

    base["attributes"]["nova"]["db"]["sql_engine"] = ""
    base["attributes"]["nova"]["db"]["sql_instance"] = ""
    begin
      databaseService = DatabaseService.new(@logger)
      dbs = databaseService.list_active[1]
      if dbs.empty?
        # No actives, look for proposals
        dbs = databaseService.proposals[1]
      end
      if dbs.empty?
        @logger.info("Nova create_proposal: no database proposal found")
        base["attributes"]["nova"]["db"]["sql_engine"] = ""
      else
        base["attributes"]["nova"]["db"]["sql_instance"] = dbs[0]
        base["attributes"]["nova"]["db"]["sql_engine"] = "database"
      end
    rescue
      @logger.info("Nova create_proposal: no database found")
    end

    if base["attributes"]["nova"]["db"]["sql_engine"] == ""
      raise(I18n.t('model.service.dependency_missing', :name => @bc_name, :dependson => "database"))
    end

    base["attributes"]["nova"]["keystone_instance"] = ""
    begin
      keystoneService = KeystoneService.new(@logger)
      keystones = keystoneService.list_active[1]
      if keystones.empty?
        # No actives, look for proposals
        keystones = keystoneService.proposals[1]
      end
      base["attributes"]["nova"]["keystone_instance"] = keystones[0] unless keystones.empty?
    rescue
      @logger.info("Nova create_proposal: no keystone found")
    end
    if base["attributes"]["nova"]["keystone_instance"] == ""
      raise(I18n.t('model.service.dependency_missing', :name => @bc_name, :dependson => "keystone"))
    end

    base["attributes"]["nova"]["glance_instance"] = ""
    begin
      glanceService = GlanceService.new(@logger)
      glances = glanceService.list_active[1]
      if glances.empty?
        # No actives, look for proposals
        glances = glanceService.proposals[1]
      end
      base["attributes"]["nova"]["glance_instance"] = glances[0] unless glances.empty?
    rescue
      @logger.info("Nova create_proposal: no glance found")
    end
    if base["attributes"]["nova"]["glance_instance"] == ""
      raise(I18n.t('model.service.dependency_missing', :name => @bc_name, :dependson => "glance"))
    end

    base["attributes"]["nova"]["volume"]["type"] = "local"
    begin
      cephService = CephService.new(@logger)
      cephs = cephService.list_active[1]
      if cephs.empty? # no active ceph service look for proposals
        cephs = cephService.proposals[1]
      end
      unless cephs.empty?
        base["attributes"]["nova"]["volume"]["ceph_instance"] = cephs[0]
        @logger.info("Using ceph instance: #{cephs[0]}")
        base["attributes"]["nova"]["volume"]["type"] = "rados"
        base["attributes"]["nova"]["volume"]["rbd_pool"] = "data"
      end
    rescue
      @logger.info("Nova create_proposal: ceph not found")
    end

    base["attributes"]["nova"]["db"]["password"] = random_password

    @logger.debug("Nova create_proposal: exiting")
    base
  end

  def apply_role_pre_chef_call(old_role, role, all_nodes)
    @logger.debug("Nova apply_role_pre_chef_call: entering #{all_nodes.inspect}")
    return if all_nodes.empty?

    # Handle addressing
    #
    # Make sure that the front-end pieces have public ip addreses.
    #   - if we are in HA mode, then that is all nodes.
    #
    # if tenants are enabled, we don't manage interfaces on nova-fixed.
    #
    net_svc = NetworkService.new @logger

    tnodes = role.override_attributes["nova"]["elements"]["nova-multi-controller"]
    tnodes = all_nodes if role.default_attributes["nova"]["network"]["ha_enabled"]
    unless tnodes.nil? or tnodes.empty?
      tnodes.each do |n|
        net_svc.allocate_ip "default", "public", "host", n
        unless role.default_attributes["nova"]["network"]["tenant_vlans"] 
          net_svc.allocate_ip "default", "nova_fixed", "router", n
        end
      end
    end

    unless role.default_attributes["nova"]["network"]["tenant_vlans"] 
      all_nodes.each do |n|
        net_svc.enable_interface "default", "nova_fixed", n
      end
    end

    @logger.debug("Nova apply_role_pre_chef_call: leaving")
  end

  def validate_proposal_after_save proposal
    super

    elements = proposal["deployment"]["nova"]["elements"]

    elements["nova-multi-controller"].each do |n|
      node = NodeObject.find_node_by_name(n)
      roles = node.roles()
      ["ceph-store", "swift-storage"].each do |role|
        if roles.include?(role)
          raise Chef::Exceptions::ValidationFailed.new("Node #{n} already has the #{role} role; nodes cannot have both nova-multi-controller and #{role} roles")
        end
      end
    end

  end

end

