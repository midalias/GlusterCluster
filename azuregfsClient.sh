#!/bin/bash

disable_selinux_centos() {
    sed -i 's/^SELINUX=.*/SELINUX=disabled/I' /etc/selinux/config
    setenforce 0
}

install_glusterfs_centos_client() {
    yum list installed glusterfs-server
    if [ ${?} -eq 0 ];
    then
        return
    fi

    if [ ! -e /etc/yum.repos.d/epel.repo ];
    then
        echo "Installing extra packages for enterprise linux"
		rpm  -ivh  http://dl.fedoraproject.org/pub/epel/7/x86_64/e/epel-release-7-5.noarch.rpm
        yum --exclude=WALinuxAgent* -y update
		echo "yum epel status is status is ${?} "
    fi

    echo "installing gluster"
    wget --no-cache http://download.gluster.org/pub/gluster/glusterfs/LATEST/EPEL.repo/glusterfs-epel.repo
    mv glusterfs-epel.repo  /etc/yum.repos.d/
    yum --exclude=WALinuxAgent* -y update
	echo "yum gfs status is status is ${?} "
	yum -y install glusterfs glusterfs-fuse
	echo "yum install gfs status is ${?} "
	
	mkdir  /mnt/gfsvolume
	
	mount.glusterfs  gluster-node-0:/gfs   /mnt/gfsvolume
}

disable_selinux_centos

install_glusterfs_centos_client
