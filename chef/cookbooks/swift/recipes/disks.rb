#
# Copyright 2011, Dell
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
# Author: andi abes
#

f = package "xfsprogs" do
  action :nothing
end
f.run_action(:install)

def get_uuid(disk)
  uuid = nil
  IO.popen("blkid -c /dev/null -s UUID -o value #{disk}"){ |f|
    uuid=f.read.strip
  }
  return uuid if uuid && (uuid != '')
  nil
end

log("locating disks using #{node[:swift][:disk_enum_expr]} test: #{node[:swift][:disk_test_expr]}") {level :debug}
to_use_disks = []
all_disks = node["crowbar"]["disks"]
all_disks.each { |k,v|
  to_use_disks << k if (v["usage"] == "Storage") && ::File.exists?("/dev/#{k}")
}

Chef::Log.info("Swift will use these disks: #{to_use_disks.join(":")}")

# Make sure that the kernel is aware of the current state of the
# drive partition tables.
::Kernel.system("partprobe #{to_use_disks.map{|d|"/dev/#{d}"}.join(' ')}")
# Let udev catch up, if needed.
sleep 3

node[:swift] ||= Mash.new
node[:swift][:devs] ||= Mash.new
found_disks=[]
wait_for_format = false
to_use_disks.each do |k|

  target_suffix= k + "1" # by default, will use format first partition.
  target_dev = "/dev/#{k}"
  target_dev_part = "/dev/#{target_suffix}"

  disk = Hash.new
  disk[:device] = target_dev_part
  disk[:uuid] = get_uuid(target_dev_part)

  if disk[:uuid].nil?
    if ::Kernel.system("parted -l -m | grep #{target_dev} | grep 'unrecognised disk label'")
      Chef::Log.info("Unknown disk label or empty disk. Try to create GPT label on #{target_dev}")
      ::Kernel.exec "parted -s #{target_dev} -- mklabel gpt")
    end
    if ::Kernel.system("parted -l -m | grep -A1 #{target_dev} | grep 1:")
      unless ::Kernel.system("parted -l -m | grep -A1 #{target_dev} | grep 1: | grep xfs")
        # probably there's some unsupported file system on the first partition - don't touch it
        Chef::Log.info("Unable to read disk #{target_dev} UUID, although device seem to have data on it - skipping")
        next
      end
    else
      # Create partition table
      Chef::Log.info("Initializing device with new partition table")
      ::Kernel.system("parted -s #{target_dev} -- unit s mklabel gpt mkpart primary ext2 2048s -1M")
      ::Kernel.system("partprobe #{target_dev}")
      sleep 3
      ::Kernel.system("dd if=/dev/zero of=#{target_dev_part} bs=1024 count=65")
    end
    # Create xfs partition
    ::Kernel.exec "mkfs.xfs -i size=1024 -f #{target_dev_part}" unless ::Process.fork
    disk[:state] = "Fresh"
    wait_for_format = true
    found_disks << disk.dup
    disk[:uuid] = get_device_uuid(device)
  elsif node[:swift][:devs][disk[:uuid]]
    # the disk is known and used
    Chef::Log.info("Swift - #{target_dev_part} already known and used by Swift.")
  else
    # the disk is unknown but definitely has a certain structure - just don't touch it
    Chef::Log.info("Disk ${device} seems to have data on it - skipping")
  end
end

if wait_for_format
  Chef::Log.info("Swift -- Waiting on all disks to finish formatting")
  ::Process.waitall
end

# If we have freshly-claimed disks, add them and save them.
found_disks.each do |disk|
  # Disk was freshly created.  Grab its UUID and create a mount point.
  disk[:uuid] = get_uuid(disk[:device])
  disk[:state] = "Operational"
  disk[:name] = disk[:uuid].delete('-')
  Chef::Log.info("Adding new disk #{disk[:device]} with UUID #{disk[:uuid]} to the Swift config")
  node[:swift][:devs][disk[:uuid]] = disk.dup
end
node.save

# Take appropriate action for each disk.
node[:swift][:devs].each do |uuid,disk|
  # We always want a mountpoint created.
  directory "/srv/node/#{disk[:name]}" do
    group node[:swift][:group]
    owner node[:swift][:user]
    recursive true
    action :create
  end
  case disk[:state]
  when "Operational"
    # We want to use this disk.
    mount "/srv/node/#{disk[:name]}"  do
      device disk[:uuid]
      device_type :uuid
      options "noatime,nodiratime,nobarrier,logbufs=8"
      dump 0
      fstype "xfs"
      action [:mount, :enable]
    end
  else
    # We don't want this disk right now.  Maybe it is about to die.
    mount "/srv/node/#{disk[:name]}"  do
      device disk[:uuid]
      device_type :uuid
      options "noatime,nodiratime,nobarrier,logbufs=8"
      dump 0
      fstype "xfs"
      action [:umount, :disable]
    end
  end
end
