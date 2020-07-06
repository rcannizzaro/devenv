#!/bin/bash

# exit script if return code != 0
set -e

# build scripts
####

# download build scripts from github
curl --connect-timeout 5 --max-time 600 --retry 5 --retry-delay 0 --retry-max-time 60 -o /tmp/scripts-master.zip -L https://github.com/rcannizzaro/devenv-scripts/archive/master.zip

# unzip build scripts
unzip /tmp/scripts-master.zip -d /tmp

# move shell scripts to /root
mv /tmp/devenv-scripts-master/shell/arch/docker/*.sh /usr/local/bin/

# detect image arch
####

OS_ARCH=$(cat /etc/os-release | grep -P -o -m 1 "(?=^ID\=).*" | grep -P -o -m 1 "[a-z]+$")
if [[ ! -z "${OS_ARCH}" ]]; then
	if [[ "${OS_ARCH}" == "arch" ]]; then
		OS_ARCH="x86-64"
	else
		OS_ARCH="aarch64"
	fi
	echo "[info] OS_ARCH defined as '${OS_ARCH}'"
else
	echo "[warn] Unable to identify OS_ARCH, defaulting to 'x86-64'"
	OS_ARCH="x86-64"
fi

# pacman packages
####

# define pacman packages
pacman_packages="base-devel git tk mc nano mono dotnet-sdk"

# install compiled packages using pacman
if [[ ! -z "${pacman_packages}" ]]; then
	pacman -S --needed $pacman_packages --noconfirm
fi

# aur packages
####

# build package only, as apacman seems to be having issues finding the rider built
# package, probably related to the fact that the package version has a colon, so
# this could be a bug in apacman escaping.
# due to the above issue we build and then use pacman to install manually (done in aur.sh).
aur_build_only="true"

# define aur packages
# call aur install script (arch user repo)

aur_packages="gconf-gtk2"
source aur.sh

aur_packages="msbuild-15-bin rider"
source aur.sh

aur_packages="webstorm"
source aur.sh

aur_packages="github-desktop-bin"
source aur.sh

aur_packages="ghidra-bin"
source aur.sh

aur_packages="visual-studio-code-bin"
source aur.sh

# config novnc
###

# overwrite novnc 16x16 icon with application specific 16x16 icon (used by bookmarks and favorites)
cp /home/nobody/novnc-16x16.png /usr/share/webapps/novnc/app/images/icons/

cat <<'EOF' > /tmp/startcmd_heredoc
# run rider
/usr/bin/rider
EOF

# replace startcmd placeholder string with contents of file (here doc)
sed -i '/# STARTCMD_PLACEHOLDER/{
    s/# STARTCMD_PLACEHOLDER//g
    r /tmp/startcmd_heredoc
}' /home/nobody/start.sh
rm /tmp/startcmd_heredoc

# config openbox
####

cat <<'EOF' > /tmp/menu_heredoc
    <item label="Rider">
    <action name="Execute">
      <command>/usr/bin/rider</command>
      <startupnotify>
        <enabled>yes</enabled>
      </startupnotify>
    </action>
    </item>
EOF

# replace menu placeholder string with contents of file (here doc)
sed -i '/<!-- APPLICATIONS_PLACEHOLDER -->/{
    s/<!-- APPLICATIONS_PLACEHOLDER -->//g
    r /tmp/menu_heredoc
}' /home/nobody/.config/openbox/menu.xml
rm /tmp/menu_heredoc

# env vars
####

# set RIDER_PROPERTIES env var, this determines the path to the custom idea.properties file
# which contains the paths for config, plugins, system and log paths (see config rider section),
# which are then defined to point at /config/... for persistence.

cat <<'EOF' > /tmp/envvars_heredoc
export RIDER_PROPERTIES=$(echo "${RIDER_PROPERTIES}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${RIDER_PROPERTIES}" ]]; then
	echo "[info] RIDER_PROPERTIES defined as '${RIDER_PROPERTIES}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	export RIDER_PROPERTIES="/home/nobody/.config/rider/config/idea.properties"
	echo "[info] RIDER_PROPERTIES not defined, defaulting to '${RIDER_PROPERTIES}'" | ts '%Y-%m-%d %H:%M:%.S'
fi

export RIDER_VM_OPTIONS=$(echo "${RIDER_VM_OPTIONS}" | sed -e 's~^[ \t]*~~;s~[ \t]*$~~')
if [[ ! -z "${RIDER_VM_OPTIONS}" ]]; then
	echo "[info] RIDER_VM_OPTIONS defined as '${RIDER_VM_OPTIONS}'" | ts '%Y-%m-%d %H:%M:%.S'
else
	echo "[info] RIDER_VM_OPTIONS not defined, skipping additional options'" | ts '%Y-%m-%d %H:%M:%.S'
fi
EOF

# replace env vars placeholder string with contents of file (here doc)
sed -i '/# ENVVARS_PLACEHOLDER/{
	s/# ENVVARS_PLACEHOLDER//g
	r /tmp/envvars_heredoc
}' /usr/local/bin/init.sh
rm /tmp/envvars_heredoc

# container perms
####

# define comma separated list of paths 
install_paths="/tmp,/usr/share/themes,/home/nobody,/usr/share/webapps/novnc,/usr/share/applications,/usr/share/licenses,/etc/xdg,/usr/share/rider"

# split comma separated string into list for install paths
IFS=',' read -ra install_paths_list <<< "${install_paths}"

# process install paths in the list
for i in "${install_paths_list[@]}"; do

	# confirm path(s) exist, if not then exit
	if [[ ! -d "${i}" ]]; then
		echo "[crit] Path '${i}' does not exist, exiting build process..." ; exit 1
	fi

done

# convert comma separated string of install paths to space separated, required for chmod/chown processing
install_paths=$(echo "${install_paths}" | tr ',' ' ')

# set permissions for container during build - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
chmod -R 775 ${install_paths}

# create file with contents of here doc, note EOF is NOT quoted to allow us to expand current variable 'install_paths'
# we use escaping to prevent variable expansion for PUID and PGID, as we want these expanded at runtime of init.sh
cat <<EOF > /tmp/permissions_heredoc

# get previous puid/pgid (if first run then will be empty string)
previous_puid=\$(cat "/root/puid" 2>/dev/null || true)
previous_pgid=\$(cat "/root/pgid" 2>/dev/null || true)

# if first run (no puid or pgid files in /tmp) or the PUID or PGID env vars are different 
# from the previous run then re-apply chown with current PUID and PGID values.
if [[ ! -f "/root/puid" || ! -f "/root/pgid" || "\${previous_puid}" != "\${PUID}" || "\${previous_pgid}" != "\${PGID}" ]]; then

	# set permissions inside container - Do NOT double quote variable for install_paths otherwise this will wrap space separated paths as a single string
	chown -R "\${PUID}":"\${PGID}" ${install_paths}

fi

# write out current PUID and PGID to files in /root (used to compare on next run)
echo "\${PUID}" > /root/puid
echo "\${PGID}" > /root/pgid

EOF

# replace permissions placeholder string with contents of file (here doc)
sed -i '/# PERMISSIONS_PLACEHOLDER/{
    s/# PERMISSIONS_PLACEHOLDER//g
    r /tmp/permissions_heredoc
}' /usr/local/bin/init.sh
rm /tmp/permissions_heredoc

# env vars
####

# cleanup
cleanup.sh
