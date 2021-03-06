#!/usr/bin/env bash
#shellcheck disable=SC2001

# netdata
# real-time performance and health monitoring, done right!
# (C) 2016 Costa Tsaousis <costa@tsaousis.gr>
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Script to find a better name for cgroups
#

export PATH="${PATH}:/sbin:/usr/sbin:/usr/local/sbin"
export LC_ALL=C

# -----------------------------------------------------------------------------

PROGRAM_NAME="$(basename "${0}")"

logdate() {
	date "+%Y-%m-%d %H:%M:%S"
}

log() {
	local status="${1}"
	shift

	echo >&2 "$(logdate): ${PROGRAM_NAME}: ${status}: ${*}"

}

warning() {
	log WARNING "${@}"
}

error() {
	log ERROR "${@}"
}

info() {
	log INFO "${@}"
}

fatal() {
	log FATAL "${@}"
	exit 1
}

function docker_get_name_classic() {
	local id="${1}"
	info "Running command: docker ps --filter=id=\"${id}\" --format=\"{{.Names}}\""
	NAME="$(docker ps --filter=id="${id}" --format="{{.Names}}")"
	return 0
}

function docker_get_name_api() {
	local id="${1}"
	if [ ! -S "${DOCKER_HOST}" ]; then
		warning "Can't find ${DOCKER_HOST}"
		return 1
	fi
	info "Running API command: /containers/${id}/json"
	JSON=$(echo -e "GET /containers/${id}/json HTTP/1.0\\r\\n" | nc -U "${DOCKER_HOST}" | grep '^{.*')
	NAME=$(echo "$JSON" | jq -r .Name,.Config.Hostname | grep -v null | head -n1 | sed 's|^/||')
	return 0
}

function docker_get_name() {
	local id="${1}"
	if hash docker 2>/dev/null; then
		docker_get_name_classic "${id}"
	else
		docker_get_name_api "${id}" || docker_get_name_classic "${id}"
	fi
	if [ -z "${NAME}" ]; then
		warning "cannot find the name of docker container '${id}'"
		NAME="${id:0:12}"
	else
		info "docker container '${id}' is named '${NAME}'"
	fi
}

function docker_validate_id() {
	local id="${1}"
	if [ -n "${id}" ] && { [ ${#id} -eq 64 ] || [ ${#id} -eq 12 ]; }; then
		docker_get_name "${id}"
	else
		error "a docker id cannot be extracted from docker cgroup '${CGROUP}'."
	fi
}

# -----------------------------------------------------------------------------

[ -z "${NETDATA_USER_CONFIG_DIR}" ] && NETDATA_USER_CONFIG_DIR="/etc/netdata"
[ -z "${NETDATA_STOCK_CONFIG_DIR}" ] && NETDATA_STOCK_CONFIG_DIR="/usr/lib/netdata/conf.d"

DOCKER_HOST="${DOCKER_HOST:=/var/run/docker.sock}"
CGROUP="${1}"
NAME=

# -----------------------------------------------------------------------------

if [ -z "${CGROUP}" ]; then
	fatal "called without a cgroup name. Nothing to do."
fi

for CONFIG in "${NETDATA_USER_CONFIG_DIR}/cgroups-names.conf" "${NETDATA_STOCK_CONFIG_DIR}/cgroups-names.conf"; do
	if [ -f "${CONFIG}" ]; then
		NAME="$(grep "^${CGROUP} " "${CONFIG}" | sed 's/[[:space:]]\+/ /g' | cut -d ' ' -f 2)"
		if [ -z "${NAME}" ]; then
			info "cannot find cgroup '${CGROUP}' in '${CONFIG}'."
		else
			break
		fi
	#else
	#   info "configuration file '${CONFIG}' is not available."
	fi
done

if [ -z "${NAME}" ]; then
	if [[ ${CGROUP} =~ ^.*docker[-_/\.][a-fA-F0-9]+[-_\.]?.*$ ]]; then
		# docker containers
		#shellcheck disable=SC1117
		DOCKERID="$(echo "${CGROUP}" | sed "s|^.*docker[-_/]\([a-fA-F0-9]\+\)[-_\.]\?.*$|\1|")"
		docker_validate_id "${DOCKERID}"

	elif [[ ${CGROUP} =~ ^.*ecs[-_/\.][a-fA-F0-9]+[-_\.]?.*$ ]]; then
		# ECS
		#shellcheck disable=SC1117
		DOCKERID="$(echo "${CGROUP}" | sed "s|^.*ecs[-_/].*[-_/]\([a-fA-F0-9]\+\)[-_\.]\?.*$|\1|")"
		docker_validate_id "${DOCKERID}"

	elif [[ ${CGROUP} =~ ^.*kubepods[_/].*[_/]pod[a-fA-F0-9-]+[_/][a-fA-F0-9]+$ ]]; then
		# kubernetes
		#shellcheck disable=SC1117
		DOCKERID="$(echo "${CGROUP}" | sed "s|^.*kubepods[_/].*[_/]pod[a-fA-F0-9-]\+[_/]\([a-fA-F0-9]\+\)$|\1|")"
		docker_validate_id "${DOCKERID}"

	elif [[ ${CGROUP} =~ machine.slice[_/].*\.service ]]; then
		# systemd-nspawn
		NAME="$(echo "${CGROUP}" | sed 's/.*machine.slice[_\/]\(.*\)\.service/\1/g')"

	elif [[ ${CGROUP} =~ machine.slice_machine.*-qemu ]]; then
		# libvirtd / qemu virtual machines
		# NAME="$(echo ${CGROUP} | sed 's/machine.slice_machine.*-qemu//; s/\/x2d//; s/\/x2d/\-/g; s/\.scope//g')"
		NAME="qemu_$(echo "${CGROUP}" | sed 's/machine.slice_machine.*-qemu//; s/\/x2d[[:digit:]]*//; s/\/x2d//g; s/\.scope//g')"

	elif [[ ${CGROUP} =~ machine_.*\.libvirt-qemu ]]; then
		# libvirtd / qemu virtual machines
		NAME="qemu_$(echo "${CGROUP}" | sed 's/^machine_//; s/\.libvirt-qemu$//; s/-/_/;')"

	elif [[ ${CGROUP} =~ qemu.slice_([0-9]+).scope && -d /etc/pve ]]; then
		# Proxmox VMs

		FILENAME="/etc/pve/qemu-server/${BASH_REMATCH[1]}.conf"
		if [[ -f $FILENAME && -r $FILENAME ]]; then
			NAME="qemu_$(grep -e '^name: ' "/etc/pve/qemu-server/${BASH_REMATCH[1]}.conf" | head -1 | sed -rn 's|\s*name\s*:\s*(.*)?$|\1|p')"
		else
			error "proxmox config file missing ${FILENAME} or netdata does not have read access.  Please ensure netdata is a member of www-data group."
		fi
	elif [[ ${CGROUP} =~ lxc_([0-9]+) && -d /etc/pve ]]; then
		# Proxmox Containers (LXC)

		FILENAME="/etc/pve/lxc/${BASH_REMATCH[1]}.conf"
		if [[ -f ${FILENAME} && -r ${FILENAME} ]]; then
			NAME=$(grep -e '^hostname: ' "/etc/pve/lxc/${BASH_REMATCH[1]}.conf" | head -1 | sed -rn 's|\s*hostname\s*:\s*(.*)?$|\1|p')
		else
			error "proxmox config file missing ${FILENAME} or netdata does not have read access.  Please ensure netdata is a member of www-data group."
		fi
	fi

	[ -z "${NAME}" ] && NAME="${CGROUP}"
	[ ${#NAME} -gt 100 ] && NAME="${NAME:0:100}"
fi

info "cgroup '${CGROUP}' is called '${NAME}'"
echo "${NAME}"
