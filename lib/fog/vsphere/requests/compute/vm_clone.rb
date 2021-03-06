module Fog
  module Compute
    class Vsphere

      module Shared
        private
        def vm_clone_check_options(options)
          default_options = {
            'force'        => false,
            'linked_clone' => false,
          }
          options = default_options.merge(options)
          required_options = %w{ path name }
          required_options.each do |param|
            raise ArgumentError, "#{required_options.join(', ')} are required" unless options.has_key? param
          end
          # The tap removes the leading empty string
          path_elements = options['path'].split('/').tap { |o| o.shift }
          first_folder = path_elements.shift
          if first_folder != 'Datacenters' then
            raise ArgumentError, "vm_clone path option must start with /Datacenters.  Got: #{options['path']}"
          end
          dc_name = path_elements.shift
          if not datacenters.get dc_name then
            raise ArgumentError, "Datacenter #{dc_name} does not exist, only datacenters #{datacenters.all.map(:name).join(",")} are accessible."
          end
          options
        end
      end

      class Real
        include Shared

        # Clones a VM from a template or existing machine on your vSphere 
        # Server.  
        #
        # ==== Parameters
        # * options<~Hash>:
        #   * 'template_path'<~String> - *REQUIRED* The path to the machine you 
        #     want to clone FROM. (Example:
        #     "/Datacenter/DataCenterNameHere/FolderNameHere/VMNameHere")
        #   * 'name'<~String> - *REQUIRED* The VMName of the Destination  
        #   * 'resource_pool'<~String> - The resource pool on your datacenter 
        #     cluster you want to use.
        #   * 'dest_folder'<~String> - Destination Folder of where 'name' will
        #     be placed on your cluster. *NOT TESTED OR VALIDATED*
        #   * 'power_on'<~Boolean> - Whether to power on machine after clone. 
        #     Defaults to true.
        #   * 'wait'<~Boolean> - Whether the method should wait for the virtual
        #     machine to close finish cloning before returning information from 
        #     vSphere. Returns the value of the machine if it finishes cloning 
        #     in 150 seconds (1m30s) else it returns nil. 'wait' Defaults to nil. 
        #     Saves a little time.
        #   * 'transform'<~String> - Not documented - see http://www.vmware.com/support/developer/vc-sdk/visdk41pubs/ApiReference/vim.vm.RelocateSpec.html
        #
        def vm_clone(options = {})
          # Option handling
          options = vm_clone_check_options(options)

          # Added for people still using options['path']
          template_path = options['path'] || options['template_path']

          notfound = lambda { raise Fog::Compute::Vsphere::NotFound, "Could not find VM template" }

          # Find the template in the folder.  This is more efficient than
          # searching ALL VM's looking for the template.
          # Tap gets rid of the leading empty string and "Datacenters" element
          # and returns the array.
          path_elements = template_path.split('/').tap { |ary| ary.shift 2 }
          # The DC name itself.
          template_dc = path_elements.shift
          # If the first path element contains "vm" this denotes the vmFolder
          # and needs to be shifted out
          path_elements.shift if path_elements[0] == 'vm'
          # The template name.  The remaining elements are the folders in the
          # datacenter.
          template_name = path_elements.pop

          dc = find_raw_datacenter(template_dc)
          # Get the VM Folder (Group) efficiently
          vm_folder = dc.vmFolder
          # Walk the tree resetting the folder pointer as we go
          folder = path_elements.inject(vm_folder) do |current_folder, sub_folder_name|
            # JJM VIM::Folder#find appears to be quite efficient as it uses the
            # searchIndex It certainly appears to be faster than
            # VIM::Folder#inventory since that returns _all_ managed objects of
            # a certain type _and_ their properties.
            sub_folder = current_folder.find(sub_folder_name, RbVmomi::VIM::Folder)
            raise ArgumentError, "Could not descend into #{sub_folder_name}.  Please check your path." unless sub_folder
            sub_folder
          end

          # Now find the template itself using the efficient find method
          vm_mob_ref = folder.find(template_name, RbVmomi::VIM::VirtualMachine)

          # Now find _a_ resource pool to use for the clone if one is not specified
          if ( options.has_key?('resource_pool') )
            resource_pool = options['resource_pool']
          elsif ( vm_mob_ref.resourcePool == nil )
            # If the template is really a template then there is no associated resource pool,
            # so we need to find one using the template's parent host or cluster
            esx_host = vm_mob_ref.collect!('runtime.host')['runtime.host']
            # The parent of the ESX host itself is a ComputeResource which has a resourcePool
            resource_pool = esx_host.parent.resourcePool
          else
            # If the vm given did return a valid resource pool, default to using it for the clone.
            # Even if specific pools aren't implemented in this environment, we will still get back
            # at least the cluster or host we can pass on to the clone task
            resource_pool = vm_mob_ref.resourcePool
          end
          
          relocation_spec=nil
          if ( options['linked_clone'] )
            # cribbed heavily from the rbvmomi clone_vm.rb
            # this chunk of code reconfigures the disk of the clone source to be read only,
            # and then creates a delta disk on top of that, this is required by the API in order to create
            # linked clondes
            disks = vm_mob_ref.config.hardware.device.select do |vm_device|
              vm_device.class == RbVmomi::VIM::VirtualDisk
            end
            disks.select{|vm_device| vm_device.backing.parent == nil}.each do |disk|
              disk_spec = {
                :deviceChange => [
                  {
                    :operation => :remove,
                    :device => disk
                  },
                  {
                    :operation => :add,
                    :fileOperation => :create,
                    :device => disk.dup.tap{|disk_backing|
                      disk_backing.backing = disk_backing.backing.dup;
                      disk_backing.backing.fileName = "[#{disk.backing.datastore.name}]";
                      disk_backing.backing.parent = disk.backing
                    }
                  },
                ]
              }
              vm_mob_ref.ReconfigVM_Task(:spec => disk_spec).wait_for_completion
            end
            # Next, create a Relocation Spec instance
            relocation_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(:pool => resource_pool,
                                                                      :diskMoveType => :moveChildMostDiskBacking)
          else
            relocation_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(:pool => resource_pool,
                                                                      :transform => options['transform'] || 'sparse')
          end
          # And the clone specification
          clone_spec = RbVmomi::VIM.VirtualMachineCloneSpec(:location => relocation_spec,
                                                            :powerOn  => options.has_key?('power_on') ? options['power_on'] : true,
                                                            :template => false)
          task = vm_mob_ref.CloneVM_Task(:folder => options.has_key?('dest_folder') ? options['dest_folder'] : vm_mob_ref.parent,
                                         :name => options['name'],
                                         :spec => clone_spec)
          # Waiting for the VM to complete allows us to get the VirtulMachine
          # object of the new machine when it's done.  It is HIGHLY recommended
          # to set 'wait' => true if your app wants to wait.  Otherwise, you're
          # going to have to reload the server model over and over which
          # generates a lot of time consuming API calls to vmware.
          if options['wait'] then
            # REVISIT: It would be awesome to call a block passed to this
            # request to notify the application how far along in the process we
            # are.  I'm thinking of updating a progress bar, etc...
            new_vm = task.wait_for_completion
          else
            tries = 0
            new_vm = begin
              # Try and find the new VM (folder.find is quite efficient)
              folder.find(options['name'], RbVmomi::VIM::VirtualMachine) or raise Fog::Vsphere::Errors::NotFound
            rescue Fog::Vsphere::Errors::NotFound
              tries += 1
              if tries <= 10 then
                sleep 15
                retry
              end
              nil
            end
          end

          # Return hash
          {
            'vm_ref'        => new_vm ? new_vm._ref : nil,
            'vm_attributes' => new_vm ? convert_vm_mob_ref_to_attr_hash(new_vm) : {},
            'task_ref'      => task._ref
          }
        end

      end

      class Mock
        include Shared
        def vm_clone(options = {})
          # Option handling
          options = vm_clone_check_options(options)
          notfound = lambda { raise Fog::Compute::Vsphere::NotFound, "Could not find VM template" }
          list_virtual_machines.find(notfound) do |vm|
            vm[:name] == options['path'].split("/")[-1]
          end
          {
            'vm_ref'   => 'vm-123',
            'task_ref' => 'task-1234',
          }
        end

      end
    end
  end
end
