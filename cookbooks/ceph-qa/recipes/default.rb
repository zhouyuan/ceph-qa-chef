
# do radosgw recipe first, because it updates the apt sources and runs
# apt-get update for us too.
if node[:platform] == "ubuntu" and (node[:platform_version] == "10.10" or node[:platform_version] == "11.10" or node[:platform_version] == "12.04")
  include_recipe "ceph-qa::radosgw"
else
  Chef::Log.info("radosgw not supported on: #{node[:platform]} #{node[:platform_version]}")

  # der.. well, run update.
  execute "apt-get update" do
    command "apt-get update"
  end
end

package 'build-essential'
package 'sysstat'
package 'gdb'
package 'python-configobj'
package 'python-gevent'

# for running ceph
package 'libedit2'
package 'libssl0.9.8'
package 'libgoogle-perftools0'

# for setting BIOS settings
package 'smbios-utils'

case node[:platform]
when "ubuntu"
  case node[:platform_version]
  when "10.10"
    package 'libcrypto++8'
  when "11.10", "12.04"
    package 'libcrypto++9'
  else
    Chef::Log.fatal("Unknown ubuntu release: #{node[:platform_version]}")
    exit 1
  end
else
  Chef::Log.fatal("Unknown platform: #{node[:platform]}")
  exit 1
end
package 'libuuid1'
package 'libfcgi'

# for compiling helpers and such
package 'libatomic-ops-dev'

# used by workunits
package 'git-core'
package 'attr'
package 'dbench'
package 'bonnie++'
package 'iozone3'
package 'tiobench'
package 'ltp-kernel-test'
package 'valgrind'
package 'python-nose'

# used by the xfstests tasks
package 'libtool'
package 'automake'
package 'gettext'
package 'uuid-dev'
package 'libacl1-dev'
package 'bc'
package 'xfsdump'
package 'dmapi'
package 'xfslibs-dev'

# for blktrace and seekwatcher
package 'blktrace'
package 'python-numpy'
package 'python-matplotlib'
package 'mencoder'

# for qemu
package 'kvm'
package 'genisoimage'

# remove ceph packages (if any)
#  FIXME: possibly remove this when teuthology starts using debs.
execute "remove ceph packages" do
  command 'apt-get remove -f -y --force-yes ceph ceph-common libcephfs1 radosgw python-ceph || true'
end
execute "remove /etc/ceph" do
  command 'rm -rf /etc/ceph'
end

# for rgw
execute "add autobuild gpg key to apt" do
  command <<-EOH
wget -q -O- 'http://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/autobuild.asc;hb=HEAD' \
| sudo apt-key add -
  EOH
end


file '/etc/grub.d/02_force_timeout' do
  owner 'root'
  group 'root'
  mode '0755'
  content <<-EOH
cat <<EOF
set timeout=5
EOF
  EOH
end

package 'ntp'

cookbook_file '/etc/ntp.conf' do
  source "ntp.conf"
  mode 0644
  owner "root"
  group "root"
  notifies :restart, "service[ntp]"
end

service "ntp" do
  action [:enable,:start]
end

execute "add user_xattr to root mount options in fstab" do
  # fugly but works! which is more than i can say for the "mount"
  # resource, which doesn't seem to like a rootfs with an unknown UUID
  # at all.
  command <<-'EOH'
    perl -pe 'if (m{^([^#]\S*\s+/\s+\S+\s+)(\S+)(\s+.*)$}) { $_="$1$2,user_xattr$3\n" unless $2=~m{(^|,)user_xattr(,|$)}; }' -i.bak /etc/fstab
  EOH
end

execute "enable xattr for this boot" do
  command "mount -o remount,user_xattr /"
end

execute "allow fuse mounts to be used by non-owners" do
  command "grep -q ^user_allow_other /etc/fuse.conf || echo user_allow_other >> /etc/fuse.conf"
end

execute "add user ubuntu to group fuse" do
  command "adduser ubuntu fuse"
end

file '/etc/fuse.conf' do
  mode "0644"
end

execute "add user ubuntu to group kvm" do
  command "adduser ubuntu kvm"
end

directory '/home/ubuntu/.ssh' do
  owner "ubuntu"
  group "ubuntu"
  mode "0755"
end

execute "set up ssh keys" do
  command <<-'EOH'
    URL=https://raw.github.com/ceph/keys/autogenerated/ssh/%s.pub
    export URL
    ssh-import-id -o /home/ubuntu/.ssh/authorized_keys @all
    sort -u </home/ubuntu/.ssh/authorized_keys >/home/ubuntu/.ssh/authorized_keys.sort
    mv /home/ubuntu/.ssh/authorized_keys.sort /home/ubuntu/.ssh/authorized_keys
    chown ubuntu.ubuntu /home/ubuntu/.ssh/authorized_keys
  EOH
end

execute "add ubuntu to disk group" do
  command <<-'EOH'
    usermod -a -G disk ubuntu
  EOH
end

execute "enable kernel logging to console" do
  command <<-'EOH'
    set -e
    f=/etc/default/grub

    # if it has a setting, make sure it's to ttyS1
    if grep -q '^GRUB_CMDLINE_LINUX=.*".*console=tty0 console=ttyS[01],115200' $f; then sed 's/console=ttyS[01]/console=ttyS1/' <$f >$f.chef; fi

    # if it has no setting, add it
    if ! grep -q '^GRUB_CMDLINE_LINUX=.*".* console=tty0 console=ttyS[01],115200.*' $f; then sed 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/GRUB_CMDLINE_LINUX="\1 console=tty0 console=ttyS1,115200"/' <$f >$f.chef; fi

    # if we did something; move it into place.  update-grub done below.
    if [ -f $f.chef ] ; then mv $f.chef $f; fi
  EOH
end

cookbook_file '/etc/init/ttyS1.conf' do
   source 'ttyS1.conf'
   mode 0644
   owner "root"
   group "root"
   notifies :start, "service[ttyS1]"
end

service "ttyS1" do
  # Default provider for Ubuntu is Debian, and :enable doesn't work
  # for Upstart services unless we change provider.  Assume Upstart
  provider Chef::Provider::Service::Upstart
  action [:enable,:start]
end

# This became necessary with oneiric - items in a submenu are in a
# different namespace when specifying grub defaults. Ubuntu puts the
# newest version at the top, and the rest in a "Previous Linux
# versions" submenu. Disable this so we can reliably set default
# kernels, without worrying about pre-existing ones.
# This may not work for future distros, so check for oneiric/precise for now.
case node[:lsb][:codename]
when "oneiric", "precise"
  execute "disable grub submenu creation" do
    command <<-'EOH'
sed 's/\! \$in_submenu\;/\! \$in_submenu \&\& false\;/' /etc/grub.d/10_linux > /etc/grub.d/.tmp_chef_linux
chmod +x /etc/grub.d/.tmp_chef_linux
mv /etc/grub.d/.tmp_chef_linux /etc/grub.d/10_linux
EOH
  end
end

execute 'update-grub' do
end

file '/ceph-qa-ready' do
  content "ok\n"
end
