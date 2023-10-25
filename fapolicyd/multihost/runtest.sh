#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /keylime_server-role-tests/multihost/db-postgresql-with-custom-certificates
#   Description: Test basic keylime attestation scenario using multiple hosts and setting attestation server via keylime roles
#   Author: Patrik Koncity <pkoncity@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2023 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
#. /usr/bin/rhts-environment.sh || exit 1
. /usr/share/beakerlib/beakerlib.sh || exit 1

# when manually troubleshooting multihost test in Restraint environment
# you may want to export XTRA variable to a unique number each team
# to make user that sync events have unique names and there are not
# collisions with former test runs

# define FAPOLICYD_SERVER_ANSIBLE_ROLE if not set already
# rhel-system-roles.keylime_server = legacy ansible role format
# redhat.rhel_system_roles.keylime_server = collection ansible role format

function assign_server_roles() {
    if [ -f ${TMT_TOPOLOGY_BASH} ]; then
        # assign roles based on tmt topology data
        cat ${TMT_TOPOLOGY_BASH}
        . ${TMT_TOPOLOGY_BASH}

        export FAPOLICYD_CLIENT=${TMT_GUESTS["fapolicyd_client.hostname"]}
        export CONTROLLER=${TMT_GUESTS["controller.hostname"]}

    elif [ -n "$SERVERS" ]; then
        # assign roles using SERVERS and CLIENTS variables
        export FAPOLICYD_CLIENT=$( echo "$SERVERS $CLIENTS" | awk '{ print $1 }')
        export CONTROLLER=$( echo "$SERVERS $CLIENTS" | awk '{ print $2 }')
    fi

    MY_IP=$( hostname -I | awk '{ print $1 }' )
    [ -n "$FAPOLICYD_CLIENT" ] && export FAPOLICYD_CLIENT_IP=$( get_IP ${FAPOLICYD_CLIENT} )
    [ -n "$CONTROLLER" ] && export CONTROLLER_IP=$( get_IP ${CONTROLLER} )
}

function get_IP() {
    if echo $1 | grep -E -q '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        echo $1
    else
        host $1 | sed -n -e 's/.*has address //p' | head -n 1
    fi
}

Fapolicyd_client() {

    rlJournalStart
    rlPhaseStartSetup
        rlRun "mkdir -p /var/tmp/executable_binaries"
        CleanupRegister 'rlRun "popd"'
        rlRun "pushd $TEST_DIR"
        echo 'int main(void) { return 0; }' > main.c
        exe1="${TEST_DIR}/exe1"
        exe2="${TEST_DIR}/exe2"
        rlRun "testUserSetup"
        rlRun "gcc main.c -o $exe1" 0 "Creating binary $exe1"
        rlRun "gcc main.c -g -o $exe2" 0 "Creating binary $exe2"
        rlRun "chmod a+rx $exe1 $exe2 ${TEST_DIR}"
        rlRun "sync-set BINARIES_CREATING_DONE"
        rlRun "sync-block ANSIBLE_SETUP_DONE ${CONTROLLER_IP}" 0 "Waiting for ansible setup..."
    rlPhaseEnd

    rlPhaseStartTest "cached object"
      rlServiceStatus fapolicyd
      rlRun "su -c '$exe1' - $testUser" 0 "cache trusted binary $exe1"
      rlRun "su -c '$exe2' - $testUser" 126 "check untrusted binary $exe2"
      CleanupRegister --mark "rlRun 'cat ${exe1}a > ${exe1}; rm -f ${exe1}a' 0 'restore $exe1'"
      rlRun "cat $exe1 > ${exe1}a" 0 "backup $exe1"
      rlRun "cat $exe2 > $exe1" 0 "replace $exe1 with $exe2"
      rlRun "su -c '$exe1' - $testUser" 126 "the cached $exe1 is invalidated by the binary change"
      rlRun "su -c '$exe2' - $testUser" 126 "check untrusted binary $exe2"
      rlRun "fapServiceOut"
      CleanupDo --mark
    rlPhaseEnd

    rlPhaseStartTest "live-update of trustdb"
      CleanupRegister --mark "rlRun 'fapolicyd-cli -f add $exe1'; rlRun 'fapolicyd-cli --update'"
      rlRun "fapolicyd-cli -f delete $exe1"
      rlRun "fapStart"
      rlRun "su -c '$exe1' - $testUser" 126 "untrusted binary $exe1"
      rlRun "fapolicyd-cli -f add $exe1"
      rlRun 'fapolicyd-cli --update'
      rlRun "sleep 20s"
      rlRun "fapServiceOut -t"
      rlRun "su -c '$exe1' - $testUser" 0 "trusted binary $exe1"
      rlRun "fapolicyd-cli -f delete $exe1"
      rlRun 'fapolicyd-cli --update'
      rlRun "sleep 20s"
      rlRun "fapServiceOut -t"
      rlRun "su -c '$exe1' - $testUser" 126 "utrusted binary $exe1"
      CleanupDo --mark
    rlPhaseEnd

    rlPhaseStartCleanup "Fapolicyd client cleanup"
      rlRun "rm -rf $TEST_DIR"
      CleanupDo
    rlPhaseEnd
    rlJournalPrintText
    rlJournalEnd
}

Controller() {
    rlPhaseStartTest "Role setup"
        rlRun "sync-block BINARIES_CREATING_DONE ${FAPOLICYD_CLIENT_IP}" 0 "Waiting for ansible setup..."
        #for now is installed from upstream
        rlRun "rm -rf roles && mkdir roles"
        pushd roles
        rlRun "GIT_SSL_NO_VERIFY=1 git clone https://github.com/radosroka/fapolicyd-system-role.git"
        popd
        rlRun "echo $FAPOLICYD_CLIENT_IP" > inventory
        rlRun "cat > playbook.yml <<EOF
# SPDX-License-Identifier: MIT
---
- name: Example template role invocation
  hosts: all
  vars:
    fapolicyd_setup_enable_service: true
    fapolicyd_setup_integrity: sha256
    fapolicyd_setup_trust: rpmdb,file
    fapolicyd_add_trusted_file:
      - /etc/passwd
      - /etc/fapolicyd/fapolicyd.conf
      - /etc/krb5.conf
      - ${TEST_DIR}/exe1
  roles:
    - fapolicyd-system-role
EOF"

        rlRun 'ansible-playbook --ssh-common-args "-o StrictHostKeychecking=no" -i inventory playbook.yml' 
        rlRun "sync-set ANSIBLE_SETUP_DONE" 
    rlPhaseEnd

    rlPhaseStartCleanup "Controller cleanup"
    rlPhaseEnd
}


####################
# Common script part
####################

rlJournalStart
    rlPhaseStartSetup
        rlRun 'rlImport "keylime-tests/sync"' || rlDie "cannot import keylime-tests/sync library"
        rlRun "rlImport --all" || rlDie 'cannot continue'
        TEST_DIR=/var/tmp/executable_binaries

        assign_server_roles

        rlLog "FAPOLICYD_CLIENT: ${FAPOLICYD_CLIENT} ${FAPOLICYD_CLIENT_IP}"
        rlLog "CONTROLLER: ${CONTROLLER} ${CONTROLLER_IP}"
        rlLog "This system is: $(hostname) ${MY_IP}"
        ###############
        # common setup
        ###############

        rlRun "rlFileBackup --clean ~/.ssh/"
        #preparing ssh keys for mutual connection
        #in future can moved to new sync lib func
        rlRun "cp ssh_keys/* ~/.ssh/"
        rlRun "cat ~/.ssh/id_rsa_multihost.pub >> ~/.ssh/authorized_keys"
        rlRun "chmod 700 ~/.ssh/id_rsa_multihost.pub ~/.ssh/id_rsa_multihost"

    rlPhaseEnd

    if echo " $HOSTNAME $MY_IP " | grep -q " ${FAPOLICYD_CLIENT} "; then
        Fapolicyd_client
    elif echo " $HOSTNAME $MY_IP " | grep -q " ${CONTROLLER} "; then
        Controller
    else
        rlPhaseStartTest
            rlFail "Unknown role"
        rlPhaseEnd
    fi

    rlPhaseStartCleanup
        rlRun "rlFileRestore"
    rlPhaseEnd

rlJournalPrintText
rlJournalEnd