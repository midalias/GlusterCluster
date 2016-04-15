#!/bin/bash


NODENAME=$(hostname)
PEERNODEPREFIX=${1}
VOLUMENAME=${2}
NODEINDEX=${3}
NODECOUNT=${4}
MOUNTPOINT="/datadrive"

BLACKLIST="/dev/sda|/dev/sdb"

scan_for_new_disks() {
    # Looks for unpartitioned disks
    declare -a RET
    DEVS=($(ls -1 /dev/sd*|egrep -v "${BLACKLIST}"|egrep -v "[0-9]$"))
    for DEV in "${DEVS[@]}";
    do
        # Check each device if there is a "1" partition.  If not,
        # "assume" it is not partitioned.
        if [ ! -b ${DEV}1 ];
        then
            RET+="${DEV} "
        fi
    done
    echo "${RET}"
}

get_disk_count() {
    DISKCOUNT=0
    for DISK in "${DISKS[@]}";
    do
        DISKCOUNT+=1
    done;
    echo "$DISKCOUNT"
}

do_partition() {
# This function creates one (1) primary partition on the
# disk, using all available space
    DISK=${1}
    echo "Partitioning disk $DISK"
    echo "n
p
1


w
" | fdisk "${DISK}"
#> /dev/null 2>&1

#
# Use the bash-specific $PIPESTATUS to ensure we get the correct exit code
# from fdisk and not from echo
if [ ${PIPESTATUS[1]} -ne 0 ];
then
    echo "An error occurred partitioning ${DISK}" >&2
    echo "I cannot continue" >&2
    exit 2
fi
}

add_to_fstab() {
    UUID=${1}
    MOUNTPOINT=${2}
    grep "${UUID}" /etc/fstab >/dev/null 2>&1
    if [ ${?} -eq 0 ];
    then
        echo "Not adding ${UUID} to fstab again (it's already there!)"
    else
        LINE="UUID=${UUID} ${MOUNTPOINT} ext4 defaults,noatime 0 0"
        echo -e "${LINE}" >> /etc/fstab
    fi
}

configure_disks() {
    ls "${MOUNTPOINT}" >> /tmp/error
    if [ ${?} -eq 0 ]
    then
        return
    fi
    DISKS=($(scan_for_new_disks))
    echo "Disks are ${DISKS[@]}"
    declare -i DISKCOUNT
    DISKCOUNT=$(get_disk_count)
    echo "Disk count is $DISKCOUNT"
        DISK="${DISKS[0]}"
        do_partition ${DISK}
		PARTITION=$(fdisk -l ${DISK}|grep /dev/sdc1|awk '{print $1}')
		echo "Partion: ${PARTITION}"

    echo "Creating filesystem on ${PARTITION}."
    mkfs -t ext4 ${PARTITION}
    mkdir "${MOUNTPOINT}"
	read UUID FS_TYPE < <(blkid -u filesystem ${PARTITION}|awk -F "[= ]" '{print $3" "$5}'|tr -d "\"")
	
	echo "UUID: ${UUID}"
    add_to_fstab "${UUID}" "${MOUNTPOINT}"
    echo "Mounting disk ${PARTITION} on ${MOUNTPOINT}"
    mount "${MOUNTPOINT}"
}


disable_selinux_centos() {
    sed -i 's/^SELINUX=.*/SELINUX=disabled/I' /etc/selinux/config
    setenforce 0
}

install_glusterfs_centos() {
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
	echo "yum gfs status is ${?} "
    yum -y install glusterfs-cli glusterfs-geo-replication glusterfs-fuse glusterfs-server glusterfs
	echo "yum install gfs status is ${?} "
}

configure_gluster() {

        systemctl status glusterd.service

        if [ ${?} -ne 0 ];
        then
            install_glusterfs_centos
        fi
        systemctl start glusterd.service

        GLUSTERDIR="${MOUNTPOINT}/brick"
    ls "${GLUSTERDIR}" >> /tmp/error
    if [ ${?} -ne 0 ];
    then
        mkdir "${GLUSTERDIR}"
    fi

    if [ $NODEINDEX -lt $(($NODECOUNT-1)) ];
    then
        echo "This is node $NODEINDEX. Too early to setup GlusterFS"
		return
    fi
    allNodes="${NODENAME}:${GLUSTERDIR}"
    retry=10
    failed=1
    while [ $retry -gt 0 ] && [ $failed -gt 0 ]; do
        failed=0
        index=0
        echo retrying $retry >> /tmp/error
        while [ $index -lt $(($NODECOUNT-1)) ]; do
            ping -c 3 "${PEERNODEPREFIX}${index}" >> /tmp/error
			PEERNODEIP=$(getent ahostsv4 ${PEERNODEPREFIX}${index} | tail -n 1|awk '{ print $1 }')
			echo "Adding ${PEERNODEIP} to /etc/hosts"
			echo "${PEERNODEIP}    ${PEERNODEPREFIX}${index}" >> /etc/hosts
            gluster peer probe "${PEERNODEPREFIX}${index}" >> /tmp/error
            if [ ${?} -ne 0 ];
            then
                failed=1
                echo "gluster peer probe ${PEERNODEPREFIX}${index} failed"
            fi
            gluster peer status >> /tmp/error
            gluster peer status | grep "${PEERNODEPREFIX}${index}" >> /tmp/error
            if [ ${?} -ne 0 ];
            then
                failed=1
                echo "gluster peer status ${PEERNODEPREFIX}${index} failed"
            fi
            if [ $retry -eq 10 ]; then
                allNodes="${allNodes} ${PEERNODEPREFIX}${index}:${GLUSTERDIR}"
				echo "allNodes: ${allNodes}"
            fi
            let index++
        done
        sleep 30
        let retry--
    done
	
	echo "allNodes Total: ${allNodes}"

    sleep 60
    gluster volume create ${VOLUMENAME} rep 2 transport tcp ${allNodes} 2>> /tmp/error
    gluster volume info 2>> /tmp/error
    gluster volume start ${VOLUMENAME} 2>> /tmp/error
}

disable_selinux_centos

configure_disks

configure_gluster

