#!/bin/bash
set -euo pipefail

SSH_CMD="sshpass -p 1111 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
EXEC_CLIENT="$SSH_CMD root@192.168.100.2"
EXEC_MIDDLEBOX="$SSH_CMD root@192.168.100.3"
EXEC_SERVER="$SSH_CMD root@192.168.100.4"

SCP_CMD="sshpass -p 1111 scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# =======================================
# Подготовка сети net_for_ssh
# =======================================
if ! virsh net-list --all | grep -q " net_for_ssh "
then
	virsh net-define net_for_ssh.xml
	virsh net-start net_for_ssh
fi

# =======================================
# Подготовка сети net_1
# =======================================
if ! virsh net-list --all | grep -q " net_1 "
then
	virsh net-define net_1.xml
	virsh net-start net_1
fi

# =======================================
# Подготовка сети net_2
# =======================================
if ! virsh net-list --all | grep -q " net_2 "
then
	virsh net-define net_2.xml
	virsh net-start net_2
fi

# =======================================
# Подготовка машины client
# =======================================
if ! virsh list --all | grep -q " client "
then
	virt-builder ubuntu-18.04 \
		--format qcow2 \
		--output client.qcow2 \
		--hostname client \
		--install wget,net-tools \
		--root-password password:1111 \
		--run-command "ssh-keygen -A" \
		--run-command "sed -i \"s/.*PermitRootLogin.*/PermitRootLogin yes/g\" /etc/ssh/sshd_config" \
		--copy-in netcfg_client.yaml:/etc/netplan/

	virt-install \
		--import \
		--name client \
		--ram 1024 \
		--disk client.qcow2 \
		--network network=net_for_ssh \
		--network network=net_1,mac=52:54:56:11:00:00 \
		--noautoconsole

	virsh snapshot-create-as client --name init
else
	virsh snapshot-revert client --snapshotname init
fi

# =======================================
# Подготовка машины middlebox
# =======================================
if ! virsh list --all | grep -q " middlebox "
then
	virt-builder ubuntu-18.04 \
		--format qcow2 \
		--output middlebox.qcow2 \
		--hostname middlebox \
		--install python,daemon,libnuma1 \
		--root-password password:1111 \
		--run-command "ssh-keygen -A" \
		--run-command "sed -i \"s/.*PermitRootLogin.*/PermitRootLogin yes/g\" /etc/ssh/sshd_config" \
		--copy-in netcfg_middlebox.yaml:/etc/netplan/

	virt-install \
		--import \
		--name middlebox \
		--vcpus=2,sockets=1,cores=2,threads=1 \
		--cpu host \
		--ram 2048 \
		--disk middlebox.qcow2 \
		--network network=net_for_ssh \
		--network network=net_1,model=e1000 \
		--network network=net_2,model=e1000 \
		--noautoconsole

	virsh snapshot-create-as middlebox --name init
else
	virsh snapshot-revert middlebox --snapshotname init
fi

# =======================================
# Подготовка машины server
# =======================================
if ! virsh list --all | grep -q " server "
then
	virt-builder ubuntu-18.04 \
		--format qcow2 \
		--output server.qcow2 \
		--hostname server \
		--install nginx,net-tools \
		--root-password password:1111 \
		--run-command "ssh-keygen -A" \
		--run-command "sed -i \"s/.*PermitRootLogin.*/PermitRootLogin yes/g\" /etc/ssh/sshd_config" \
		--copy-in netcfg_server.yaml:/etc/netplan/

	virt-install \
		--import \
		--name server \
		--ram 1024 \
		--disk server.qcow2 \
		--network network=net_for_ssh \
		--network network=net_2,mac=52:54:56:00:00:00 \
		--noautoconsole

	virsh snapshot-create-as server --name init
else
	virsh snapshot-revert server --snapshotname init
fi

# =======================================
# Убедимся, что наши машины запустились
# и доступны для команд управления
# =======================================
while ! $EXEC_CLIENT echo
do
	echo "Waiting for client VM ..."
	sleep 1
done

while ! $EXEC_MIDDLEBOX echo
do
	echo "Waiting for middlebox VM ..."
	sleep 1
done

while ! $EXEC_SERVER echo
do
	echo "Waiting for server VM ..."
	sleep 1
done

# =======================================
# Собственно, начало теста
# Копируем дитрибутив l3fwd-acl на middlebox
# Устанавливаем и запускаем его
# =======================================
$SCP_CMD l3fwd-acl-1.0.0.deb root@192.168.100.3:~

$EXEC_MIDDLEBOX << EOF
	set -xeuo pipefail

	dpkg -i l3fwd-acl-1.0.0.deb

	echo 256 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
	mkdir -p /mnt/huge
	mount -t hugetlbfs nodev /mnt/huge

	modprobe uio_pci_generic
	dpdk-devbind --bind=uio_pci_generic ens4 ens5

	echo "R0.0.0.0/0 192.168.102.0/24 0 : 65535 0 : 65535 0x0/0x0 1" > /etc/rule_ipv4.db
	echo "R0.0.0.0/0 192.168.101.0/24 0 : 65535 0 : 65535 0x0/0x0 0" >> /etc/rule_ipv4.db

	echo "R0:0:0:0:0:0:0:0/0 0:0:0:0:0:0:0:0/0 0 : 65535 0 : 65535 0x0/0x0 0" > /etc/rule_ipv6.db

	daemon --name l3fwd --unsafe --output /var/log/l3fwd -- l3fwd-acl \
		-l 1 \
		-n 4 \
		-- \
		-p 0x3 \
		-P \
		--config="(0,0,1),(1,0,1)" \
		--rule_ipv4="/etc/rule_ipv4.db" \
		--rule_ipv6="/etc/rule_ipv6.db"
EOF

# =======================================
# Проверяем, что трафик ходит без проблем
# =======================================

$EXEC_CLIENT arp -s 192.168.101.3 52:54:56:00:00:00
$EXEC_SERVER arp -s 192.168.102.3 52:54:56:11:00:00

$EXEC_CLIENT << EOF
	set -xeuo pipefail

	ping -c 5 192.168.102.2
	wget --timeout=5 --tries=1 http://192.168.102.2
EOF

# =======================================
# Добавим правило, заврещающее tcp трафик
# =======================================

$EXEC_MIDDLEBOX << EOF
	set -xeuo pipefail

	daemon --name l3fwd --stop

	echo "@0.0.0.0/0 0.0.0.0/0 0 : 65535 0 : 65535 0x06/0xff" > /etc/rule_ipv4.db
	echo "R0.0.0.0/0 192.168.102.0/24 0 : 65535 0 : 65535 0x0/0x0 1" >> /etc/rule_ipv4.db
	echo "R0.0.0.0/0 192.168.101.0/24 0 : 65535 0 : 65535 0x0/0x0 0" >> /etc/rule_ipv4.db

	daemon --name l3fwd --unsafe --output /var/log/l3fwd -- l3fwd-acl \
		-l 1 \
		-n 4 \
		-- \
		-p 0x3 \
		-P \
		--config="(0,0,1),(1,0,1)" \
		--rule_ipv4="/etc/rule_ipv4.db" \
		--rule_ipv6="/etc/rule_ipv6.db"
EOF

# =======================================
# Проверяем, что ping продолжает ходить,
# а http трафик - перестал
# =======================================

$EXEC_CLIENT << EOF
	set -xeuo pipefail

	ping -c 5 192.168.102.2
	! wget --timeout=5 --tries=1 http://192.168.102.2
EOF

echo "====================================="
echo "УРА, НАШИ ТЕСТЫ ЗАВЕРШИЛИСЬ УСПЕШНО!!"
echo "ПОЙДЁМТЕ ВЫПЬЕМ ПИВКА ПО ЭТОМУ СЛУЧАЮ"
echo "====================================="
