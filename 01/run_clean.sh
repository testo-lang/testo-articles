#!/bin/bash
set -euo pipefail

# =======================================
# Удаление машины client
# =======================================
if virsh list --all | grep -q " client "; then
	if virsh domstate client | grep -q "running"; then
		virsh destroy client
	fi
	virsh undefine client --snapshots-metadata --remove-all-storage
fi

# =======================================
# Удаление машины middlebox
# =======================================
if virsh list --all | grep -q " middlebox "; then
	if virsh domstate middlebox | grep -q "running"; then
		virsh destroy middlebox
	fi
	virsh undefine middlebox --snapshots-metadata --remove-all-storage
fi

# =======================================
# Удаление машины server
# =======================================
if virsh list --all | grep -q " server "; then
	if virsh domstate server | grep -q "running"; then
		virsh destroy server
	fi
	virsh undefine server --snapshots-metadata --remove-all-storage
fi

# =======================================
# Удаление сети net_for_ssh
# =======================================
if virsh net-list --all | grep -q " net_for_ssh "; then
	if virsh net-list --all | grep " net_for_ssh " | grep -q " active "; then
		virsh net-destroy net_for_ssh
	fi
	virsh net-undefine net_for_ssh
fi

# =======================================
# Удаление сети net_1
# =======================================
if virsh net-list --all | grep -q " net_1 "; then
	if virsh net-list --all | grep " net_1 " | grep -q " active "; then
		virsh net-destroy net_1
	fi
	virsh net-undefine net_1
fi

# =======================================
# Удаление сети net_2
# =======================================
if virsh net-list --all | grep -q " net_2 "; then
	if virsh net-list --all | grep " net_2 " | grep -q " active "; then
		virsh net-destroy net_2
	fi
	virsh net-undefine net_2
fi
