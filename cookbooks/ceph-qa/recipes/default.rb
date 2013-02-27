# Check if burnupi/plana
if !node['hostname'].match(/^(plana|burnupi)/)
 raise "This recipe is only intended for plana and burnupi hosts"
end


# remove ceph packages (if any)
#  FIXME: possibly remove this when teuthology starts using debs.
execute "remove ceph packages" do
  command 'apt-get purge -f -y --force-yes ceph ceph-common libcephfs1 radosgw python-ceph librbd1 librados2|| true'
end
execute "remove /etc/ceph" do
  command 'rm -rf /etc/ceph'
end
execute "remove ceph sources" do
  command 'rm -f /etc/apt/sources.list.d/ceph.list'
end

#Setup sources.list to use our apt mirror.
case node[:platform]
when "ubuntu"
  case node[:platform_version]
  when "12.04"
    cookbook_file '/etc/apt/sources.list' do
      source "sources.list.precise"
      mode 0644
      owner "root"
      group "root"
    end
  when "12.10"
    cookbook_file '/etc/apt/sources.list' do
      source "sources.list.quantal"
      mode 0644
      owner "root"
      group "root"
    end
  end
end

# for rgw
execute "add autobuild gpg key to apt" do
  command <<-EOH
wget -q -O- 'http://ceph.com/git/?p=ceph.git;a=blob_plain;f=keys/autobuild.asc;hb=HEAD' \
| sudo apt-key add -
  EOH
end

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
package 'libboost-thread1.46.1'
package 'cryptsetup-bin'
package 'xfsprogs'
package 'gdisk'
package 'parted'

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
package 'btrfs-tools'

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
package 'mpich2'
package 'libmpich2-3'
package 'libmpich2-dev'
package 'ant'

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

# for json_xs to investigate JSON by hand
package 'libjson-xs-perl'
# for pretty-printing xml
package 'xml-twig-tools'

# for java bindings, hadoop, etc.
package 'default-jdk'
package 'junit4'

# for disk/etc monitoring
package 'smartmontools'
package 'nagios-nrpe-server'

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

#Unfortunately no megacli/arecacli package for ubuntu -- Needed for raid monitoring and smart.
cookbook_file '/usr/sbin/megacli' do
  source "megacli"
  mode 0755
  owner "root"
  group "root"
end
cookbook_file '/usr/sbin/cli64' do
  source "cli64"
  mode 0755
  owner "root"
  group "root"
end


#Custom netsaint scripts for raid/disk/smart monitoring:
directory "/usr/libexec/" do
  owner "root"
  group "root"
  mode "0755"
  action :create
end
cookbook_file '/usr/libexec/raid.pl' do
  source "raid.pl"
  mode 0755
  owner "root"
  group "root"
end
cookbook_file '/usr/libexec/smart.pl' do
  source "smart.pl"
  mode 0755
  owner "root"
  group "root"
end
cookbook_file '/usr/libexec/diskusage.pl' do
  source "diskusage.pl"
  mode 0755
  owner "root"
  group "root"
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

#NFS servers uport per David Z.
package 'nfs-kernel-server'

#Static IP
package 'ipcalc'

execute "set up static IP and 10gig interface" do
  command <<-'EOH'
    dontrun=$(grep -ic eth2 /etc/network/interfaces)
    if [ $dontrun -eq 0 ]
    then
    cidr=$(ip addr show dev eth0 | grep -iw inet | awk '{print $2}')
    ip=$(echo $cidr | cut -d'/' -f1)
    netmask=$(ipcalc $cidr | grep -i netmask | awk '{print $2}')
    gateway=$(ipcalc $cidr | grep -i hostmin | awk '{print $2}')
    broadcast=$(ipcalc $cidr | grep -i hostmax | awk '{print $2}')
    octet1=$(echo $ip | cut -d'.' -f1)
    octet2=$(echo $ip | cut -d'.' -f2)
    octet3=$(echo $ip | cut -d'.' -f3)
    octet4=$(echo $ip | cut -d'.' -f4)
    octet3=$(($octet3 + 13))
    
    cat interfaces | sed -i "s/iface eth0 inet dhcp/\
    iface eth0 inet static\n\
            address $ip\n\
            netmask $netmask\n\
            gateway $gateway\n\
            broadcast $broadcast\n\
    \n\
    auto eth2\n\
    iface eth2 inet static\n\
            address $octet1.$octet2.$octet3.$octet4\n\
            netmask $netmask\
    /g" /etc/network/interfaces
    fi
  EOH
end

#Static DNS

file '/etc/resolvconf/resolv.conf.d/base' do
  owner 'root'
  group 'root'
  mode '0755'
  content <<-EOH
    nameserver 10.214.128.4
    nameserver 10.214.128.5
    search front.sepia.ceph.com sepia.ceph.com
  EOH
end

#Nagios sudo (for raid utilities)
file '/etc/sudoers.d/90-nagios' do
  owner 'root'
  group 'root'
  mode '0440'
  content <<-EOH
    nagios ALL=NOPASSWD: /usr/sbin/megacli, /usr/sbin/cli64, /usr/sbin/smartctl, /usr/sbin/smartctl
  EOH
end

#Nagios nrpe config
cookbook_file '/etc/nagios/nrpe.cfg' do
  source "nrpe.cfg"
  owner 'root'
  group 'root'
  mode '0644'
  notifies :restart, "service[nagios-nrpe-server]"
end

service "nagios-nrpe-server" do
  action [:enable,:start]
end


#nagios nrpe settings
file '/etc/default/nagios-nrpe-server' do
  owner 'root'
  group 'root'
  mode '0644'
  content <<-EOH
    DAEMON_OPTS="--no-ssl"
  EOH
end


execute "Restarting Networking" do
  command <<-'EOH'
    sudo /etc/init.d/networking restart
  EOH
end

execute "Restarting resolvdns" do
  command <<-'EOH'
    sudo service resolvconf restart
  EOH
end

bash "ssh_max_sessions" do
  user "root"
  cwd "/etc/ssh"
  code <<-EOT
    echo "MaxSessions 1000" >> sshd_config
  EOT
  not_if {File.read("/etc/ssh/sshd_config") =~ /MaxSessions/}
end

service "ssh" do
  action [:restart]
end

file '/ceph-qa-ready' do
  content "ok\n"
end
