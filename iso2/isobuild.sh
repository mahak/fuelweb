#!/bin/bash

#set -x
set -e

[ X`whoami` = X'root' ] || { echo "You must be root to run this script."; exit 1; }


###########################
# VARIABLES
###########################
STAMP=`date +%Y%m%d%H%M%S`

SCRIPT=`readlink -f "$0"`
SCRIPTDIR=`dirname ${SCRIPT}`
REPO=${SCRIPTDIR}/..
GNUPG=${REPO}/gnupg
STAGE=${SCRIPTDIR}/stage

RELEASE=precise
VERSION=12.04

ORIGISO=/var/tmp/ubuntu-12.04-server-amd64.iso
NEWISONAME=nailgun-ubuntu-${VERSION}-amd64
[ -z ${NEWISODIR} ] && NEWISODIR=/var/tmp

MIRROR="http://ru.archive.ubuntu.com/ubuntu"
REQDEB=`cat ${REPO}/requirements-deb.txt | grep -v "^\s*$" | grep -v "^\s*#"`

BASEDIR=/var/tmp/build_iso2

ORIG=${BASEDIR}/orig
NEW=${BASEDIR}/new
EXTRAS=${BASEDIR}/extras
KEYRING=${BASEDIR}/keyring
INDICES=${BASEDIR}/indices

TMPGNUPG=${BASEDIR}/gnupg
GPGKEYID=F8AF89DD
GPGKEYNAME="Mirantis Product"
GPGKEYEMAIL="<product@mirantis.com>"
GPGKEY="${GPGKEYNAME} ${GPGKEYEMAIL}"
GPGPASSWDFILE=${TMPGNUPG}/keyphrase

ARCHITECTURES="i386 amd64"
SECTIONS="main restricted universe multiverse"


[ -z ${BOOTSTRAP_KERNEL_URL} ] && \
    BOOTSTRAP_KERNEL_URL='http://mc0n1-srt.srt.mirantis.net/nailgun_bootstrap/linux'
[ -z ${BOOTSTRAP_INITRD_URL} ] && \
    BOOTSTRAP_INITRD_URL='http://mc0n1-srt.srt.mirantis.net/nailgun_bootstrap/initrd.gz'
BOOTSTRAPDIR=${BASEDIR}/bootstrap

EGGSDIR=${BASEDIR}/eggs
GEMSDIR=${BASEDIR}/gems


###########################
# CLEANING
###########################
echo "Cleaning ..."
if (mount | grep -q ${ORIG}); then
    echo "Umounting ${ORIG} ..."
    umount ${ORIG}
fi

echo "Removing ${BASEDIR} ..."
rm -rf ${BASEDIR}

echo "Removing ${ORIG} ..."
rm -rf ${ORIG}

echo "Removing ${NEW} ..."
rm -rf ${NEW}

echo "Removing ${INDICES} ..."
rm -rf ${INDICES}

#echo "Removing ${EXTRAS} ..."
#rm -rf ${EXTRAS}

echo "Removing ${TMPGNUPG} ..."
rm -rf ${TMPGNUPG}

echo "Removing ${KEYRING} ..."
rm -rf ${KEYRING}





###########################
# STAGING
###########################

mkdir -p ${ORIG}
mkdir -p ${NEW}

echo "Mounting original iso image ..."
mount | grep -q ${ORIG} && umount ${ORIG}
mount -o loop ${ORIGISO} ${ORIG}

echo "Syncing original iso to new iso ..."
rsync -a ${ORIG}/ ${NEW}
chmod -R u+w ${NEW}

echo "Syncing stage directory to new iso ..."
rsync -a ${STAGE}/ ${NEW}

###########################
# DOWNLOADING INDICES
###########################
echo "Downloading indices ..."
mkdir -p ${INDICES}

for s in ${SECTIONS}; do
    wget -qO- ${MIRROR}/indices/override.${RELEASE}.${s}.debian-installer > \
	${INDICES}/override.${RELEASE}.${s}.debian-installer
    
    wget -qO- ${MIRROR}/indices/override.${RELEASE}.${s} > \
	${INDICES}/override.${RELEASE}.${s}
    
    wget -qO- ${MIRROR}/indices/override.${RELEASE}.extra.${s} > \
	${INDICES}/override.${RELEASE}.extra.${s}
done


###########################
# REORGANIZE POOL
###########################
echo "Reorganizing pool ..."
(
    cd ${NEW}/pool
    find -type f \( -name "*.deb" -o -name "*.udeb" \) | while read debfile; do
	debbase=`basename ${debfile}`
	packname=`echo ${debbase} | awk -F_ '{print $1}'`
	section=`grep "^${packname}\s" ${INDICES}/* | \
	    grep -v extra | head -1 | awk -F: '{print $1}' | \
	    awk -F. '{print $3}'`
	test -z ${section} && section=main
	mkdir -p ${NEW}/pools/${RELEASE}/${section}
	mv ${debfile} ${NEW}/pools/${RELEASE}/${section}
    done
)
rm -fr ${NEW}/pool


###########################
# DOWNLOADING REQUIRED DEBS
###########################
mkdir -p ${EXTRAS}/state
touch ${EXTRAS}/state/status

mkdir -p ${EXTRAS}/archives
mkdir -p ${EXTRAS}/cache

mkdir -p ${EXTRAS}/etc/preferences.d
mkdir -p ${EXTRAS}/etc/apt.conf.d
cat > ${EXTRAS}/etc/sources.list <<EOF
deb ${MIRROR} precise main restricted universe multiverse
deb-src ${MIRROR} precise main restricted universe multiverse
deb http://apt.opscode.com ${RELEASE}-0.10 main
EOF

cat > ${EXTRAS}/etc/preferences.d/opscode <<EOF
Package: *
Pin: origin "apt.opscode.com"
Pin-Priority: 999
EOF


# possible apt configs
# Install-Recommends "true";
# Install-Suggests "true";

cat > ${EXTRAS}/etc/apt.conf <<EOF
APT
{
  Architecture "amd64";
  Default-Release "${RELEASE}";
  Get::AllowUnauthenticated "true";
};

Dir
{
  State "${EXTRAS}/state";
  State::status "status";
  
  Cache::archives "${EXTRAS}/archives";
  Cache "${EXTRAS}/cache";
  
  Etc "${EXTRAS}/etc";
};

Debug::NoLocking "true";
EOF

echo "Linking files that already in pool ..."
find ${NEW}/pools/${RELEASE} -name "*.deb" -o -name "*.udeb" | while read debfile; do
    debbase=`basename ${debfile}`
    ln -sf  ${debfile} ${EXTRAS}/archives/${debbase}
done

echo "Downloading requied packages ..."
apt-get -c=${EXTRAS}/etc/apt.conf update
for package in ${REQDEB}; do
    apt-get -c=${EXTRAS}/etc/apt.conf -d -y install ${package}
done

find ${EXTRAS}/archives -type f \( -name "*.deb" -o -name "*.udeb" \) | while read debfile; do
    debbase=`basename ${debfile}`
    packname=`echo ${debbase} | awk -F_ '{print $1}'`
    section=`grep "^${packname}\s" ${INDICES}/* | \
	grep -v extra | head -1 | awk -F: '{print $1}' | \
	awk -F. '{print $3}'`
    test -z ${section} && section=main
    mkdir -p ${NEW}/pools/${RELEASE}/${section}
    cp ${debfile} ${NEW}/pools/${RELEASE}/${section}
done


###########################
# REBUILDING KEYRING
###########################
echo "Rebuilding ubuntu-keyring packages ..."

mkdir -p ${KEYRING}

(
    cd ${KEYRING} && apt-get -c=${EXTRAS}/etc/apt.conf source ubuntu-keyring
)

KEYRING_PACKAGE=`find ${KEYRING} -maxdepth 1 \
    -name "ubuntu-keyring*" -type d -print | xargs basename`
if [ -z ${KEYRING_PACKAGE} ]; then
    echo "Cannot grab keyring source! Exiting."
    exit 1
fi

cp -rp ${GNUPG} ${TMPGNUPG}
chown -R root:root ${TMPGNUPG}
chmod 700 ${TMPGNUPG}
chmod 600 ${TMPGNUPG}/*

GNUPGHOME=${TMPGNUPG} gpg --import < \
    ${KEYRING}/${KEYRING_PACKAGE}/keyrings/ubuntu-archive-keyring.gpg

GNUPGHOME=${TMPGNUPG} gpg --yes --export \
    --output ${KEYRING}/${KEYRING_PACKAGE}/keyrings/ubuntu-archive-keyring.gpg \
    FBB75451 437D05B5 ${GPGKEYID}

(
    cd ${KEYRING}/${KEYRING_PACKAGE} && \
	dpkg-buildpackage -m"Mirantis Nailgun" -k"${GPGKEYID}" -uc -us
)

rm -f ${NEW}/pools/${RELEASE}/main/ubuntu-keyring*deb
cp ${KEYRING}/ubuntu-keyring*deb ${NEW}/pools/${RELEASE}/main || \
    { echo "Error occured while moving rebuilded ubuntu-keyring packages into pool"; exit 1; }


###########################
# UPDATING REPO
###########################

for s in ${SECTIONS}; do
    for a in ${ARCHITECTURES}; do
	for t in deb udeb; do
	    [ X${t} = Xudeb ] && di="/debian-installer" || di=""
	    mkdir -p ${NEW}/dists/${RELEASE}/${s}${di}/binary-${a}

	    if [ X${t} = Xdeb ]; then
		cat > ${NEW}/dists/${RELEASE}/${s}/binary-${a}/Release <<EOF
Archive: ${RELEASE}
Version: ${VERSION}
Component: ${s}
Origin: Mirantis
Label: Mirantis
Architecture: ${a}
EOF
	    fi
	done
    done
done

cat > ${BASEDIR}/extraoverride.pl <<EOF
#!/usr/bin/env perl
while (<>) {
  chomp; next if /^ /;
  if (/^\$/ && defined(\$task)) {
    print "\$package Task \$task\n";
    undef \$package;
    undef \$task;
  } 
  (\$key, \$value) = split /: /, \$_, 2;
  if (\$key eq 'Package') {
    \$package = \$value;
  } 
  if (\$key eq 'Task') {
    \$task = \$value;
  }
}
EOF
chmod +x ${BASEDIR}/extraoverride.pl

gunzip -c ${NEW}/dists/${RELEASE}/main/binary-amd64/Packages.gz | \
    ${BASEDIR}/extraoverride.pl >> \
    ${INDICES}/override.${RELEASE}.extra.main

for s in ${SECTIONS}; do
    for a in ${ARCHITECTURES}; do
	for t in deb udeb; do
	    echo "Scanning section=${s} arch=${a} type=${t} ..."

	    if [ X${t} = Xudeb ]; then
		di="/debian-installer"
		diover=".debian-installer"
	    else
		di=""
		diover=""
	    fi

	    [ -r ${INDICES}/override.${RELEASE}.${s}${diover} ] && \
		override=${INDICES}/override.${RELEASE}.${s}${diover} || \
		unset override
	    [ -r ${INDICES}/override.${RELEASE}.extra.${s} ] && \
		extraoverride="-e ${INDICES}/override.${RELEASE}.extra.${s}" || \
		unset extraoverride

	    mkdir -p ${NEW}/pools/${RELEASE}/${s}

	    (
		cd ${NEW} && dpkg-scanpackages -m -a${a} -t${t} ${extraoverride} \
		    pools/${RELEASE}/${s} \
		    ${override} > \
		    ${NEW}/dists/${RELEASE}/${s}${di}/binary-${a}/Packages
	    )

	    gzip -c ${NEW}/dists/${RELEASE}/${s}${di}/binary-${a}/Packages > \
		${NEW}/dists/${RELEASE}/${s}${di}/binary-${a}/Packages.gz
	done
    done
done

echo "Creating main Release file in cdrom repo"

cat > ${BASEDIR}/release.conf <<EOF
APT::FTPArchive::Release::Origin "Mirantis";
APT::FTPArchive::Release::Label "Mirantis";
APT::FTPArchive::Release::Suite "${RELEASE}";
APT::FTPArchive::Release::Version "${VERSION}";
APT::FTPArchive::Release::Codename "${RELEASE}";
APT::FTPArchive::Release::Architectures "${ARCHITECTURES}";
APT::FTPArchive::Release::Components "${SECTIONS}";
APT::FTPArchive::Release::Description "Mirantis Nailgun Repo";
EOF


apt-ftparchive -c ${BASEDIR}/release.conf release ${NEW}/dists/${RELEASE} > \
    ${NEW}/dists/${RELEASE}/Release


echo "Signing main Release file in cdrom repo ..."
GNUPGHOME=${TMPGNUPG} gpg --yes --no-tty --default-key ${GPGKEYID} \
    --passphrase-file ${GPGPASSWDFILE} --output ${NEW}/dists/${RELEASE}/Release.gpg \
    -ba ${NEW}/dists/${RELEASE}/Release


###########################
# DOWNLOADING BOOTSTRAP
###########################
echo "Downloading bootstrap kernel and miniroot ..."
echo "BOOTSTRAP_KERNEL_URL=${BOOTSTRAP_KERNEL_URL}"
echo "BOOTSTRAP_INITRD_URL=${BOOTSTRAP_INITRD_URL}"
mkdir -p ${BOOTSTRAPDIR}
wget -qO- ${BOOTSTRAP_KERNEL_URL} > ${BOOTSTRAPDIR}/linux
wget -qO- ${BOOTSTRAP_INITRD_URL} > ${BOOTSTRAPDIR}/initrd.gz


###########################
# DOWNLOADING PYTHON EGGS
###########################
echo "Downloading python eggs ..."
# FIXME:
# It is very ugly to just copy directory with eggs into disk
# It is nice to have beautiful way to download eggs with there dependencies
mkdir -p ${EGGSDIR}
rsync -av /var/tmp/eggs/ ${EGGSDIR}

###########################
# DOWNLOADING RUBY GEMS
###########################
echo "Downloading ruby gems ..."
# FIXME:
# It is very ugly to just copy directory with gems into disk
# It is nice to have beautiful way to download gems with there dependencies
mkdir -p ${GEMSDIR}
rsync -av /var/tmp/gems/ ${GEMSDIR}



###########################
# INJECT EXTRA FILES
###########################
echo "Injecting some files into iso ..."
mkdir -p ${NEW}/inject/scripts
mkdir -p ${NEW}/indices
cp -r ${INDICES}/* ${NEW}/indices
cp -r ${REPO}/cookbooks ${NEW}/inject
cp ${REPO}/scripts/solo-admin.json ${NEW}/inject/scripts/solo.json
cp ${REPO}/scripts/solo.rb ${NEW}/inject/scripts
cp ${REPO}/scripts/solo.cron ${NEW}/inject/scripts
cp ${REPO}/scripts/solo.rc.local ${NEW}/inject/scripts
cp -r ${REPO}/gnupg ${NEW}/inject/gnupg
cp -r ${REPO}/nailgun ${NEW}/inject
mkdir -p ${NEW}/bootstrap
cp ${BOOTSTRAPDIR}/linux ${NEW}/bootstrap/linux
cp ${BOOTSTRAPDIR}/initrd.gz ${NEW}/bootstrap/initrd.gz
mkdir -p ${NEW}/eggs
rsync -av ${EGGSDIR}/ ${NEW}/eggs
mkdir -p ${NEW}/gems
rsync -av ${GEMSDIR}/ ${NEW}/gems


###########################
# MAKE NEW ISO
###########################
echo "Calculating md5sums ..."
rm ${NEW}/md5sum.txt
(
    cd ${NEW}/ && \
    find . -type f -print0 | \
    xargs -0 md5sum | \
    grep -v "boot.cat" | \
    grep -v "md5sum.txt" > md5sum.txt
)


echo "Building iso image ..."
mkisofs -r -V "Mirantis Nailgun" \
    -cache-inodes \
    -J -l -b isolinux/isolinux.bin \
    -c isolinux/boot.cat -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    -o ${NEWISODIR}/${NEWISONAME}.${STAMP}.iso ${NEW}/


rm -f ${NEWISODIR}/${NEWISONAME}.last.iso
(
    cd ${NEWISODIR}
    ln -s ${NEWISONAME}.${STAMP}.iso ${NEWISONAME}.last.iso
)
